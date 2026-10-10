#!/bin/sh
# oxcom-pm gate (chunk 63): the compositor survives the power drill.
# The drill (OX_PM_SELFTEST=1 is powerd's default) suspends the machine
# at boot+6s and resumes via RTC (~8s). Chunk-62's boot deaths showed
# oxcom CAN die around graphics setup — this gate asserts the SERVICE
# bar after a real suspend/resume cycle:
#   1. the drill runs (pm-resumed journalled)
#   2. oxcom answers status afterwards
#   3. a post-resume screendump lands (screen.read granted)
#   4. deaths are counted from the run-file rc journal and REPORTED —
#      the assertion is service, not zero deaths.
# Boots WITHOUT ox.pm_drill=off deliberately.
# usage: oxcom-pm-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="${2:-/nix/store/qf3508h6zl2yq3vx6j236nq3r8dns4d9-linux-aarch64-unknown-linux-gnu-6.18.48/Image}"; TMO="${3:-1800}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$OXDIR/tools/gate-lib.sh"
OUT=/tmp/ox-opmgate
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-opm] %s\n' "$*"; }
fail() { printf '[ox-opm] FAIL: %s\n' "$*" >&2; exit 1; }

LOG="$OUT/serial-pm.log"
(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

wait_guest "name=pm-selftest-begin" 360000 1800 "power drill never began"
say "drill began (suspend at boot+30s — after the display claim)"
wait_guest "name=pm-resumed" 360000 1800 "the machine never resumed"
say "machine resumed"
wait_guest "name=oxcom-pm-resilient" 600000 1800 "oxcom did not prove post-resume service"
# the selftest journals exactly one outcome; resilient already matched —
# a failed journal would mean both, which is impossible, but check cheaply
grep -aq "name=pm-oxcom-failed" "$LOG" 2>/dev/null && fail "selftest journalled a failure"

DEATHS=$(grep -ac "oxcom: exited rc=" "$LOG" 2>/dev/null || true)
say "oxcom deaths this boot: ${DEATHS:-0} (rc classes: $(grep -a 'oxcom: exited rc=' "$LOG" 2>/dev/null | grep -o 'rc=[0-9]*' | tr '\n' ' '))"
say "ALL GREEN — the compositor serves through suspend/resume"
echo "OXCOM-PM GATE ALL GREEN"
