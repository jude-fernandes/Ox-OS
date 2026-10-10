#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# NFC gate (Phase 4): the reader stack end to end on a VIRTUAL reader.
# The host-side emulator feeds a virtio-serial port ("oxnfc.0"): idle
# frames while no tag is in range, then a checksummed tag frame
# injected through the control socket. ox-nfcd must own the port,
# journal the honest no-tag leg, read the tag (checksum + parse +
# persist), and the on-guest selftest must walk the nfc.read matrix
# over that REAL tag: deny refused, fake synthetic (real text must
# not leak), grant verbatim.
# usage: nfc-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-1200}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-nfcgate
LOG="$OUT/serial-nfc.log"
EMU="$OUT/nfc-emu.log"
EMUOUT="$OUT/nfc-emu.stderr"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon /tmp/ox-nfc-emu.sock /tmp/ox-nfc-emu-ctl

say() { printf '[ox-nfc] %s\n' "$*"; }
fail() { printf '[ox-nfc] FAIL: %s\n' "$*" >&2; exit 1; }

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

NFC_UID=04a2b3c4d5e6
NFC_TEXT='boarding pass VF-2381 gate four'

# 1. emulator up first (QEMU connects out to it, with reconnect)
python3 "$OXDIR/tools/nfc-emu.py" --sock /tmp/ox-nfc-emu.sock \
    --ctl /tmp/ox-nfc-emu-ctl \
    --log "$EMU" > "$EMUOUT" 2>&1 &
EMU_PID=$!
sleep 1
kill -0 "$EMU_PID" 2>/dev/null || fail "nfc emulator did not start"
[ -S /tmp/ox-nfc-emu-ctl ] || fail "control socket missing"
trap 'kill "$EMU_PID" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true' EXIT

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=0 OX_VERBOSE=1 OX_QEMU_EXTRA="-chardev socket,id=oxnfc,path=/tmp/ox-nfc-emu.sock,server=off,reconnect=3 \
    -device virtio-serial-pci,id=oxnfcser \
    -device virtserialport,chardev=oxnfc,name=oxnfc.0" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 2. daemon owns the reader port (found via sysfs port name)
wait_guest "name=nfcd-ready transport=" 2160000 1800 "ox-nfcd never found the reader port (virtio-serial wiring? sysfs name?)"
say "reader owned by ox-nfcd:"
grep -a "name=nfcd-ready transport=" "$LOG" | tail -1 | sed 's/^/[ox-nfc]   /'

# 3. honest idle leg: the reader reports no tag; the daemon journals it
wait_guest "name=nfc-no-tag" 1080000 1800 "daemon never journaled the no-tag state"
say "no-tag state journaled (reader idle frames)"

# 4. present the tag; the frame must survive checksum + parse + persist
python3 - "$NFC_UID" "$NFC_TEXT" <<'PYEOF'
import json, socket, sys
uid, text = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-nfc-emu-ctl")
s.sendall((json.dumps({"present_tag": {"uid": uid, "text": text}}) + "\n").encode())
buf = b""
while b"\n" not in buf:
    data = s.recv(4096)
    if not data:
        break
    buf += data
reply = json.loads(buf.split(b"\n")[0].decode())
if not reply.get("ok"):
    sys.stderr.write("present refused: %r\n" % reply)
    sys.exit(1)
print("[ox-nfc] tag presented uid=%s" % uid)
PYEOF
grep -aq "TAG-PRESENTED uid=$NFC_UID" "$EMU" || fail "emulator never sent the tag frame"
wait_guest "name=nfc-tag-read uid=$NFC_UID" 1080000 1800 "daemon never read the tag (checksum/parse path broken?)"
say "tag read: checksummed frame parsed and persisted"
wait_guest "nfc-tag-persisted" 270000 1800 "tag never persisted to the driver store"

# 5. the on-guest selftest walks deny/fake/grant over that REAL tag
wait_guest "name=nfc-denied-refused" 1080000 1800 "last was not refused under nfc.read deny"
say "refused under the bound deny"
wait_guest "name=nfc-fake-synthetic" 1080000 1800 "fake leg did not answer synthetic"
wait_guest "name=nfc-real-tag-ok" 1080000 1800 "selftest never verified the matrix (grant must return the tag verbatim)"
say "permission matrix over REAL tag: deny refused, fake synthetic (no leak), grant verbatim"

kill "$EMU_PID" 2>/dev/null || true
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — NFC: reader owned -> honest no-tag -> checksummed tag read+persisted -> deny/fake/grant over the REAL tag"
echo "NFC GATE ALL GREEN"
