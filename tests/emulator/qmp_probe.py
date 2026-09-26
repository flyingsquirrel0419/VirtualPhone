#!/usr/bin/env python3
"""Asks a running QEMU over QMP what state it is in.

    qmp_probe.py PORT [EXPECTED_STATUS]

Prints the status ("running", "paused", …); with EXPECTED_STATUS, exits 1 on a
mismatch. Retries the connection for a few seconds while QEMU comes up.
"""
import json
import socket
import sys
import time


def query(port: int, timeout: float = 5.0) -> str:
    deadline = time.time() + timeout
    while True:
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=2)
            break
        except OSError:
            if time.time() > deadline:
                raise
            time.sleep(0.1)
    with sock:
        stream = sock.makefile("rwb")

        def read():
            while True:
                msg = json.loads(stream.readline())
                if "event" not in msg:
                    return msg

        read()  # greeting
        for cmd in ("qmp_capabilities", "query-status"):
            stream.write((json.dumps({"execute": cmd}) + "\n").encode())
            stream.flush()
            reply = read()
        return reply["return"]["status"]


def main() -> int:
    port = int(sys.argv[1])
    status = query(port)
    print(status)
    if len(sys.argv) > 2 and status != sys.argv[2]:
        print(f"expected {sys.argv[2]}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
