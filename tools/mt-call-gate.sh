#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# MT-call gate (Phase 4): mobile-terminated voice calls end to end.
# The signed dialer.oxp installs at boot (telephony.dial bound deny);
# the gate first proves the MO leg is honest (dial refused -> user
# grant), then INJECTS an inbound call through the emulator's control
# socket and requires the full MT chain: RING from the radio ->
# daemon asks CLCC for the caller and journals modem-ring -> the app
# raises the INCOMING banner (dialer-incoming) -> Answer goes to the
# RADIO (emulator logs CALL-ANSWER; call active incoming=true) ->
# End -> radio CALL-END -> Close -> reap.
# usage: mt-call-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-1500}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-mtgate
LOG="$OUT/serial-mt.log"
EMU="$OUT/modem-emu.log"
EMUOUT="$OUT/modem-emu.stderr"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon /tmp/ox-modem-emu.sock /tmp/ox-modem-emu-ctl

say() { printf '[ox-mt] %s\n' "$*"; }
fail() { printf '[ox-mt] FAIL: %s\n' "$*" >&2; exit 1; }

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



# same loop against the EMULATOR log (radio-side evidence)
wait_emu() {
    _pat="$1"; _max="$2"; _label="$3"
    k=0
    while [ $k -lt "$_max" ]; do
        grep -aq "$_pat" "$EMU" 2>/dev/null && return 0
        sleep 2; k=$((k + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}

# the AT emulator up first (control socket included: MT injection)
python3 "$OXDIR/tools/modem-emu.py" --sock /tmp/ox-modem-emu.sock \
    --ctl /tmp/ox-modem-emu-ctl \
    --log "$EMU" > "$EMUOUT" 2>&1 &
EMU_PID=$!
sleep 1
kill -0 "$EMU_PID" 2>/dev/null || fail "modem emulator did not start"
[ -S /tmp/ox-modem-emu-ctl ] || fail "control socket missing"
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
print("[ox-mt] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
        print("[ox-mt] unlock already observed - aborting remaining PIN taps")
        sys.exit(0)
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
if unlocked() > 0:
    print("[ox-mt] unlock already observed - skipping OK tap")
    sys.exit(0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-mt] PIN digits + OK injected")
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
# NO keep-awake tap loop: lock screen + foreground apps hold wake locks.

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
# watch the launch stream: once no NEW app launch has appeared for
# 36s the lagging-click queue is drained, then close any stray app
# window (a lagging click can launch one that eats every later tap)
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

# 1. Dialer tile (sorted dynamic slot 1) -> app up
wait_guest "name=dialer-app-installed" 2700000 1800 "dialer.oxp never installed"
tap_retry 402 467 "name=dialer-ready" "Dialer app never drew"
say "Dialer app launched"

# 2. the MO leg is still honest: +15550001 dial REFUSED by the bound
#    deny, then the selftest flips the grant
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
qmp_tap 570 328   # Call
wait_guest "name=dialer-call-denied" 1080000 1800 "dial was not refused by the bound deny (permission leak?)"
say "dial refused by the bound telephony.dial deny"
wait_guest "name=dialer-app-granted" 2700000 1800 "selftest never flipped the user grant"
say "user grant flipped"

# 3. the MT leg: the network calls +15550003; RING repeats from the
#    radio, the daemon asks CLCC (caller identity) and journals, the
#    app raises the INCOMING banner
python3 "$OXDIR/tools/modem-inject.py" /tmp/ox-modem-emu-ctl \
    '{"inject_call":{"from":"+15550003"}}' > /dev/null
say "inbound call injected (+15550003)"
grep -aq "CALL-INCOMING from=+15550003" "$EMU" || fail "emulator never started the MT call"
# the ring loop ticks every 2s — WAIT for the first RING (emulator
# log) before requiring anything from the guest
wait_emu ">> RING" 60 "emulator never rang (ring loop broken)"
wait_guest "name=modem-ring from=+15550003" 1080000 1800 "daemon never recorded the ring (RING URC path broken?)"
grep -aq "AT+CLCC" "$EMU" || fail "daemon never asked the radio who is calling (CLCC)"
wait_guest "name=dialer-incoming from=+15550003" 1080000 1800 "app never showed the INCOMING banner (callstatus poll broken?)"
say "ring recorded by daemon and surfaced by the app"

# 4. Answer -> the RADIO answers (ATA), call active incoming=true
tap_retry 570 488 "name=dialer-call-active number=+15550003 synthetic=false incoming=true" "call never went active after Answer"
grep -aq "CALL-ANSWER (was +15550003)" "$EMU" || fail "radio never saw ATA (answer egress broken)"
grep -aq "name=modem-answer number=+15550003 synthetic=false" "$LOG" || fail "daemon never journaled the radio answer"
say "answered: radio logged CALL-ANSWER for +15550003"

# 5. End -> the radio hangs up
qmp_tap 570 408   # End
wait_guest "name=dialer-call-ended" 1080000 1800 "call never ended"
wait_emu "CALL-END (was +15550003)" 60 "radio never saw the hangup (ATH)"
say "ended: radio logged CALL-END"

# 6. close + reap
qmp_tap 877 662   # Close
wait_guest "name=dialer-exit" 1080000 1800 "Dialer app never exited"
wait_guest "intent-exit app=Dialer" 1080000 1800 "intentd never reaped the Dialer app"
say "closed and reaped"

kill "$EMU_PID" 2>/dev/null || true
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — MT calls: RING -> CLCC caller lookup -> INCOMING UI -> RADIO answer (ATA) + hangup (ATH), with the MO leg still honest (bound-deny refusal -> grant)"
echo "MT CALL GATE ALL GREEN"
