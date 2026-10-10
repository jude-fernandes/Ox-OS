#!/bin/sh
# Lock-shield gate (chunk 59, guest-time waits per chunk-54 discipline):
# while the device is LOCKED, an app window must not cover the PIN pad
# or take its taps. The chunk-58 rollout caught exactly that (a Hello
# window above the lock pad ate entries). Fix under test: the secure
# tier in oxcom —
#   locked:   the shell window is SECURE: it composites and takes clicks
#             above every normal window, whatever raises/launches land
#   unlocked: the shield releases; normal z-order competition returns
# Legs:
#   1. boot -> shell-locked + lock-shield on=true
#   2. shield-selftest starts Hello while locked -> its window lands
#      below the shield (tier, not timing)
#   3. tap a pad digit -> oxcom journals lock-shield-kept (the tap WOULD
#      have hit Hello) AND the shell's pad receives the digit
#   4. unlock 1234 -> shell-unlocked + lock-shield on=false
#   5. relock via the footer button -> shell-relocked + shield on=true
# All waits are GUEST-clock budgets (wait_guest) — host-speed-independent
# (the 2026-09-27 sweep caught the host-clock version expiring early).
# usage: lock-shield-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="${2:-/nix/store/qf3508h6zl2yq3vx6j236nq3r8dns4d9-linux-aarch64-unknown-linux-gnu-6.18.48/Image}"; TMO="${3:-2400}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$OXDIR/tools/gate-lib.sh"   # chunk-54 guest-time waits
OUT=/tmp/ox-lsgate
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-ls] %s\n' "$*"; }
fail() { printf '[ox-ls] FAIL: %s\n' "$*" >&2; exit 1; }

qmp_tap_key() {
    python3 - "$1" <<'PYEOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmp")
f = s.makefile("rw")
f.readline()
def send(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    return json.loads(f.readline())
send({"execute": "qmp_capabilities"})
send({"execute": "system_wakeup"})
time.sleep(2.0)
def ev(events):
    r = send({"execute": "input-send-event", "arguments": {"events": events}})
    assert "error" not in r, r
    time.sleep(0.15)
def tap(sx, sy):
    move1 = [{"type": "abs", "data": {"axis": "x", "value": int(sx * 32767 / 1280)}},
             {"type": "abs", "data": {"axis": "y", "value": int(sy * 32767 / 800)}}]
    ev(move1)
    time.sleep(0.4)
    ev(move1)
    ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
    ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "OK"]
rects = [(353 + (i % 3) * 102, 420 + (i // 3) * 68, 90, 56) for i in range(12)]
for ch in sys.argv[1]:
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-ls] pad keys + OK injected")
PYEOF
}

qmp_tap_xy() {
    python3 - "$1" "$2" <<'PYEOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmp")
f = s.makefile("rw")
f.readline()
def send(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    return json.loads(f.readline())
send({"execute": "qmp_capabilities"})
send({"execute": "system_wakeup"})
time.sleep(2.0)
def ev(events):
    r = send({"execute": "input-send-event", "arguments": {"events": events}})
    assert "error" not in r, r
    time.sleep(0.15)
sx, sy = float(sys.argv[1]), float(sys.argv[2])
move1 = [{"type": "abs", "data": {"axis": "x", "value": int(sx * 32767 / 1280)}},
         {"type": "abs", "data": {"axis": "y", "value": int(sy * 32767 / 800)}}]
ev(move1)
time.sleep(0.4)
ev(move1)
ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
print("[ox-ls] tap injected")
PYEOF
}

LOG="$OUT/serial-ls.log"
(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-locked" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=lockd-ready" "$LOG" || fail "no lockd-ready milestone"

# 1. the shell engaged the shield at boot (guest-time budget)
wait_guest "name=lock-shield id=[0-9]* on=true" 360000 1800 "shield never engaged at boot"
say "shield engaged at boot (secure tier on the lock pad)"
# baseline BEFORE the selftest launches anything: after this point the
# only window that can appear is the probe app's
WN_BEFORE=$(grep -ac "name=window-new" "$LOG" 2>/dev/null || true)

# 2. an app starts while locked (the chunk-58 tapjacking condition).
# The selftest retries until pkg-selftest has packaged Hello (up to
# ~450 guest-s), so the budget must cover its full patience.
wait_guest "name=shield-probe-launched" 600000 1800 "shield selftest never launched Hello"
wait_guest "name=intent-start app=Hello" 600000 1800 "Hello never intent-started"
# Hello's window has a UNIQUE shape — no other client draws 900x680 at
# (190,80); waiting on the shape beats count races entirely
wait_guest "name=window-new id=[0-9]* x=190 y=80 w=900 h=680" 600000 1800 "Hello's window never appeared"
WIN=$(grep -a "name=window-new id=[0-9]* x=190 y=80 w=900 h=680" "$LOG" | tail -1 | sed "s/.*id=\([0-9]*\).*/\1/")
[ -n "$WIN" ] || fail "could not read Hello's window id"
say "Hello window id=$WIN created while locked (must be below the shield)"

# 3. a pad tap must reach the pad, not the app covering it
qmp_tap_key 5
wait_guest "name=lock-shield-kept win=[0-9]* shadowed=$WIN" 240000 1800 "shield did not journal the redirected tap"
# the shell journals the pointer position it received — QMP round-trip
# rounding lands it a pixel off the computed key center (observed
# x=499 y=515 for the computed (500,516)), so match a 10px band
wait_guest "ox-shell: click x=49[0-9] y=51[0-9] locked=true" 240000 1800 "the pad never received the tap"
say "PAD KEPT THE TAP: shield journal + pad digit both advanced (app window is below)"

# 4. unlock: the shield must release so the grid competes normally
qmp_tap_key 1234
wait_guest "name=shell-unlocked" 360000 1800 "owner unlock timed out"
wait_guest "name=lock-shield id=[0-9]* on=false" 240000 1800 "shield never released on unlock"
say "unlocked: shield released (lock-shield on=false)"

# 5. relock from the footer: the shield must re-engage (count-verified)
BEFORE_ON=$(grep -ac "name=lock-shield id=[0-9]* on=true" "$LOG" 2>/dev/null || true)
qmp_tap_xy 123 652
wait_guest "name=shell-relocked" 360000 1800 "footer relock never fired"
k=0
ADV=no
while [ $k -lt 300 ]; do
    A=$(grep -ac "name=lock-shield id=[0-9]* on=true" "$LOG" 2>/dev/null || true)
    if [ "${A:-0}" -gt "${BEFORE_ON:-0}" ]; then ADV=yes; break; fi
    sleep 2; k=$((k + 1))
done
[ "$ADV" = yes ] || fail "shield did not re-engage on relock"
say "relocked: shield re-engaged"

say "ALL GREEN — the lock pad cannot be covered or tapjacked; unlock and relock cycle the shield"
echo "LOCK-SHIELD GATE ALL GREEN"
