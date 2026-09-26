/*
 * VirtualPhone runtime bridge — see vp_runtime.h.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "vp_runtime.h"
#include "vp_inferno_abi.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The emulator thread's stack: TCG and device emulation recurse deeply. */
#define VP_EMULATOR_STACK (8u * 1024u * 1024u)

_Static_assert(sizeof(vp_frame_info) == sizeof(InfernoFrameInfo),
               "vp_frame_info must match InfernoFrameInfo");
_Static_assert(offsetof(vp_frame_info, generation) == offsetof(InfernoFrameInfo, generation),
               "vp_frame_info must match InfernoFrameInfo");

struct vp_emulator {
    void *handle;

    qemu_init_fn qemu_init;
    qemu_main_loop_fn qemu_main_loop;
    qemu_cleanup_fn qemu_cleanup;

    bql_lock_impl_fn bql_lock;
    bql_unlock_fn bql_unlock;
    bql_locked_fn bql_locked;
    vm_start_fn vm_start;
    vmstop_request_prepare_fn vmstop_prepare;
    vmstop_request_fn vmstop_request;
    reset_request_fn reset_request;
    shutdown_request_fn shutdown_request;

    display_attach_fn display_attach;
    display_invalidate_fn display_invalidate;
    display_read_fn display_read;
    display_stats_fn display_stats;
    input_touch_fn input_touch;
    input_function_key_fn input_key;
    net_link_up_fn net_link_up;
    battery_set_fn battery_set;

    uint32_t caps;

    pthread_mutex_t lock;
    /* Serialises pause/resume/reset/stop and the final STOPPED publication.
     * Lock order: control, then the BQL, then lock. */
    pthread_mutex_t control;
    pthread_cond_t done_cond;
    /* Set with the BQL held as soon as the main loop returns. */
    atomic_bool loop_exited;
    vp_state state;
    int32_t exit_status;
    bool thread_started;
    bool done;
    pthread_t thread;
    struct timespec started_at;
    bool has_started;

    int argc;
    char **argv;

    vp_state_callback callback;
    void *callback_context;

    _Atomic uint64_t frames_read;
    _Atomic uint64_t touches_sent;
    _Atomic uint64_t buttons_sent;

    char error[512];
};

/* QEMU's globals make a second machine in one process impossible. */
static atomic_bool g_spent = false;

static void set_error(vp_emulator *emu, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    pthread_mutex_lock(&emu->lock);
    vsnprintf(emu->error, sizeof emu->error, fmt, ap);
    pthread_mutex_unlock(&emu->lock);
    va_end(ap);
}

static void transition(vp_emulator *emu, vp_state state, int32_t detail)
{
    vp_state_callback cb;
    void *ctx;

    pthread_mutex_lock(&emu->lock);
    /* STOPPED and FAILED are final: nothing may move a machine out of them. */
    if (emu->state == VP_STATE_STOPPED || emu->state == VP_STATE_FAILED) {
        pthread_mutex_unlock(&emu->lock);
        return;
    }
    emu->state = state;
    if (state == VP_STATE_RUNNING && !emu->has_started) {
        clock_gettime(CLOCK_MONOTONIC, &emu->started_at);
        emu->has_started = true;
    }
    cb = emu->callback;
    ctx = emu->callback_context;
    pthread_mutex_unlock(&emu->lock);

    if (cb)
        cb(ctx, state, detail);
}

/* Fires the callback for a state set while holding the lock. */
static void notify(vp_emulator *emu, vp_state state, int32_t detail)
{
    vp_state_callback cb;
    void *ctx;
    pthread_mutex_lock(&emu->lock);
    cb = emu->callback;
    ctx = emu->callback_context;
    pthread_mutex_unlock(&emu->lock);
    if (cb)
        cb(ctx, state, detail);
}

static vp_state current(vp_emulator *emu)
{
    vp_state s;
    pthread_mutex_lock(&emu->lock);
    s = emu->state;
    pthread_mutex_unlock(&emu->lock);
    return s;
}

#define RESOLVE(field, name) (emu->field = (__typeof__(emu->field))dlsym(emu->handle, name))

