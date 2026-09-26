/*
 * The emulator's exported ABI, as the bridge calls it.
 *
 * Mirrors include/ui/inferno-embed.h and the runstate declarations of the
 * emulator commit pinned in deps.lock, with the same type names, so a call
 * through a resolved pointer has exactly the callee's type. Linux CI checks
 * these declarations against the pinned tree (linux-ci.yml, emulator-patches).
 * Private to app/Runtime and tests/emulator.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef VP_INFERNO_ABI_H
#define VP_INFERNO_ABI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* qapi/run-state.json (generated enums; only the values the bridge uses). */
typedef enum RunState {
    RUN_STATE_PAUSED = 3,
} RunState;

typedef enum ShutdownCause {
    SHUTDOWN_CAUSE_HOST_UI = 5,
} ShutdownCause;

/* include/ui/inferno-embed.h */
typedef enum InfernoFrameResult {
    INFERNO_FRAME_NONE = 0,
    INFERNO_FRAME_OK = 1,
    INFERNO_FRAME_RESIZE = 2,
} InfernoFrameResult;

typedef struct InfernoFrameInfo {
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t x, y, w, h;
    uint32_t generation;
} InfernoFrameInfo;

typedef struct InfernoDisplayStats {
    uint64_t presents;
    uint64_t refreshes;
} InfernoDisplayStats;

typedef void (*qemu_init_fn)(int argc, char **argv);
typedef int (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(int status);

typedef void (*bql_lock_impl_fn)(const char *file, int line);
typedef void (*bql_unlock_fn)(void);
typedef bool (*bql_locked_fn)(void);
typedef void (*vm_start_fn)(void);
typedef void (*vmstop_request_prepare_fn)(void);
typedef void (*vmstop_request_fn)(RunState reason);
typedef void (*reset_request_fn)(ShutdownCause reason);
typedef void (*shutdown_request_fn)(ShutdownCause reason);

typedef void (*display_attach_fn)(void);
typedef void (*display_invalidate_fn)(void);
typedef InfernoFrameResult (*display_read_fn)(void *dst, size_t dst_size, InfernoFrameInfo *info);
typedef void (*display_stats_fn)(InfernoDisplayStats *out);
typedef void (*input_touch_fn)(int32_t x, int32_t y, bool pressed);
typedef void (*input_function_key_fn)(uint32_t number, bool pressed);
typedef bool (*net_link_up_fn)(void);
typedef void (*battery_set_fn)(int32_t percent, bool external, bool charging);

#endif /* VP_INFERNO_ABI_H */
