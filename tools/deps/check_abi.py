#!/usr/bin/env python3
"""Checks app/Runtime/vp_inferno_abi.h against a checked-out emulator tree.

    check_abi.py EMULATOR_SRC

The bridge calls the emulator through function pointers typed by that header.
If the pinned emulator changes a signature, a struct layout or an enum value,
this fails before any macOS minute is spent.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Declarations that must appear verbatim (modulo whitespace) in the fork's header.
EMBED_DECLS = [
    "void inferno_display_attach(void);",
    "void inferno_display_invalidate(void);",
    "InfernoFrameResult inferno_display_read(void* dst, size_t dst_size, InfernoFrameInfo* info);",
    "void inferno_display_stats(InfernoDisplayStats* out);",
    "void inferno_input_touch(int32_t x, int32_t y, bool pressed);",
    "void inferno_input_function_key(uint32_t number, bool pressed);",
    "bool inferno_net_link_up(void);",
    "void inferno_battery_set(int32_t percent, bool external, bool charging);",
    "uint32_t width; uint32_t height; uint32_t stride; uint32_t x, y, w, h; uint32_t generation;",
    "uint64_t presents; uint64_t refreshes;",
    "INFERNO_FRAME_NONE = 0,",
    "INFERNO_FRAME_OK = 1,",
    "INFERNO_FRAME_RESIZE = 2,",
]
RUNSTATE_DECLS = [
    "void vm_start(void);",
    "void qemu_system_reset_request(ShutdownCause reason);",
    "void qemu_system_shutdown_request(ShutdownCause reason);",
    "void qemu_system_vmstop_request(RunState reason);",
    "void qemu_system_vmstop_request_prepare(void);",
]
MAIN_LOOP_DECLS = [
    "void bql_lock_impl(const char* file, int line);",
    "void bql_unlock(void);",
    "bool bql_locked(void);",
]
ENUMS = {"RunState": ("paused", 3), "ShutdownCause": ("host-ui", 5)}


def squash(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r"\s+", " ", text)
    return re.sub(r"\s*\*\s*", "* ", text)  # normalise pointer spacing


def contains(haystack: str, decl: str) -> bool:
    return squash(decl).strip() in haystack


def enum_index(qapi: str, name: str, member: str) -> int | None:
    m = re.search(r"'enum':\s*'" + name + r"'.*?'data':\s*\[(.*?)\]", qapi, re.S)
    if not m:
        return None
    members = re.findall(r"'([a-z0-9-]+)'", re.sub(r"#[^\n]*", "", m.group(1)))
    return members.index(member) if member in members else None


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    src = Path(argv[0])
    problems = []
    checks = [
        (src / "include/ui/inferno-embed.h", EMBED_DECLS),
        (src / "include/system/runstate.h", RUNSTATE_DECLS),
        (src / "include/qemu/main-loop.h", MAIN_LOOP_DECLS),
    ]
    for header, decls in checks:
        if not header.exists():
            problems.append(f"missing {header.relative_to(src)}")
            continue
        text = squash(header.read_text())
        problems += [f"{header.relative_to(src)}: no `{d}`" for d in decls if not contains(text, d)]

    qapi = (src / "qapi/run-state.json").read_text()
    for enum, (member, want) in ENUMS.items():
        got = enum_index(qapi, enum, member)
        if got != want:
            problems.append(f"qapi {enum}.{member} is {got}, bridge assumes {want}")

    for p in problems:
        print(f"ABI MISMATCH: {p}")
    if problems:
        return 1
    print(f"ABI OK: {sum(len(d) for _, d in checks) + len(ENUMS)} declarations match {src}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