static void resolve_symbols(vp_emulator *emu)
{
    RESOLVE(qemu_init, "qemu_init");
    RESOLVE(qemu_main_loop, "qemu_main_loop");
    RESOLVE(qemu_cleanup, "qemu_cleanup");

    RESOLVE(bql_lock, "bql_lock_impl");
    RESOLVE(bql_unlock, "bql_unlock");
    RESOLVE(bql_locked, "bql_locked");
    RESOLVE(vm_start, "vm_start");
    RESOLVE(vmstop_prepare, "qemu_system_vmstop_request_prepare");
    RESOLVE(vmstop_request, "qemu_system_vmstop_request");
    RESOLVE(reset_request, "qemu_system_reset_request");
    RESOLVE(shutdown_request, "qemu_system_shutdown_request");

    RESOLVE(display_attach, "inferno_display_attach");
    RESOLVE(display_invalidate, "inferno_display_invalidate");
    RESOLVE(display_read, "inferno_display_read");
    RESOLVE(display_stats, "inferno_display_stats");
    RESOLVE(input_touch, "inferno_input_touch");
    RESOLVE(input_key, "inferno_input_function_key");
    RESOLVE(net_link_up, "inferno_net_link_up");
    RESOLVE(battery_set, "inferno_battery_set");

    emu->caps = 0;
    if (emu->display_attach && emu->display_read)
        emu->caps |= VP_CAP_DISPLAY;
    if (emu->input_touch)
        emu->caps |= VP_CAP_TOUCH;
    if (emu->input_key)
        emu->caps |= VP_CAP_BUTTONS;
    if (emu->vmstop_prepare && emu->vmstop_request && emu->vm_start && emu->bql_lock &&
        emu->bql_unlock)
        emu->caps |= VP_CAP_PAUSE;
    if (emu->reset_request)
        emu->caps |= VP_CAP_RESET;
    if (emu->shutdown_request)
        emu->caps |= VP_CAP_STOP;
    if (emu->display_stats)
        emu->caps |= VP_CAP_STATS;
    if (emu->net_link_up)
        emu->caps |= VP_CAP_NET_STATUS;
    if (emu->battery_set)
        emu->caps |= VP_CAP_BATTERY;
}

vp_emulator *vp_emulator_create(const char *library_path, char *error, size_t error_size)
{
    vp_emulator *emu;
    void *handle;

    if (!library_path || !*library_path) {
        if (error && error_size)
            snprintf(error, error_size, "no library path");
        return NULL;
    }
    handle = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        if (error && error_size)
            snprintf(error, error_size, "dlopen failed: %s", dlerror());
        return NULL;
    }
    emu = calloc(1, sizeof *emu);
    if (!emu) {
        if (error && error_size)
            snprintf(error, error_size, "out of memory");
        return NULL;
    }
    emu->handle = handle;
    pthread_mutex_init(&emu->lock, NULL);
    pthread_mutex_init(&emu->control, NULL);
    pthread_cond_init(&emu->done_cond, NULL);
    resolve_symbols(emu);

    if (!emu->qemu_init || !emu->qemu_main_loop || !emu->qemu_cleanup) {
        if (error && error_size)
            snprintf(error, error_size,
                     "%s does not export qemu_init/qemu_main_loop/qemu_cleanup "
                     "(was it built with -Dshared_lib=true?)",
                     library_path);
        pthread_cond_destroy(&emu->done_cond);
        pthread_mutex_destroy(&emu->control);
        pthread_mutex_destroy(&emu->lock);
        free(emu);
        return NULL;
    }
    emu->state = VP_STATE_IDLE;
    snprintf(emu->error, sizeof emu->error, "no error");
    return emu;
}

int vp_emulator_destroy(vp_emulator *emu)
{
    vp_state s;
    bool joinable;

    if (!emu)
        return VP_ERR_INVALID;
    pthread_mutex_lock(&emu->lock);
    s = emu->state;
    joinable = emu->thread_started;
    pthread_mutex_unlock(&emu->lock);
    if (s != VP_STATE_IDLE && s != VP_STATE_STOPPED && s != VP_STATE_FAILED)
        return VP_ERR_STATE;
    if (joinable)
        pthread_join(emu->thread, NULL);
    if (emu->argv) {
        for (int i = 0; emu->argv[i]; i++)
            free(emu->argv[i]);
        free(emu->argv);
    }
    pthread_cond_destroy(&emu->done_cond);
    pthread_mutex_destroy(&emu->control);
    pthread_mutex_destroy(&emu->lock);
    free(emu);
    return VP_OK;
}

void vp_emulator_set_state_callback(vp_emulator *emu, vp_state_callback cb, void *context)
{
    if (!emu)
        return;
    pthread_mutex_lock(&emu->lock);
    emu->callback = cb;
    emu->callback_context = context;
    pthread_mutex_unlock(&emu->lock);
}

