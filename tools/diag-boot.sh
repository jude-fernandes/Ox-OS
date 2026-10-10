#!/bin/sh
# Minimal diagnostic boot: kernel only, verbose console, no root mount.
# usage: diag-boot.sh KERNEL_IMAGE [EXTRA_CMDLINE]
set -u
KERNEL="$1"; EXTRA="${2:-}"
command -v timeout >/dev/null || { echo "need coreutils timeout" >&2; exit 2; }
timeout 90 qemu-system-aarch64 \
    -machine virt -cpu cortex-a76 -smp 4 -m 2048 \
    -nographic -monitor none \
    -kernel "$KERNEL" \
    -append "console=ttyAMA0 earlycon keep_bootcon ignore_loglevel $EXTRA" 2>&1 | tail -40
