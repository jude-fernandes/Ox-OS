#!/bin/sh
# Kill any lingering QEMU instances holding payload image locks.
pkill -f qemu-system-aarch64 2>/dev/null
sleep 1
pgrep -f qemu-system-aarch64 >/dev/null && { sleep 3; pkill -9 -f qemu-system-aarch64 2>/dev/null; }
sleep 1
pgrep -f qemu-system-aarch64 >/dev/null && echo "STILL RUNNING" || echo "qemu clean"