static void *emulator_thread(void *arg)
{
    vp_emulator *emu = arg;
    vp_state_callback cb;
    void *ctx;
    int status;

    /* qemu_init calls exit() on a bad command line; the Swift side validates
     * the configuration first because nothing here can catch that. */
    emu->qemu_init(emu->argc, emu->argv);

    /* qemu_init returns holding the BQL: the one moment a display listener
     * may be registered from outside the main loop. */
    if (emu->display_attach)
        emu->display_attach();

    transition(emu, VP_STATE_RUNNING, 0);
    status = emu->qemu_main_loop();
    atomic_store(&emu->loop_exited, true); /* still holding the BQL */
    emu->qemu_cleanup(status);

    /* A thread that ends holding the BQL leaves it held for good, and exit
     * notifiers then deadlock on it. */
    if (emu->bql_locked && emu->bql_unlock && emu->bql_locked())
        emu->bql_unlock();

    /* STOPPED is published first, so anyone woken by vp_emulator_wait (and
     * any destroy after it) sees it; the callback runs next; `done` last, so
     * wait returns only once the callback has been delivered. destroy joins
     * this thread, so nothing is freed underneath the callback. */
    pthread_mutex_lock(&emu->control);
    pthread_mutex_lock(&emu->lock);
    emu->exit_status = status;
    emu->state = VP_STATE_STOPPED;
    cb = emu->callback;
    ctx = emu->callback_context;
    pthread_mutex_unlock(&emu->lock);
    pthread_mutex_unlock(&emu->control);

    if (cb)
        cb(ctx, VP_STATE_STOPPED, status);

    pthread_mutex_lock(&emu->lock);
    emu->done = true;
    pthread_cond_broadcast(&emu->done_cond);
    pthread_mutex_unlock(&emu->lock);
    return NULL;
}

int vp_emulator_start(vp_emulator *emu, int argc, const char *const *argv)
{
    pthread_attr_t attr;
    bool expected = false;
    int rc;

    if (!emu || argc < 1 || !argv)
        return VP_ERR_INVALID;
    for (int i = 0; i < argc; i++)
        if (!argv[i])
            return VP_ERR_INVALID;

    if (current(emu) != VP_STATE_IDLE) {
        set_error(emu, "start: machine is %s", vp_state_name(current(emu)));
        return VP_ERR_STATE;
    }
    if (!atomic_compare_exchange_strong(&g_spent, &expected, true)) {
        set_error(emu, "this process already ran a machine; relaunch the app to start another");
        return VP_ERR_SPENT;
    }

    /* Until the thread runs, QEMU has not been touched: a failure here gives
     * the process back its one start. */
    emu->argv = calloc((size_t)argc + 1, sizeof(char *));
    if (!emu->argv) {
        atomic_store(&g_spent, false);
        set_error(emu, "out of memory");
        return VP_ERR_SYSTEM;
    }
    for (int i = 0; i < argc; i++) {
        emu->argv[i] = strdup(argv[i]);
        if (!emu->argv[i]) {
            atomic_store(&g_spent, false);
            set_error(emu, "out of memory");
            return VP_ERR_SYSTEM;
        }
    }
    emu->argc = argc;

    transition(emu, VP_STATE_STARTING, 0);

    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, VP_EMULATOR_STACK);
    rc = pthread_create(&emu->thread, &attr, emulator_thread, emu);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        atomic_store(&g_spent, false);
        set_error(emu, "pthread_create: %s", strerror(rc));
        pthread_mutex_lock(&emu->lock);
        emu->state = VP_STATE_IDLE;
        pthread_mutex_unlock(&emu->lock);
        notify(emu, VP_STATE_IDLE, VP_ERR_SYSTEM);
        return VP_ERR_SYSTEM;
    }
    pthread_mutex_lock(&emu->lock);
    emu->thread_started = true;
    pthread_mutex_unlock(&emu->lock);
    return VP_OK;
}

/*
 * Pause, resume, reset and stop hold `control` from their state check to the
 * state change, and the emulator thread takes it before publishing STOPPED,
 * so no request can interleave with the machine ending. Lock order is
 * control → BQL → lock everywhere (the emulator thread takes `lock` with the
 * BQL held right after qemu_init).
 */
static vp_state locked_state(vp_emulator *emu)
{
    return current(emu);
}

static void set_state(vp_emulator *emu, vp_state state)
{
    pthread_mutex_lock(&emu->lock);
    emu->state = state;
    pthread_mutex_unlock(&emu->lock);
}

static int refuse(vp_emulator *emu, const char *what, vp_state s)
{
    pthread_mutex_unlock(&emu->control);
    set_error(emu, "%s: machine is %s", what, vp_state_name(s));
    return VP_ERR_STATE;
}

