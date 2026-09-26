/*
 * Level C tests for the runtime bridge, against mock_qemu.
 *
 *   test_runtime <scenario> <mock library> [minimal mock library]
 *
 * One scenario per process: the bridge refuses a second machine in one
 * process, exactly as QEMU requires, so that rule is itself a scenario.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "vp_runtime.h"

#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                      \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

static void msleep(int ms)
{
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}

static bool wait_for(vp_emulator *emu, vp_state want, int ms)
{
    for (int i = 0; i < ms; i++) {
        if (vp_emulator_state(emu) == want)
            return true;
        msleep(1);
    }
    return vp_emulator_state(emu) == want;
}

static atomic_int transitions[8];
static void on_state(void *ctx, vp_state state, int32_t detail)
{
    (void)ctx;
    (void)detail;
    if ((unsigned)state < 8)
        atomic_fetch_add(&transitions[state], 1);
}

static const char *const ARGV[] = {"qemu-system-aarch64", "-M", "t8030", "-display", "none"};

static void *probe(const char *lib, const char *name)
{
    void *h = dlopen(lib, RTLD_NOW | RTLD_NOLOAD);
    return h ? dlsym(h, name) : NULL;
}

static void scenario_full(const char *lib)
{
    char err[256] = "";
    vp_emulator *emu = vp_emulator_create(lib, err, sizeof err);
    CHECK(emu != NULL);
    if (!emu) {
        fprintf(stderr, "  %s\n", err);
        return;
    }
    vp_emulator_set_state_callback(emu, on_state, NULL);

    uint32_t caps = vp_emulator_capabilities(emu);
    CHECK(caps & VP_CAP_DISPLAY);
    CHECK(caps & VP_CAP_TOUCH);
    CHECK(caps & VP_CAP_BUTTONS);
    CHECK(caps & VP_CAP_PAUSE);
    CHECK(caps & VP_CAP_RESET);
    CHECK(caps & VP_CAP_STOP);
    CHECK(caps & VP_CAP_STATS);
    CHECK(caps & VP_CAP_NET_STATUS);
    CHECK(caps & VP_CAP_BATTERY);
    CHECK(vp_emulator_state(emu) == VP_STATE_IDLE);

    /* Nothing reaches the machine before it exists. */
    CHECK(vp_emulator_set_touch(emu, 1, 1, true) == VP_ERR_STATE);
    CHECK(vp_emulator_pause(emu) == VP_ERR_STATE);
    vp_frame_info info;
    CHECK(vp_emulator_framebuffer(emu, NULL, 0, &info) == VP_FRAME_UNAVAILABLE);
    /* Battery is allowed early: the SMC keeps it for boot. */
    CHECK(vp_emulator_set_battery(emu, 80, true, false) == VP_OK);
    CHECK(vp_emulator_set_battery(emu, 101, true, false) == VP_ERR_INVALID);

    CHECK(vp_emulator_start(emu, 0, ARGV) == VP_ERR_INVALID);
    CHECK(vp_emulator_start(emu, 5, ARGV) == VP_OK);
    CHECK(wait_for(emu, VP_STATE_RUNNING, 2000));
    CHECK(vp_emulator_start(emu, 5, ARGV) == VP_ERR_STATE);

    int (*argc_probe)(void) = (int (*)(void))probe(lib, "mock_argc");
    CHECK(argc_probe && argc_probe() == 5);
    int (*attached)(void) = (int (*)(void))probe(lib, "mock_attached");
    CHECK(attached && attached() == 1);

    /* Framebuffer: resize first, then a full frame, then nothing new. */
    CHECK(vp_emulator_framebuffer(emu, NULL, 0, &info) == VP_FRAME_RESIZE);
    CHECK(info.width == 64 && info.height == 32 && info.stride == 256);
    size_t size = (size_t)info.stride * info.height;
    uint32_t *fb = calloc(1, size);
    CHECK(vp_emulator_framebuffer(emu, fb, size, &info) == VP_FRAME_OK);
    CHECK(fb[0] == 0xFF000000u && fb[5] == 0xFF000005u);
    CHECK(vp_emulator_framebuffer(emu, fb, size, &info) == VP_FRAME_NONE);
    vp_emulator_invalidate_display(emu);
    CHECK(vp_emulator_framebuffer(emu, fb, size, &info) == VP_FRAME_OK);
    free(fb);

    /* Input. */
    int x, y, pressed, key;
    CHECK(vp_emulator_set_touch(emu, 10, 20, true) == VP_OK);
    CHECK(vp_emulator_set_touch(emu, -1, 20, true) == VP_ERR_INVALID);
    void (*last_touch)(int *, int *, int *) =
        (void (*)(int *, int *, int *))probe(lib, "mock_last_touch");
    last_touch(&x, &y, &pressed);
    CHECK(x == 10 && y == 20 && pressed == 1);

    void (*last_key)(int *, int *) = (void (*)(int *, int *))probe(lib, "mock_last_key");
    const struct {
        vp_button b;
        int f;
    } keys[] = {
        {VP_BUTTON_HOME, 6},        {VP_BUTTON_SIDE, 5},   {VP_BUTTON_VOLUME_UP, 4},
        {VP_BUTTON_VOLUME_DOWN, 3}, {VP_BUTTON_RINGER, 2}, {VP_BUTTON_FORCE_SHUTDOWN, 1},
    };
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        CHECK(vp_emulator_button_event(emu, keys[i].b, true) == VP_OK);
        last_key(&key, &pressed);
        CHECK(key == keys[i].f && pressed == 1);
    }
    CHECK(vp_emulator_button_event(emu, VP_BUTTON_COUNT, true) == VP_ERR_INVALID);

    /* Pause, resume, reset. */
    int (*paused)(void) = (int (*)(void))probe(lib, "mock_paused");
    CHECK(vp_emulator_pause(emu) == VP_OK);
    CHECK(vp_emulator_state(emu) == VP_STATE_PAUSED && paused() == 1);
    CHECK(vp_emulator_pause(emu) == VP_ERR_STATE);
    CHECK(vp_emulator_resume(emu) == VP_OK);
    CHECK(vp_emulator_state(emu) == VP_STATE_RUNNING && paused() == 0);
    CHECK(vp_emulator_reset(emu) == VP_OK);
    int (*resets)(void) = (int (*)(void))probe(lib, "mock_reset_count");
    CHECK(resets() == 1);

    vp_metrics m;
    msleep(5);
    vp_emulator_get_metrics(emu, &m);
    CHECK(m.frames_presented == 7 && m.display_refreshes == 9);
    CHECK(m.frames_read == 2 && m.touches_sent == 1 && m.buttons_sent == 6);
    CHECK(m.net_link_up);
    CHECK(m.state == VP_STATE_RUNNING);
    CHECK(m.uptime_ms >= 1);

    /* Stop, from pause, to make sure that path ends the loop too. */
    CHECK(vp_emulator_pause(emu) == VP_OK);
    CHECK(vp_emulator_stop(emu) == VP_OK);
    CHECK(vp_emulator_wait(emu, 3000));
    CHECK(vp_emulator_state(emu) == VP_STATE_STOPPED);
    CHECK(vp_emulator_stop(emu) == VP_OK); /* idempotent */
    vp_emulator_get_metrics(emu, &m);
    CHECK(m.exit_status == 42);
    int (*cleanup)(void) = (int (*)(void))probe(lib, "mock_cleanup_status");
    CHECK(cleanup() == 42);
    CHECK(vp_emulator_set_touch(emu, 1, 1, true) == VP_ERR_STATE);

    CHECK(atomic_load(&transitions[VP_STATE_STARTING]) == 1);
    CHECK(atomic_load(&transitions[VP_STATE_RUNNING]) == 2);
    CHECK(atomic_load(&transitions[VP_STATE_PAUSED]) == 2);
    CHECK(atomic_load(&transitions[VP_STATE_STOPPED]) == 1);
    CHECK(vp_emulator_destroy(emu) == VP_OK);
}

