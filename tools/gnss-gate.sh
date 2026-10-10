#!/bin/sh
# GNSS gate (Phase 4): the location stack end to end on a VIRTUAL
# receiver. The host-side NMEA emulator feeds a virtio-serial port
# ("oxgnss.0"); ox-gnssd owns the port, parses the stream and
# publishes the last-known fix; ox-locationd serves it to a GRANTED
# app through permstored. The gate requires, in order: daemon finds
# the port -> honest no-fix leg (receiver up, no fix yet) -> REAL fix
# acquired with coordinates matching the emulator -> the permission
# layer serves exactly that fix to a granted app (synthetic:false).
# usage: gnss-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-1200}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-gnssgate
LOG="$OUT/serial-gnss.log"
EMU="$OUT/gnss-emu.log"
EMUOUT="$OUT/gnss-emu.stderr"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon /tmp/ox-gnss-emu.sock

say() { printf '[ox-gnss] %s\n' "$*"; }
fail() { printf '[ox-gnss] FAIL: %s\n' "$*" >&2; exit 1; }

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

EMU_LAT=37.774933
EMU_LON=-122.419416

# 1. emulator up first (QEMU connects out to it, with reconnect)
python3 "$OXDIR/tools/gnss-emu.py" --sock /tmp/ox-gnss-emu.sock \
    --log "$EMU" --lat "$EMU_LAT" --lon "$EMU_LON" \
    > "$EMUOUT" 2>&1 &
EMU_PID=$!
sleep 1
kill -0 "$EMU_PID" 2>/dev/null || fail "gnss emulator did not start"
trap 'kill "$EMU_PID" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true' EXIT

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=0 OX_VERBOSE=1 OX_QEMU_EXTRA="-chardev socket,id=oxgnss,path=/tmp/ox-gnss-emu.sock,server=off,reconnect=3 \
    -device virtio-serial-pci,id=oxgnssser \
    -device virtserialport,chardev=oxgnss,name=oxgnss.0" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 2. daemon owns the receiver port (found via sysfs port name)
wait_ms "name=gnssd-ready transport=" 240 "ox-gnssd never found the receiver port (virtio-serial wiring? sysfs name?)"
say "receiver owned by ox-gnssd:"
grep -a "name=gnssd-ready transport=" "$LOG" | tail -1 | sed 's/^/[ox-gnss]   /'

# 3. honest no-fix leg: the emulator holds a no-fix phase first; the
# daemon must journal it rather than inventing coordinates
wait_ms "name=gnss-no-fix" 120 "gnssd never reported the honest no-fix state"
say "no-fix state journaled before the first fix"

# 4. fix acquired: real NMEA parsed; coordinates must match the
# emulator's position (nothing else could produce them)
wait_ms "name=gnss-fix lat=" 300 "gnssd never acquired a fix from the NMEA stream"
LINE=$(grep -a "name=gnss-fix lat=" "$LOG" | tail -1)
say "$LINE"
GLAT=$(printf '%s' "$LINE" | grep -o 'lat=[-0-9.]*' | cut -d= -f2)
GLON=$(printf '%s' "$LINE" | grep -o 'lon=[-0-9.]*' | cut -d= -f2)
check() {
    python3 - "$1" "$2" <<'PYEOF'
import sys
got, want, tol = float(sys.argv[1]), float(sys.argv[2]), 0.002
assert abs(got - want) <= tol, "got %r want %r" % (got, want)
PYEOF
}
check "$GLAT" "$EMU_LAT" || fail "fix latitude $GLAT does not match emulator $EMU_LAT"
check "$GLON" "$EMU_LON" || fail "fix longitude $GLON does not match emulator $EMU_LON"
say "fix coordinates match the emulator ($GLAT, $GLON)"
grep -aq "FIX ACQUIRED" "$EMU" || fail "emulator never announced a fix"
grep -aq "DBG-GNSS-DRIVER" "$LOG" || fail "selftest never consulted the driver"

# 5. permission layer: a GRANTED app asks locationd and receives
# exactly the receiver's fix (synthetic:false) — never the synthetic
# one, never a refusal
wait_ms "name=gnss-location-grant-ok lat=" 300 "granted app never received the real fix through locationd"
say "granted app got the REAL fix via locationd (permstored grant):"
grep -a "name=gnss-location-grant-ok" "$LOG" | tail -1 | sed 's/^/[ox-gnss]   /'
LLAT=$(grep -a "name=gnss-location-grant-ok" "$LOG" | tail -1 | grep -o 'lat=[-0-9.]*' | cut -d= -f2)
LLON=$(grep -a "name=gnss-location-grant-ok" "$LOG" | tail -1 | grep -o 'lon=[-0-9.]*' | cut -d= -f2)
check "$LLAT" "$EMU_LAT" || fail "served latitude $LLAT does not match the receiver"
check "$LLON" "$EMU_LON" || fail "served longitude $LLON does not match the receiver"
grep -a "DBG-GNSS-GRANT" "$LOG" | tail -1 | cut -c1-220 | sed 's/^/[ox-gnss]   /'

kill "$EMU_PID" 2>/dev/null || true
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — GNSS: NMEA over virtio-serial -> ox-gnssd parser -> last-known store -> permstored-gated locationd fix"
echo "GNSS GATE ALL GREEN"