int vp_emulator_pause(vp_emulator *emu)
{
    vp_state s;
    if (!emu)
        return VP_ERR_INVALID;
    if (!(emu->caps & VP_CAP_PAUSE))
        return VP_ERR_UNSUPPORTED;
    pthread_mutex_lock(&emu->control);
    s = locked_state(emu);
    if (s != VP_STATE_RUNNING || atomic_load(&emu->loop_exited))
        return refuse(emu, "pause", s);
    /* The vmstop request is QEMU's own cross-thread path (vCPUs use it). */
    emu->vmstop_prepare();
    emu->vmstop_request(RUN_STATE_PAUSED);
    set_state(emu, VP_STATE_PAUSED);
    pthread_mutex_unlock(&emu->control);
    notify(emu, VP_STATE_PAUSED, 0);
    return VP_OK;
}

int vp_emulator_resume(vp_emulator *emu)
{
    vp_state s;
    if (!emu)
        return VP_ERR_INVALID;
    if (!(emu->caps & VP_CAP_PAUSE))
        return VP_ERR_UNSUPPORTED;
    pthread_mutex_lock(&emu->control);
    s = locked_state(emu);
    if (s != VP_STATE_PAUSED)
        return refuse(emu, "resume", s);
    emu->bql_lock(__FILE__, __LINE__);
    /* Checked under the BQL: the loop may have ended while we waited for it. */
    if (atomic_load(&emu->loop_exited)) {
        emu->bql_unlock();
        return refuse(emu, "resume", VP_STATE_STOPPING);
    }
    emu->vm_start();
    emu->bql_unlock();
    set_state(emu, VP_STATE_RUNNING);
    pthread_mutex_unlock(&emu->control);
    notify(emu, VP_STATE_RUNNING, 0);
    return VP_OK;
}

int vp_emulator_reset(vp_emulator *emu)
{
    vp_state s;
    if (!emu)
        return VP_ERR_INVALID;
    if (!(emu->caps & VP_CAP_RESET))
        return VP_ERR_UNSUPPORTED;
    pthread_mutex_lock(&emu->control);
    s = locked_state(emu);
    if ((s != VP_STATE_RUNNING && s != VP_STATE_PAUSED) || atomic_load(&emu->loop_exited))
        return refuse(emu, "reset", s);
    emu->reset_request(SHUTDOWN_CAUSE_HOST_UI);
    pthread_mutex_unlock(&emu->control);
    return VP_OK;
}

int vp_emulator_stop(vp_emulator *emu)
{
    vp_state s;
    if (!emu)
        return VP_ERR_INVALID;
    if (!(emu->caps & VP_CAP_STOP))
        return VP_ERR_UNSUPPORTED;
    pthread_mutex_lock(&emu->control);
    s = locked_state(emu);
    if (s == VP_STATE_STOPPING || s == VP_STATE_STOPPED) {
        pthread_mutex_unlock(&emu->control);
        return VP_OK;
    }
    if (s != VP_STATE_RUNNING && s != VP_STATE_PAUSED)
        return refuse(emu, "stop", s);
    set_state(emu, VP_STATE_STOPPING);
    emu->shutdown_request(SHUTDOWN_CAUSE_HOST_UI);
    pthread_mutex_unlock(&emu->control);
    notify(emu, VP_STATE_STOPPING, 0);
    return VP_OK;
}

bool vp_emulator_wait(vp_emulator *emu, uint32_t timeout_ms)
{
    struct timespec deadline;
    bool done;

    if (!emu)
        return false;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&emu->lock);
    while (emu->thread_started && !emu->done) {
        if (pthread_cond_timedwait(&emu->done_cond, &emu->lock, &deadline) == ETIMEDOUT)
            break;
    }
    done = emu->done;
    pthread_mutex_unlock(&emu->lock);
    return done;
}

static bool machine_live(vp_emulator *emu)
{
    vp_state s = current(emu);
    return s == VP_STATE_RUNNING || s == VP_STATE_PAUSED;
}

int vp_emulator_set_touch(vp_emulator *emu, int32_t x, int32_t y, bool pressed)
{
    if (!emu)
        return VP_ERR_INVALID;
    if (!emu->input_touch)
        return VP_ERR_UNSUPPORTED;
    if (!machine_live(emu))
        return VP_ERR_STATE;
    if (x < 0 || y < 0)
        return VP_ERR_INVALID;
    emu->input_touch(x, y, pressed);
    atomic_fetch_add(&emu->touches_sent, 1);
    return VP_OK;
}

uint32_t vp_button_function_key(vp_button button)
{
    /* hw/input/buttons.c in the emulator. */
    switch (button) {
    case VP_BUTTON_FORCE_SHUTDOWN:
        return 1;
    case VP_BUTTON_RINGER:
        return 2;
    case VP_BUTTON_VOLUME_DOWN:
        return 3;
    case VP_BUTTON_VOLUME_UP:
        return 4;
    case VP_BUTTON_SIDE:
        return 5;
    case VP_BUTTON_HOME:
        return 6;
    default:
        return 0;
    }
}

