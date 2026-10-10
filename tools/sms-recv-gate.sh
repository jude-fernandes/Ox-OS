#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# SMS receive gate (Phase 4): inbound SMS end to end. The signed
# sms.oxp installs at boot; the gate unlocks, taps Messaging, proves
# the SEND leg is still honest (compose -> bound-deny refusal ->
# grant -> radio), then INJECTS an inbound SMS through the emulator's
# control socket and requires the full receive chain: +CMTI raised to
# the guest -> daemon reads it (AT+CMGR), journals
# modem-sms-received, deletes it (AT+CMGD) -> the app's
# permission-checked sms-list poll picks it up and journals
# sms-received (displayed). Close -> reap.
# usage: sms-recv-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-2400}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-recvgate
LOG="$OUT/serial-smsrecv.log"
EMU="$OUT/modem-emu.log"
EMUOUT="$OUT/modem-emu.stderr"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon /tmp/ox-modem-emu.sock /tmp/ox-modem-emu-ctl

say() { printf '[ox-recv] %s\n' "$*"; }
fail() { printf '[ox-recv] FAIL: %s\n' "$*" >&2; exit 1; }

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



# the AT emulator up first (QEMU connects out to it, with reconnect);
# --ctl opens the injection socket
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
print("[ox-recv] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
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
        print("[ox-recv] unlock already observed - aborting remaining PIN taps")
        sys.exit(0)
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
if unlocked() > 0:
    print("[ox-recv] unlock already observed - skipping OK tap")
    sys.exit(0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-recv] PIN digits + OK injected")
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
# 120s: the PIN queue (13 clicks) can take ~100s to fully deliver
sleep 120
qmp_tap 877 662
sleep 6
qmp_tap 877 662
sleep 3

# 1. signed package installed -> Messaging tile (sorted slot 3)
wait_guest "name=sms-app-installed" 2700000 1800 "sms.oxp never installed"
tap_retry 402 579 "name=sms-ready" "Messaging app never drew"
say "Messaging app launched"

# 2. the SEND leg is still honest: compose +15550001 "hi", the bound
#    deny refuses, the selftest grant flips
# RECIPIENT ENTRY, stray-proof: each tap is verified only by "a new
# key journal appeared" (lag can duplicate/delay deliveries); the FINAL
# to= journal decides correctness — on mismatch the entry restarts from
# C (3 rounds). The radio leg asserts the exact recipient anyway.
SMSKEYS='+ 336 462
1 176 294
5 256 350
5 256 350
5 256 350
0 256 462
0 256 462
0 256 462
1 176 294'
NBASE=$(grep -ac "name=sms-key" "$LOG" 2>/dev/null || true)
enter_keys() {
    r=0
    while [ $r -lt 3 ]; do
        qmp_tap 176 462   # C: reset
        k=0
        while [ $k -lt 20 ]; do
            N1=$(grep -ac "name=sms-key" "$LOG" 2>/dev/null || true)
            [ $((N1 - NBASE)) -ge 1 ] 2>/dev/null && break
            sleep 2; k=$((k + 1))
        done
        NBASE=$(grep -ac "name=sms-key" "$LOG" 2>/dev/null || true)
        printf '%s
' "$SMSKEYS" | while read -r c kx ky; do
            [ -n "$c" ] || continue
            qmp_tap "$kx" "$ky"   # $c
            k=0
            while :; do
                N1=$(grep -ac "name=sms-key" "$LOG" 2>/dev/null || true)
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
            grep -aq "name=sms-key c=1 to=+15550001" "$LOG" 2>/dev/null && return 0
            sleep 2; k=$((k + 1))
            [ $k -gt 45 ] && break
        done
        LAST=$(grep -a "name=sms-key c=" "$LOG" 2>/dev/null | tail -1)
        say "recipient entry produced: $(printf '%s' "$LAST" | grep -o 'to=[+0-9]*') — restarting"
        r=$((r + 1))
    done
    return 1
}
enter_keys || fail "recipient entry never produced +15550001"
tap_key 446 342 sms-key h "txt=h" "letter h (txt h)"
tap_key 524 342 sms-key i "txt=hi" "letter i (txt hi)"
tap_retry 230 584 "name=sms-send-denied" "send was not refused by the bound deny (permission leak?)"
say "send refused by the bound telephony.sms deny"
wait_guest "name=sms-app-granted" 2700000 1800 "selftest never flipped the user grant"
say "user grant flipped"

# 3. the RECEIVE leg: the network delivers an SMS while the app is
#    open; the daemon must read it off the store and journal it, the
#    app must surface it through its permission-checked sms-list poll
python3 "$OXDIR/tools/modem-inject.py" /tmp/ox-modem-emu-ctl \
    +15550002 "meet at the dock at 9" > /dev/null
say "inbound SMS injected (+15550002)"
grep -aq "SMS-INJECT idx=1 from=+15550002" "$EMU" || fail "emulator never stored the message"
wait_guest "name=modem-sms-received from=+15550002" 1080000 1800 "daemon never read the delivered SMS (CMTI->CMGR broken?)"
grep -aq "SMS-READ idx=1 from=+15550002" "$EMU" || fail "daemon never issued AT+CMGR (store read broken)"
grep -aq "SMS-DELETE idx=1" "$EMU" || fail "daemon never deleted the store entry (CMGD broken)"
say "daemon read + stored + deleted the delivered SMS"
wait_guest "name=sms-received from=+15550002" 1080000 1800 "app never surfaced the received SMS (inbox poll broken?)"
say "app surfaced the received SMS through the gated sms-list"

# 4. the granted SEND still goes to the radio
tap_retry 230 584 "name=sms-sent" "send never completed after the grant"
grep -aq "SMS-SENT to +15550001: 'hi'" "$EMU" || fail "radio never received the outbound message"
say "outbound confirmed: radio logged SMS-SENT to +15550001 body hi"

# 5. close + reap
qmp_tap 877 662   # Close
wait_guest "name=sms-exit" 1080000 1800 "Messaging app never exited"
wait_guest "intent-exit app=Messaging" 1080000 1800 "intentd never reaped the Messaging app"
say "closed and reaped"

kill "$EMU_PID" 2>/dev/null || true
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — Messaging receive: network SMS -> CMTI -> daemon CMGR read + journal + CMGD -> app inbox through the gated sms-list; send leg still honest (deny -> grant -> radio)"
echo "SMS RECV GATE ALL GREEN"
