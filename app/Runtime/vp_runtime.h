/*
 * VirtualPhone runtime bridge.
 *
 * The one surface the Swift front end uses to drive the emulator. The
 * emulator is a shared library (Inferno built with -Dshared_lib=true) loaded
 * into this process; everything QEMU-specific — symbol names, the big lock,
 * enum values, the F-key wiring of the device buttons — stays behind this
 * header, so a change of emulator build touches vp_runtime.c and nothing else.
 *
 * Threading: vp_emulator_start() spawns the emulator thread, which runs
 * qemu_init and the main loop. Every other call is safe from any thread.
 *
 * QEMU keeps process-wide state and cannot be initialised twice, so one
 * process runs at most one machine, once. After the machine stops the app has
 * to be relaunched to start another (vp_emulator_start returns VP_ERR_SPENT).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef VP_RUNTIME_H
#define VP_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VP_RUNTIME_API_VERSION 1

typedef struct vp_emulator vp_emulator;

typedef enum vp_state {
    VP_STATE_IDLE = 0,     /* library loaded, machine not started */
    VP_STATE_STARTING = 1, /* qemu_init running */
    VP_STATE_RUNNING = 2,
    VP_STATE_PAUSED = 3,
    VP_STATE_STOPPING = 4, /* shutdown requested, main loop still turning */
    VP_STATE_STOPPED = 5,  /* main loop returned; detail is its status */
    VP_STATE_FAILED = 6,   /* see vp_emulator_last_error */
} vp_state;

typedef enum vp_error {
    VP_OK = 0,
    VP_ERR_INVALID = -1,     /* bad argument */
    VP_ERR_STATE = -2,       /* not allowed in the current state */
    VP_ERR_UNSUPPORTED = -3, /* the loaded library does not export what this needs */
    VP_ERR_SPENT = -4,       /* this process already ran a machine */
    VP_ERR_SYSTEM = -5,      /* thread creation or similar failed */
} vp_error;

/* Device buttons. Values are ours, not the machine's F-key numbers. */
typedef enum vp_button {
    VP_BUTTON_HOME = 0,
    VP_BUTTON_SIDE = 1,
    VP_BUTTON_VOLUME_UP = 2,
    VP_BUTTON_VOLUME_DOWN = 3,
    VP_BUTTON_RINGER = 4, /* toggles on press; release is ignored */
    VP_BUTTON_FORCE_SHUTDOWN = 5,
    VP_BUTTON_COUNT
} vp_button;

/* Optional features, reported by vp_emulator_capabilities(). */
enum {
    VP_CAP_DISPLAY = 1u << 0, /* in-process framebuffer */
    VP_CAP_TOUCH = 1u << 1,
    VP_CAP_BUTTONS = 1u << 2,
    VP_CAP_PAUSE = 1u << 3,
    VP_CAP_RESET = 1u << 4,
    VP_CAP_STOP = 1u << 5,
    VP_CAP_STATS = 1u << 6,
    VP_CAP_NET_STATUS = 1u << 7,
    VP_CAP_BATTERY = 1u << 8,
};

typedef enum vp_frame_result {
    VP_FRAME_NONE = 0,       /* nothing redrawn since the last call */
    VP_FRAME_OK = 1,         /* rows in info.{x,y,w,h} were copied */
    VP_FRAME_RESIZE = 2,     /* dst too small; info has the new size */
    VP_FRAME_UNAVAILABLE = 3 /* no machine, or no display support */
} vp_frame_result;

/* Layout mirrors the emulator's InfernoFrameInfo; checked at compile time. */
typedef struct vp_frame_info {
    uint32_t width;
    uint32_t height;
    uint32_t stride; /* bytes per destination row, width * 4 */
    uint32_t x, y, w, h;
    uint32_t generation;
} vp_frame_info;

typedef struct vp_metrics {
    uint64_t frames_presented; /* totals since the previous call */
    uint64_t display_refreshes;
    uint64_t frames_read; /* vp_emulator_framebuffer calls that returned OK */
    uint64_t touches_sent;
    uint64_t buttons_sent;
    uint64_t uptime_ms; /* since the machine entered RUNNING */
    int32_t exit_status;
    uint32_t state;
    bool net_link_up;
} vp_metrics;

typedef void (*vp_state_callback)(void *context, vp_state state, int32_t detail);

/*
 * Loads the emulator library. Returns NULL and fills `error` on failure.
 * The library is never unloaded: QEMU registers destructors and threads that
 * outlive any attempt to dlclose it.
 */
vp_emulator *vp_emulator_create(const char *library_path, char *error, size_t error_size);

/*
 * Frees the handle. Only when the machine never started, has stopped or has
 * failed: a running QEMU cannot be torn down from outside. The library stays
 * loaded. Returns VP_ERR_STATE (and frees nothing) otherwise.
 */
int vp_emulator_destroy(vp_emulator *emu);

/* Called on the emulator thread (or the caller's, for synchronous failures). */
void vp_emulator_set_state_callback(vp_emulator *emu, vp_state_callback cb, void *context);

/* argv is copied; argv[0] is the program name as QEMU expects. */
int vp_emulator_start(vp_emulator *emu, int argc, const char *const *argv);
int vp_emulator_pause(vp_emulator *emu);
int vp_emulator_resume(vp_emulator *emu);
int vp_emulator_reset(vp_emulator *emu);
/* Asks the guest machine to power off; returns at once. */
int vp_emulator_stop(vp_emulator *emu);
/* Waits up to timeout_ms for the emulator thread to finish. true if it did. */
bool vp_emulator_wait(vp_emulator *emu, uint32_t timeout_ms);

/* Absolute framebuffer pixel coordinates. */
int vp_emulator_set_touch(vp_emulator *emu, int32_t x, int32_t y, bool pressed);
int vp_emulator_button_event(vp_emulator *emu, vp_button button, bool pressed);
int vp_emulator_set_battery(vp_emulator *emu, int32_t percent, bool external, bool charging);

vp_frame_result vp_emulator_framebuffer(vp_emulator *emu, void *dst, size_t dst_size,
                                        vp_frame_info *info);
void vp_emulator_invalidate_display(vp_emulator *emu);

void vp_emulator_get_metrics(vp_emulator *emu, vp_metrics *out);
vp_state vp_emulator_state(const vp_emulator *emu);
uint32_t vp_emulator_capabilities(const vp_emulator *emu);
/* A copy owned by the calling thread, valid until its next call. Never NULL. */
const char *vp_emulator_last_error(vp_emulator *emu);
const char *vp_state_name(vp_state state);

/* The machine's F-key number for a button, 0 if none. Exposed for tests. */
uint32_t vp_button_function_key(vp_button button);

#ifdef __cplusplus
}
#endif

#endif /* VP_RUNTIME_H */