int vp_emulator_button_event(vp_emulator *emu, vp_button button, bool pressed)
{
    uint32_t key;
    if (!emu)
        return VP_ERR_INVALID;
    key = vp_button_function_key(button);
    if (!key)
        return VP_ERR_INVALID;
    if (!emu->input_key)
        return VP_ERR_UNSUPPORTED;
    if (!machine_live(emu))
        return VP_ERR_STATE;
    emu->input_key(key, pressed);
    atomic_fetch_add(&emu->buttons_sent, 1);
    return VP_OK;
}

int vp_emulator_set_battery(vp_emulator *emu, int32_t percent, bool external, bool charging)
{
    if (!emu)
        return VP_ERR_INVALID;
    if (!emu->battery_set)
        return VP_ERR_UNSUPPORTED;
    if (percent < 0 || percent > 100)
        return VP_ERR_INVALID;
    /* Safe before the machine exists: the SMC starts with the last value. */
    emu->battery_set(percent, external, charging);
    return VP_OK;
}

vp_frame_result vp_emulator_framebuffer(vp_emulator *emu, void *dst, size_t dst_size,
                                        vp_frame_info *info)
{
    int r;
    if (!emu || !info || !emu->display_read || !machine_live(emu))
        return VP_FRAME_UNAVAILABLE;
    r = (int)emu->display_read(dst, dst_size, (InfernoFrameInfo *)info);
    switch (r) {
    case VP_FRAME_NONE:
        return VP_FRAME_NONE;
    case VP_FRAME_OK:
        atomic_fetch_add(&emu->frames_read, 1);
        return VP_FRAME_OK;
    case VP_FRAME_RESIZE:
        return VP_FRAME_RESIZE;
    default:
        return VP_FRAME_UNAVAILABLE;
    }
}

void vp_emulator_invalidate_display(vp_emulator *emu)
{
    if (emu && emu->display_invalidate && machine_live(emu))
        emu->display_invalidate();
}

void vp_emulator_get_metrics(vp_emulator *emu, vp_metrics *out)
{
    struct timespec now;
    InfernoDisplayStats stats = {0, 0};

    if (!out)
        return;
    memset(out, 0, sizeof *out);
    if (!emu)
        return;
    if (emu->display_stats && machine_live(emu))
        emu->display_stats(&stats);
    out->frames_presented = stats.presents;
    out->display_refreshes = stats.refreshes;
    out->frames_read = atomic_load(&emu->frames_read);
    out->touches_sent = atomic_load(&emu->touches_sent);
    out->buttons_sent = atomic_load(&emu->buttons_sent);
    out->net_link_up = emu->net_link_up && machine_live(emu) ? emu->net_link_up() : false;

    pthread_mutex_lock(&emu->lock);
    out->state = (uint32_t)emu->state;
    out->exit_status = emu->exit_status;
    if (emu->has_started) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        out->uptime_ms = (uint64_t)(now.tv_sec - emu->started_at.tv_sec) * 1000u +
                         (uint64_t)((now.tv_nsec - emu->started_at.tv_nsec) / 1000000L);
    }
    pthread_mutex_unlock(&emu->lock);
}

vp_state vp_emulator_state(const vp_emulator *emu)
{
    if (!emu)
        return VP_STATE_FAILED;
    return current((vp_emulator *)emu);
}

uint32_t vp_emulator_capabilities(const vp_emulator *emu)
{
    return emu ? emu->caps : 0;
}

const char *vp_emulator_last_error(vp_emulator *emu)
{
    /* A per-thread copy: set_error may rewrite emu->error concurrently. */
    static _Thread_local char copy[sizeof(((vp_emulator *)0)->error)];
    if (!emu)
        return "no emulator";
    pthread_mutex_lock(&emu->lock);
    memcpy(copy, emu->error, sizeof copy);
    pthread_mutex_unlock(&emu->lock);
    return copy;
}

const char *vp_state_name(vp_state state)
{
    switch (state) {
    case VP_STATE_IDLE:
        return "idle";
    case VP_STATE_STARTING:
        return "starting";
    case VP_STATE_RUNNING:
        return "running";
    case VP_STATE_PAUSED:
        return "paused";
    case VP_STATE_STOPPING:
        return "stopping";
    case VP_STATE_STOPPED:
        return "stopped";
    case VP_STATE_FAILED:
        return "failed";
    }
    return "unknown";
}
