#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# Uninstall gate: closing the package lifecycle through the UI. At boot
# the selftest installs hello.oxp (bound deny). The gate PIN-unlocks ->
# Settings -> Apps -> taps the Hello entry -> app-removed (grants die
# with it: perm-unbound) -> Back -> Close -> taps Hello's (now stale)
# dynamic tile: the shell still launches it, but intentd refuses —
# the app set has shrunk. Screendump of the Apps panel.
# usage: uninstall-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-3600}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-uninstgate
LOG="$OUT/serial-uninst.log"
PPM="$OUT/uninst-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-uninst] %s\n' "$*"; }
fail() { printf '[ox-uninst] FAIL: %s\n' "$*" >&2; exit 1; }

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

# early wake loop: the boot PM drill can suspend before the first
# milestone — nudge every 15s (no-op while awake)
(while :; do
    python3 - <<'PYW' 2>/dev/null || true
import socket
try:
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmon")
    s.settimeout(2)
    s.recv(4096)
    s.sendall(b"system_wakeup" + chr(10).encode())
except Exception:
    pass
PYW
    sleep 15
done) 2>/dev/null &

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

qmp_tap() {
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
print("[ox-uninst] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
PYEOF
}

qmp_pin() {
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
def unlocked():
    # raw BYTES read: the serial log carries ANSI escapes and torn
    # lines — a text-mode grep here used to throw on decode and
    # silently report zero forever
    try:
        with open(sys.argv[2], "rb") as f:
            return f.read().count(b"name=shell-unlocked")
    except Exception:
        return 0
# ABSOLUTE, checked BEFORE each tap: the gates unlock exactly once,
# so any unlock observation means the device is already open and the
# remaining pad taps would land on the home GRID (a stray launch whose
# window then eats every later tap). A per-attempt delta was blind:
# the unlock milestone lands between attempts and the base swallowed it.
for ch in sys.argv[1]:
    if unlocked() > 0:
        print("[ox-uninst] unlock already observed - aborting remaining PIN taps")
        sys.exit(0)
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
if unlocked() > 0:
    print("[ox-uninst] unlock already observed - skipping OK tap")
    sys.exit(0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-uninst] PIN digits + OK injected")
PYEOF
}

wait_ms() {
    _pat="$1"; _max="$2"; _label="$3"
    k=0
    while [ $k -lt "$_max" ]; do
        grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
        if [ $((k % 10)) -eq 5 ]; then
            # PM wake assist: nudge the machine like a power button —
            # the RTC alarm can miss under host load (guest clock lag
            # arms the wakealarm in the past); no-op while awake.
            python3 - <<'PYW' 2>/dev/null || true
import socket
try:
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmon")
    s.settimeout(2)
    s.recv(4096)
    s.sendall(b"system_wakeup\n")
except Exception:
    pass
PYW
        fi
        sleep 2; k=$((k + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}

tap_until() {
    _sx="$1"; _sy="$2"; _pat="$3"; _rounds="$4"; _label="$5"
    attempt=0
    while [ $attempt -lt "$_rounds" ]; do
        qmp_tap "$_sx" "$_sy"
        k=0
        while [ $k -lt 60 ]; do
            grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
            if [ $((k % 10)) -eq 5 ]; then
                python3 - <<'PYW' 2>/dev/null || true
import socket
try:
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmon")
    s.settimeout(2)
    s.recv(4096)
    s.sendall(b"system_wakeup" + chr(10).encode())
except Exception:
    pass
PYW
            fi
            sleep 2; k=$((k + 1))
        done
        attempt=$((attempt + 1))
        say "$_label not observed (retry $((attempt + 1)))"
    done
    fail "$_label"
}

# 1. boot basics
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone"
grep -aq "name=intentd-ready" "$LOG" || fail "no intentd-ready milestone"
wait_guest "name=intent-install app=Hello" 1080000 1800 "hello.oxp not installed at boot"
say "locked shell up, hello.oxp installed"
# bounded + non-decisive: the drill is resourced-gate's assertion; its
# tmpfs fill can crawl for many minutes under TCG and must not eat the
# gate's timeout (a previous round burned 600s here, then QEMU's
# timeout killed the machine mid-gate)
k=0
while [ $k -lt 150 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && say "resourced drill settled after $((k * 2))s" || say "resourced drill still running after $((k * 2))s — proceeding (not this gate's assertion)"
sleep 3

# 2. PIN unlock — chunk 64: event-relative 600s windows (a pad click
# can take ~20 guest-s to land under load), so one queued PIN drains
# fully before any re-inject can poison the digit buffer.
attempt=0
UNLOCKED=no
while [ $attempt -lt 3 ]; do
    N0=$(grep -ac "name=shell-unlocked" "$LOG" || true)
    qmp_pin 1234 "$LOG"
    k=0
    while [ $k -lt 300 ]; do
        N1=$(grep -ac "name=shell-unlocked" "$LOG" || true)
        [ "$N1" -gt "$N0" ] && break
        sleep 2; k=$((k + 1))
    done
    grep -aq "name=shell-unlocked" "$LOG" 2>/dev/null && { UNLOCKED=yes; break; }
    attempt=$((attempt + 1))
    say "unlock not observed yet (retry $((attempt + 1)))"
    # drain: let queued pad clicks DELIVER before re-injecting —
    # a lagging click lands on the (now unlocked) home grid and
    # opens a full-screen app window that eats every later tap
    sleep 30
done
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone"
say "unlocked"
# post-unlock hygiene: PIN-pad clicks injected while locked can sit in
# the input queue and DELIVER up to ~2 minutes later, after the unlock —
# landing on a dynamic tile and opening a full-screen app window that
# eats every later tile tap. A fixed drain loses that race by
# construction; instead watch the launch stream: once no NEW app launch
# has appeared for 36s the queue is drained, then tap the app Close
# button twice (inert on the bare home screen) to remove any strays.
sleep 60
prev=$(grep -ac "name=shell-launch app=" "$LOG" 2>/dev/null || true)
stable=0
while [ $stable -lt 3 ]; do
    sleep 12
    cur=$(grep -ac "name=shell-launch app=" "$LOG" 2>/dev/null || true)
    if [ "$cur" = "$prev" ]; then
        stable=$((stable + 1))
    else
        stable=0
        prev=$cur
    fi
done
qmp_tap 877 662
sleep 8
qmp_tap 877 662
sleep 5

# 3. Settings -> Apps panel (Apps button center: window (471,562) ->
#    screen (661,642); chunk 66: aim 16px HIGHER — y=642 delivered as
#    641-642 after QMP rounding, i.e. inside the footer's y=640 edge
#    strip (Settings ignores clicks there; solo runs' rounding landed
#    1-2px higher and won the boundary lottery). The row center has
#    margin on both sides.
tap_until_guest 158 195 "name=settings-ready" 540000 1800 "Settings did not launch"
say "Settings open"
tap_until_guest 661 626 "name=apps-open" 540000 1800 "Apps panel did not open"
say "Apps panel open"

# 4. tap the Hello entry (row 2 — Camera and Dialer sort ahead of it;
#    row centers 84px apart from screen y=236 — center 640,404) -> removed + unbound
tap_until 640 404 "name=app-removed app=Hello" 3 "Hello was not removed"
wait_guest "name=perm-unbound app=Hello" 180000 1800 "grants did not die with the app"
say "Hello uninstalled; its grants died with it"

# 5. artifact: screendump of the Apps panel
sleep 2
python3 - "$PPM" <<'PYEOF'
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
r = send({"execute": "screendump", "arguments": {"filename": sys.argv[1]}})
assert "error" not in r, r
print("[ox-uninst] screendump ok")
PYEOF

# 6. back, close: the shell refreshes its grid from intentd's
#    pkgs-changed event (~instant); tapping the old spot is INERT —
#    no launch, no intent, nothing.
tap_until_guest 313 712 "name=apps-back" 540000 1800 "Back did not return to Settings"
tap_until_guest 967 712 "name=settings-close" 540000 1800 "Settings did not close"
say "waiting for the shell grid to refresh"
sleep 7
N0=$(grep -ac "name=shell-launch app=Hello" "$LOG" 2>/dev/null || true)
qmp_tap 158 579
sleep 15
N1=$(grep -ac "name=shell-launch app=Hello" "$LOG" 2>/dev/null || true)
[ "$N1" = "$N0" ] || fail "the uninstalled app's tile still launched (grid did not refresh)"
grep -aq "grid-event-refresh\|package set changed" "$LOG" || fail "shell grid did not self-refresh after uninstall"
say "removed app's tile is gone and inert: tap after uninstall launches nothing"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — uninstall through the UI: package removed, grants die, stale tile refused"
echo "UNINSTALL GATE ALL GREEN"
