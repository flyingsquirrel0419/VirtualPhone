/*
 * A stand-in for libqemu-aarch64-softmmu that exports the same entry points
 * the runtime bridge resolves, so the bridge can be exercised on any host
 * without an emulator build or a guest image.
 *
 * Build with -DMOCK_MINIMAL to export only qemu_init/main_loop/cleanup, which
 * is what an emulator built without the embed patches looks like.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include "vp_inferno_abi.h"

#define EXPORT __attribute__((visibility("default")))

static atomic_int g_shutdown;
static atomic_int g_argc;
static atomic_int g_cleanup_status = -1;
static pthread_mutex_t g_bql = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local bool g_bql_held;

static void msleep(int ms)
{
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}

EXPORT void qemu_init(int argc, char **argv)
{
    (void)argv;
    atomic_store(&g_argc, argc);
    pthread_mutex_lock(&g_bql);
    g_bql_held = true;
}

EXPORT int qemu_main_loop(void)
{
    /* The real loop runs with the BQL dropped while it waits. */
    while (!atomic_load(&g_shutdown)) {
        g_bql_held = false;
        pthread_mutex_unlock(&g_bql);
        msleep(2);
        pthread_mutex_lock(&g_bql);
        g_bql_held = true;
    }
    return 42;
}

EXPORT void qemu_cleanup(int status)
{
    atomic_store(&g_cleanup_status, status);
}

EXPORT void qemu_system_shutdown_request(ShutdownCause cause)
{
    (void)cause;
    atomic_store(&g_shutdown, 1);
}

/* ---- test probes ---------------------------------------------------- */
EXPORT int mock_argc(void)
{
    return atomic_load(&g_argc);
}
EXPORT int mock_cleanup_status(void)
{
    return atomic_load(&g_cleanup_status);
}

#ifndef MOCK_MINIMAL

enum { W = 64, H = 32 };
static atomic_int g_reset_count;
static atomic_int g_paused;
static atomic_int g_attached;
static atomic_int g_dirty = 1;
static atomic_int g_generation = 1;
static atomic_int g_last_x = -1, g_last_y = -1, g_last_pressed = -1;
static atomic_int g_last_key, g_last_key_pressed = -1;
static atomic_int g_battery = -1;

EXPORT void bql_lock_impl(const char *file, int line)
{
    (void)file;
    (void)line;
    pthread_mutex_lock(&g_bql);
    g_bql_held = true;
}

EXPORT void bql_unlock(void)
{
    g_bql_held = false;
    pthread_mutex_unlock(&g_bql);
}

EXPORT bool bql_locked(void)
{
    return g_bql_held;
}

EXPORT void vm_start(void)
{
    atomic_store(&g_paused, 0);
}
EXPORT void qemu_system_vmstop_request_prepare(void) {}
EXPORT void qemu_system_vmstop_request(RunState state)
{
    if (state == RUN_STATE_PAUSED)
        atomic_store(&g_paused, 1);
}
EXPORT void qemu_system_reset_request(ShutdownCause cause)
{
    (void)cause;
    atomic_fetch_add(&g_reset_count, 1);
}

EXPORT void inferno_display_attach(void)
{
    atomic_store(&g_attached, 1);
}
EXPORT void inferno_display_invalidate(void)
{
    atomic_store(&g_dirty, 1);
}

EXPORT InfernoFrameResult inferno_display_read(void *dst, size_t size, InfernoFrameInfo *info)
{
    info->width = W;
    info->height = H;
    info->stride = W * 4;
    info->generation = (uint32_t)atomic_load(&g_generation);
    if (!atomic_load(&g_attached))
        return INFERNO_FRAME_NONE;
    if (!dst || size < (size_t)W * H * 4) {
        info->x = info->y = 0;
        info->w = W;
        info->h = H;
        return INFERNO_FRAME_RESIZE;
    }
    if (!atomic_exchange(&g_dirty, 0))
        return INFERNO_FRAME_NONE;
    for (uint32_t i = 0; i < (uint32_t)W * H; i++)
        ((uint32_t *)dst)[i] = 0xFF000000u | i;
    info->x = info->y = 0;
    info->w = W;
    info->h = H;
    return INFERNO_FRAME_OK;
}

EXPORT void inferno_display_stats(InfernoDisplayStats *out)
{
    out->presents = 7;
    out->refreshes = 9;
}

EXPORT void inferno_input_touch(int32_t x, int32_t y, bool pressed)
{
    atomic_store(&g_last_x, x);
    atomic_store(&g_last_y, y);
    atomic_store(&g_last_pressed, pressed);
}

EXPORT void inferno_input_function_key(uint32_t number, bool pressed)
{
    atomic_store(&g_last_key, (int)number);
    atomic_store(&g_last_key_pressed, pressed);
}

EXPORT bool inferno_net_link_up(void)
{
    return true;
}
EXPORT void inferno_battery_set(int32_t percent, bool external, bool charging)
{
    (void)external;
    (void)charging;
    atomic_store(&g_battery, percent);
}

EXPORT int mock_paused(void)
{
    return atomic_load(&g_paused);
}
EXPORT int mock_reset_count(void)
{
    return atomic_load(&g_reset_count);
}
EXPORT int mock_attached(void)
{
    return atomic_load(&g_attached);
}
EXPORT void mock_last_touch(int *x, int *y, int *pressed)
{
    *x = atomic_load(&g_last_x);
    *y = atomic_load(&g_last_y);
    *pressed = atomic_load(&g_last_pressed);
}
EXPORT void mock_last_key(int *key, int *pressed)
{
    *key = atomic_load(&g_last_key);
    *pressed = atomic_load(&g_last_key_pressed);
}
EXPORT int mock_battery(void)
{
    return atomic_load(&g_battery);
}

#endif /* MOCK_MINIMAL */
