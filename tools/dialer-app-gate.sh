#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# Dialer-app gate (Phase 4): telephony end to end through the UI. The
# signed dialer.oxp installs at boot (dynamic tile, telephony.dial
# bound deny); the gate unlocks, taps the Dialer tile, enters a number
# on the pad, and requires the FULL honest lifecycle: dial REFUSED
# (bound deny) -> user grant flips -> dial goes to the RADIO (the AT
# emulator logs CALL-DIAL for the exact number) -> in-call -> End ->
# radio hangup (CALL-END) -> Close -> reap.
# usage: dialer-app-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-2400}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-dialgate
LOG="$OUT/serial-dialer.log"
EMU="$OUT/modem-emu.log"
EMUOUT="$OUT/modem-emu.stderr"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon /tmp/ox-modem-emu.sock

say() { printf '[ox-dial] %s\n' "$*"; }
fail() { printf '[ox-dial] FAIL: %s\n' "$*" >&2; exit 1; }

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

# tap + wait-for-milestone with retry rounds: a single tap is a
# single point of failure under variable guest timing
tap_retry() {
    _sx="$1"; _sy="$2"; _pat="$3"; _label="$4"
    r=0
    while [ $r -lt 5 ]; do
        qmp_tap "$_sx" "$_sy"
        k=0
        while [ $k -lt 60 ]; do
            grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
            sleep 2; k=$((k + 1))
        done
        r=$((r + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}
# tap a PAD/KEYBOARD key causally: tap until the app journals the
# keypress (name=<journal> c=<char> len=<len>) — single-shot key taps
# are dropped by input-queue lag under load, corrupting the composed
# number/text and making every later tap pointless
tap_key() {
    _kx="$1"; _ky="$2"; _jl="$3"; _kc="$4"; _kl="$5"; _label="$6"
    r=0
    while [ $r -lt 5 ]; do
        qmp_tap "$_kx" "$_ky"
        k=0
        while [ $k -lt 30 ]; do
            grep -aq "name=$_jl c=$_kc $_kl" "$LOG" 2>/dev/null && return 0
            sleep 2; k=$((k + 1))
        done
        r=$((r + 1))
    done
    fail "$_label (key journal not observed: $_jl c=$_kc $_kl)"
}



# the AT emulator up first (QEMU connects out to it, with reconnect)
python3 "$OXDIR/tools/modem-emu.py" --sock /tmp/ox-modem-emu.sock \
    --log "$EMU" > "$EMUOUT" 2>&1 &
EMU_PID=$!
sleep 1
kill -0 "$EMU_PID" 2>/dev/null || fail "modem emulator did not start"
trap 'kill "$EMU_PID" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true' EXIT

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 OX_VERBOSE=1 OX_QEMU_EXTRA="-chardev socket,id=oxmodem,path=/tmp/ox-modem-emu.sock,server=off,reconnect=3 \
    -device virtio-serial-pci,id=oxser \
    -device virtserialport,chardev=oxmodem,name=oxmodem.0" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
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
print("[ox-dial] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
        print("[ox-dial] unlock already observed - aborting remaining PIN taps")
        sys.exit(0)
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
if unlocked() > 0:
    print("[ox-dial] unlock already observed - skipping OK tap")
    sys.exit(0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-dial] PIN digits + OK injected")
PYEOF
}

wait_guest "name=pm-drill-skipped\|name=pm-resumed" 1800000 1800 "powerd PM selftest never resumed"
wait_guest "name=shell-locked" 900000 1800 "lock screen never rendered"

# keep the guest wakeable through idle suspends: a 15s system_wakeup
# is a no-op while awake and plays the power button while suspended
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
say "powerd PM selftest resumed"
# NO keep-awake tap loop here: the lock screen and every foreground app
# hold wake locks, and the loop's (4,4) taps hit the shell's top-left
# switcher zone — raising the shell ABOVE the app window so pad clicks
# leak to the shell mid-flow.

i=0
while [ ! -S /tmp/ox-qmp ] && [ $i -lt 120 ]; do
    sleep 1; i=$((i + 1))
done
sleep 30
attempt=0
UNLOCKED=no
while [ $attempt -lt 6 ]; do
    qmp_pin 1234 "$LOG" || true
    k=0
    while [ $k -lt 300 ]; do
        grep -aq "name=shell-unlocked" "$LOG" 2>/dev/null && break
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


# post-unlock hygiene (see tiles-gate): a lagging PIN-pad click can
# deliver onto the unlocked grid or into a freshly opened app's pad,
# corrupting state (a stray digit makes the '+' key inert). Wait out
# the delivery lag, then tap the app Close button twice - inert on the
# bare home screen, closes any stray app window.
# 120s: the PIN queue (13 clicks) can take ~100s to fully deliver
sleep 120
qmp_tap 877 662
sleep 6
qmp_tap 877 662
sleep 3

# 1. signed package installed -> Dialer dynamic tile (slot 1: Camera
#    sorts first) -> tap it
wait_guest "name=dialer-app-installed" 2700000 1800 "dialer.oxp never installed"
say "dialer.oxp installed, telephony.dial bound deny"
# tap_retry: the home grid self-heals within ~5s of the install; a
# single early tap lands on a slot the shell has not drawn yet
tap_retry 402 467 "name=dialer-ready" "Dialer app never drew (tile tap)"

say "Dialer app launched"

# 2. enter +15550001 on the pad (the + key FIRST — numbers are E.164);
#    the bound deny refuses the dial
#    (window 60,90; pad keys 1/5/0/+ at window (80,200)+(col,row)*102x68)
# NUMBER ENTRY, stray-proof: each tap is verified only by "a new key
# journal appeared" (lag can duplicate/delay deliveries); the FINAL
# number journal decides correctness — on mismatch the entry restarts
# from C (3 rounds). The radio leg asserts the exact number anyway.
DIALKEYS='+ 389 522
1 185 318
5 287 386
5 287 386
5 287 386
0 287 522
0 287 522
0 287 522
1 185 318'
NBASE=$(grep -ac "name=dialer-key" "$LOG" 2>/dev/null || true)
enter_number() {
    r=0
    while [ $r -lt 3 ]; do
        qmp_tap 185 522   # C: reset
        k=0
        while [ $k -lt 20 ]; do
            N1=$(grep -ac "name=dialer-key" "$LOG" 2>/dev/null || true)
            [ $((N1 - NBASE)) -ge 1 ] 2>/dev/null && break
            sleep 2; k=$((k + 1))
        done
        NBASE=$(grep -ac "name=dialer-key" "$LOG" 2>/dev/null || true)
        OK=all
        for key in $DIALKEYS; do :; done
        for key in "$DIALKEYS"; do :; done
        printf '%s
' "$DIALKEYS" | while read -r c kx ky; do
            [ -n "$c" ] || continue
            qmp_tap "$kx" "$ky"   # $c
            k=0
            while :; do
                N1=$(grep -ac "name=dialer-key" "$LOG" 2>/dev/null || true)
                [ "${N1:-0}" -gt "${NBASE:-0}" ] 2>/dev/null && break
                sleep 2; k=$((k + 1))
                [ $k -gt 45 ] && break
            done
            NBASE=$N1
        done
        # the LAST key of the sequence waits for its OWN full-state
        # journal: a line-count check races the file flush and can read
        # stale state (complete entries were "restarted" against their
        # own success in one run)
        k=0
        while :; do
            grep -aq "name=dialer-key c=1 num=+15550001" "$LOG" 2>/dev/null && return 0
            sleep 2; k=$((k + 1))
            [ $k -gt 45 ] && break
        done
        LAST=$(grep -a "name=dialer-key c=" "$LOG" 2>/dev/null | tail -1)
        say "number entry produced: $(printf '%s' "$LAST" | grep -o 'num=[+0-9]*') — restarting"
        r=$((r + 1))
    done
    return 1
}
enter_number || fail "number entry never produced +15550001"
tap_retry 570 328 "name=dialer-call-denied" "dial was not refused by the bound deny (permission leak?)"
say "dial refused by the bound telephony.dial deny"

# 3. the user grant flips -> the same dial goes to the RADIO
wait_guest "name=dialer-app-granted" 2700000 1800 "selftest never flipped the user grant"
tap_retry 570 328 "name=dialer-call-active" "call never went active after the grant"
grep -aq "CALL-DIAL to +15550001" "$EMU" || fail "radio never saw ATD+15550001 (egress broken)"
say "call active: radio dialed +15550001 (emulator logged CALL-DIAL)"

# 4. End -> radio hangup
qmp_tap 570 408   # End
wait_guest "name=dialer-call-ended" 1080000 1800 "call never ended"
grep -aq "CALL-END" "$EMU" || fail "radio never saw the hangup (ATH)"
say "call ended: radio logged CALL-END"

# 5. close + reap
qmp_tap 877 662   # Close
wait_guest "name=dialer-exit" 1080000 1800 "Dialer app never exited"
wait_guest "intent-exit app=Dialer" 1080000 1800 "intentd never reaped the Dialer app"
say "closed and reaped"

kill "$EMU_PID" 2>/dev/null || true
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — Dialer: signed package, bound-deny refusal, user grant, REAL radio dial + hangup (emulator-confirmed), clean reap"
echo "DIALER APP GATE ALL GREEN"