static void scenario_spent(const char *lib)
{
    vp_emulator *a = vp_emulator_create(lib, NULL, 0);
    vp_emulator *b = vp_emulator_create(lib, NULL, 0);
    CHECK(a && b);
    CHECK(vp_emulator_start(a, 5, ARGV) == VP_OK);
    CHECK(vp_emulator_start(b, 5, ARGV) == VP_ERR_SPENT);
    CHECK(strstr(vp_emulator_last_error(b), "relaunch") != NULL);
    CHECK(wait_for(a, VP_STATE_RUNNING, 2000));
    CHECK(vp_emulator_destroy(a) == VP_ERR_STATE); /* still running */
    CHECK(vp_emulator_stop(a) == VP_OK);
    CHECK(vp_emulator_wait(a, 3000));
    CHECK(vp_emulator_destroy(a) == VP_OK);
    CHECK(vp_emulator_destroy(b) == VP_OK); /* never started */
}

static void scenario_minimal(const char *lib)
{
    vp_emulator *emu = vp_emulator_create(lib, NULL, 0);
    CHECK(emu != NULL);
    uint32_t caps = vp_emulator_capabilities(emu);
    CHECK(caps == VP_CAP_STOP);
    CHECK(vp_emulator_start(emu, 5, ARGV) == VP_OK);
    CHECK(wait_for(emu, VP_STATE_RUNNING, 2000));
    vp_frame_info info;
    CHECK(vp_emulator_framebuffer(emu, NULL, 0, &info) == VP_FRAME_UNAVAILABLE);
    CHECK(vp_emulator_set_touch(emu, 1, 1, true) == VP_ERR_UNSUPPORTED);
    CHECK(vp_emulator_button_event(emu, VP_BUTTON_HOME, true) == VP_ERR_UNSUPPORTED);
    CHECK(vp_emulator_pause(emu) == VP_ERR_UNSUPPORTED);
    CHECK(vp_emulator_reset(emu) == VP_ERR_UNSUPPORTED);
    CHECK(vp_emulator_set_battery(emu, 50, false, false) == VP_ERR_UNSUPPORTED);
    vp_metrics m;
    vp_emulator_get_metrics(emu, &m);
    CHECK(!m.net_link_up && m.frames_presented == 0);
    CHECK(vp_emulator_stop(emu) == VP_OK);
    CHECK(vp_emulator_wait(emu, 3000));
    CHECK(vp_emulator_destroy(emu) == VP_OK);
}

