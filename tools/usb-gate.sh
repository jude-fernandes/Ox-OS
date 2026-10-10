#!/bin/sh
. "$(dirname "$0")/gate-lib.sh"   # chunk-54 guest-time waits
# USB gate (Phase 4): the quarantine lifecycle on a REAL (emulated)
# xHCI bus. The gate hot-plugs a USB stick at runtime (QEMU HMP
# device_add), ox-usbd must journal usb-added + usb-quarantined, and
# the kernel must have NO block device for it (drivers unbound).
# The on-guest selftest walks the usb.read matrix over that REAL
# device (deny refused / fake synthetic no-leak / grant with
# authorized:false), then authorizes it (the system "allow" tap) and
# requires the block device to APPEAR. Finally the gate unplugs the
# stick and requires usb-removed.
# usage: usb-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-1200}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-usbgate
LOG="$OUT/serial-usb.log"
rm -rf "$OUT"; mkdir -p "$OUT"
dd if=/dev/zero of="$OUT/stick.img" bs=1M count=8 2>/dev/null

say() { printf '[ox-usb] %s\n' "$*"; }
fail() { printf '[ox-usb] FAIL: %s\n' "$*" >&2; exit 1; }

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


hmp() {
    python3 - "$1" <<'PYEOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmon")
time.sleep(0.5)
s.recv(4096)
s.sendall((sys.argv[1] + "\n").encode())
time.sleep(0.5)
print("[ox-usb] hmp: %s" % sys.argv[1])
PYEOF
}

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=0 OX_VERBOSE=1 OX_QEMU_EXTRA="-device qemu-xhci,id=xhci \
    -drive if=none,id=stick,format=raw,file=$OUT/stick.img" \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# 1. the daemon is up; no USB storage device may exist yet
wait_guest "name=usbd-ready" 720000 1800 "ox-usbd never came up"
say "ox-usbd ready (bus watcher live)"
wait_guest "name=usb-default-unauthorized" 360000 1800 "kernel cmdline lacks usbcore.authorized_default=0"
say "plug-time safety is kernel policy: devices enumerate UNAUTHORIZED"

# the PM selftest suspends the machine early — the gate must wait out
# the suspend-resume cycle BEFORE hot-plugging, or the whole guest
# freezes mid-flow (chunk-44 finding: same rule as the app gates)
wait_guest "name=pm-drill-skipped\|name=pm-resumed" 600000 1800 "powerd PM selftest never resumed"
say "PM suspend-resume drill settled; machine awake"

# 2. hot-plug the stick; the daemon must add + QUARANTINE it
[ -S /tmp/ox-qmon ] || fail "HMP monitor socket missing"
hmp "device_add usb-storage,id=stick0,bus=xhci.0,drive=stick"
wait_guest "name=usb-added" 360000 1800 "kernel never enumerated the hot-plugged stick"
wait_guest "name=usb-quarantined" 360000 1800 "usbd never quarantined the new device"
say "stick enumerated and QUARANTINED by the daemon"
wait_guest "name=usb-quarantine-no-blockdev" 180000 1800 "quarantined stick exposed a block device (drivers not unbound!)"
say "quarantine holds: no /dev/sd* while unauthorized"

# 3. the on-guest selftest walks the usb.read matrix
wait_guest "name=usb-denied-refused" 900000 1800 "devices list was not refused under usb.read deny"
say "list refused under the bound deny"
wait_guest "name=usb-fake-synthetic" 900000 1800 "fake leg did not answer synthetic"
say "fake list: clearly synthetic, no real stick identity"
wait_guest "name=usb-list-real" 900000 1800 "grant leg never served the real (quarantined) device"
say "granted list shows the REAL stick with authorized:false"

# 4. the system "allow" tap -> drivers bind -> the block device appears
wait_guest "name=usb-authorized-blockdev" 900000 1800 "authorized stick never produced a block device"
say "authorized: block device appeared (usb-storage bound)"

# 5. unplug -> the daemon must notice the removal
hmp "device_del stick0"
wait_guest "name=usb-removed" 360000 1800 "usbd never noticed the unplug"
say "unplug noticed: bus clean"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — USB: hot-plug -> enumerated -> QUARANTINED (no blockdev) -> usb.read matrix -> authorized -> blockdev appears -> clean unplug"
echo "USB GATE ALL GREEN"
