#!/bin/sh
# Boot-health gate (chunk 67): boots the payload and asserts EVERY core
# daemon is serving, BY NAME. Closes the "missing daemon" flake class —
# a boot that loses powerd (run-4b camera-app) or dies pre-journal
# (run-5 bt fragment) now produces a named boot-daemon-down journal
# instead of a mysteriously absent pattern.
#   1. every daemon in the boot-health manifest journals a socket, or
#      the selftest names the missing ones (gate refuses)
#   2. any daemon that DIED self-reports via the fleet-wide exit-code
#      journal (chunk 67) — deaths are counted and reported
# Boots WITH ox.pm_drill=off (deterministic boot; the PM drill has its
# own dedicated gate).
# usage: boot-health-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="${2:-/nix/store/qf3508h6zl2yq3vx6j236nq3r8dns4d9-linux-aarch64-unknown-linux-gnu-6.18.48/Image}"; TMO="${3:-1800}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$OXDIR/tools/gate-lib.sh"
OUT=/tmp/ox-bhgate
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-bh] %s\n' "$*"; }
fail() { printf '[ox-bh] FAIL: %s\n' "$*" >&2; exit 1; }

LOG="$OUT/serial-bh.log"
(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. the selftest settled and journalled the manifest walk
wait_guest "name=boot-health missing=" 900000 1800 "boot-health selftest never settled"
say "boot-health selftest settled"

# 2. refuse ANY missing daemon (named — never a mystery again)
if grep -aq "name=boot-daemon-down daemon=" "$LOG" 2>/dev/null; then
    grep -ao "name=boot-daemon-down daemon=[a-z-]*" "$LOG" | sort -u | sed 's/^/[ox-bh]   DOWN: /' >&2
    fail "boot is INCOMPLETE — missing daemons named above"
fi
grep -aq "name=boot-health missing=none" "$LOG" 2>/dev/null \
    || fail "boot-health journalled an unexpected missing list"
say "manifest complete: all 19 core daemons serving"

# 3. deaths: the fleet-wide exit journal reports any daemon that died
#    and (s6) restarted — reported honestly, refusals only if a death
#    left the daemon down (already caught by the manifest check above)
DEATHS=$(grep -ac ": exited rc=" "$LOG" || true)
say "daemon deaths this boot: ${DEATHS:-0} ($(grep -a ': exited rc=' "$LOG" 2>/dev/null | grep -o '^[a-z-]*: exited rc=[0-9]*' | sort -u | tr '\n' ' '))"

# 4. the shell is up and the compositor serves (client-layer sanity)
wait_guest "name=shell-locked" 600000 1800 "shell never locked"
grep -aq "stage serving" "$LOG" 2>/dev/null || fail "compositor never reached stage serving"
say "shell locked, compositor serving"

say "ALL GREEN — boot completeness: every core daemon serves, deaths self-report"
echo "BOOT-HEALTH GATE ALL GREEN"
