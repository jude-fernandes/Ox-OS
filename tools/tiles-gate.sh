#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# Tiles gate: dynamic shell grid. The pkg-selftest installs hello.oxp
# at boot; after PIN unlock the shell's home grid must contain a tile
# for the installed app (drawn from intentd's package list), and
# tapping it must run the full launch chain: shell-launch app=Hello ->
# shell-intent -> intent-start -> hello-ready. Screendump as artifact.
# usage: tiles-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-1800}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-tilesgate
LOG="$OUT/serial-tiles.log"
PPM="$OUT/tiles-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-tiles] %s\n' "$*"; }
fail() { printf '[ox-tiles] FAIL: %s\n' "$*" >&2; exit 1; }

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
print("[ox-tiles] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
        print("[ox-tiles] unlock already observed - aborting remaining PIN taps")
        sys.exit(0)
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
if unlocked() > 0:
    print("[ox-tiles] unlock already observed - skipping OK tap")
    sys.exit(0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-tiles] PIN digits + OK injected")
PYEOF
}

# 1. boot basics + the package must be installed before unlock.
#    900s budget: with the full Phase-4 selftest set booting under TCG,
#    the pkg install lands around guest t≈450s (was ~120s on the
#    lighter Phase-3 payload — fixed 240s budgets started missing it).
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-home" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=shell-locked" "$LOG" || fail "no shell-locked milestone"
grep -aq "name=intentd-ready" "$LOG" || fail "no intentd-ready milestone"
say "locked shell up, intentd supervised"
k=0
while [ $k -lt 450 ]; do
    grep -aq "name=intent-install app=Hello" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "name=intent-install app=Hello" "$LOG" 2>/dev/null || fail "hello.oxp not installed (dynamic tile would not exist)"
say "hello.oxp installed before unlock"
sleep 3

# 2. let the resourced memory drill settle — bounded and NON-decisive:
#    it is resourced-gate's assertion, not this gate's; the tmpfs fill
#    can crawl for many minutes under TCG and must not eat the budget
#    (a previous round burned 600s here, then QEMU's timeout killed it)
k=0
while [ $k -lt 150 ]; do
    grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && break
    grep -aq "name=resourced-tier-failed" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "name=resourced-tier-ok" "$LOG" 2>/dev/null && say "resourced drill settled after $((k * 2))s" || say "resourced drill still running after $((k * 2))s — proceeding (not this gate's assertion)"

# 3. PIN unlock
attempt=0
UNLOCKED=no
while [ $attempt -lt 6 ]; do
    N0=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
    qmp_pin 1234 "$LOG"
    k=0
    while [ $k -lt 300 ]; do
        N1=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
        [ "$N1" -gt "$N0" ] 2>/dev/null && break
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
say "unlocked with PIN"
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

# 4. tap the DYNAMIC Hello tile (third dyn slot: window 48,535 220x88
#    -> center screen 158,579) -> full launch chain. The launch
#    assertion is CAUSAL: a count increment of shell-launch app=Hello,
#    which only a real tap can produce — hello-ready alone is NOT
#    proof, the boot pkg selftest spawns Hello too (a previous round's
#    loop matched that stale milestone and passed without a tap).
attempt=0
READY=no
N0=$(grep -ac "name=shell-launch app=Hello" "$LOG" 2>/dev/null || true)
while [ $attempt -lt 4 ]; do
    qmp_tap 158 579
    k=0
    while [ $k -lt 30 ]; do
        N1=$(grep -ac "name=shell-launch app=Hello" "$LOG" 2>/dev/null || true)
        [ $((k % 10)) -eq 0 ] && say "DBG-N0=$N0 N1=[$N1] k=$k"
        [ "$N1" -gt "$N0" ] 2>/dev/null && { READY=yes; break; }
        sleep 2; k=$((k + 1))
    done
    [ "$READY" = yes ] && break
    attempt=$((attempt + 1))
    say "shell did not register the Hello tile tap (retry $((attempt + 1)))"
done
# final flush re-check: QEMU buffers serial output — the milestone can
# land in the FILE well after it happened in the guest; a loop that
# polls the file can exhaust its rounds against a stale buffer. Give
# the buffer one last bounded chance before declaring failure.
if [ "$READY" != yes ]; then
    sleep 20
    N1=$(grep -ac "name=shell-launch app=Hello" "$LOG" 2>/dev/null || true)
    [ "$N1" -gt "$N0" ] 2>/dev/null && { READY=yes; say "Hello tap registered after the serial flush"; }
fi
[ "$READY" = yes ] || fail "tapping the dynamic Hello tile did not launch the app"
k=0
while [ $k -lt 30 ]; do
    grep -aq "name=intent-start app=Hello" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
say "dynamic tile tap -> full launch chain:"
grep -a -e "name=shell-launch app=Hello" -e "name=shell-intent app=Hello" -e "name=intent-start app=Hello" -e "name=hello-ready" "$LOG" | tail -4 | sed 's/^/[ox-tiles]   /'
grep -aq "name=shell-launch app=Hello" "$LOG" || fail "shell did not register the Hello tile tap"
grep -aq "name=intent-start app=Hello" "$LOG" || fail "intentd did not spawn Hello from the tile tap"

# 5. artifact: screendump of the launched state
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
print("[ox-tiles] screendump ok")
PYEOF

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — dynamic grid: installed package appears and launches from the home screen"
echo "TILES GATE ALL GREEN"