static void scenario_bad(void)
{
    char err[256] = "";
    CHECK(vp_emulator_create("/nonexistent/libqemu.so", err, sizeof err) == NULL);
    CHECK(strstr(err, "dlopen failed") != NULL);
    CHECK(vp_emulator_create("", err, sizeof err) == NULL);
    /* libc exists but is no emulator. */
    CHECK(vp_emulator_create("libc.so.6", err, sizeof err) == NULL);
    CHECK(strstr(err, "shared_lib") != NULL);

    /* NULL-safety of every entry point. */
    CHECK(vp_emulator_start(NULL, 1, ARGV) == VP_ERR_INVALID);
    CHECK(vp_emulator_stop(NULL) == VP_ERR_INVALID);
    CHECK(vp_emulator_state(NULL) == VP_STATE_FAILED);
    CHECK(vp_emulator_capabilities(NULL) == 0);
    CHECK(!vp_emulator_wait(NULL, 1));
    CHECK(vp_emulator_destroy(NULL) == VP_ERR_INVALID);
    vp_metrics m;
    vp_emulator_get_metrics(NULL, &m);
    CHECK(m.state == 0);
    CHECK(strcmp(vp_state_name(VP_STATE_PAUSED), "paused") == 0);
    CHECK(vp_button_function_key(VP_BUTTON_COUNT) == 0);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s full|spent|minimal|bad [lib]\n", argv[0]);
        return 2;
    }
    const char *s = argv[1];
    if (!strcmp(s, "full") && argc > 2)
        scenario_full(argv[2]);
    else if (!strcmp(s, "spent") && argc > 2)
        scenario_spent(argv[2]);
    else if (!strcmp(s, "minimal") && argc > 2)
        scenario_minimal(argv[2]);
    else if (!strcmp(s, "bad"))
        scenario_bad();
    else {
        fprintf(stderr, "unknown scenario or missing library: %s\n", s);
        return 2;
    }
    printf("%s %s (%d failure%s)\n", failures ? "FAIL" : "PASS", s, failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
