#!/bin/sh
# Debug: does an HMP system_wakeup resume a PM-suspended guest?
set -u
cd /root/oxbuild
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
rm -rf /tmp/ox-waketest && mkdir -p /tmp/ox-waketest
cp -r "$P"/. /tmp/ox-waketest/
rm -f /tmp/ox-waketest/data.img /tmp/ox-waketest/data.img.key
LOG=/tmp/ox-waketest/serial.log
(OX_GFX=0 timeout 300 bash targets/qemu-virt-aarch64/run-qemu.sh \
    /tmp/ox-waketest "$K" "$LOG" >/dev/null 2>&1 &)

# wait for the suspend (the PM selftest fires it early)
suspended=no
for i in $(seq 1 90); do
    if grep -aq 'Suspending console' "$LOG" 2>/dev/null; then suspended=yes; break; fi
    sleep 2
done
echo "suspended=$suspended at $(date -u +%H:%M:%S)"
if [ "$suspended" != yes ]; then
    echo "guest never suspended (check log)"; tail -3 "$LOG" | cut -c1-120; exit 1
fi

# give the alarm a chance to wake it on its own first (30s)
for i in $(seq 1 15); do
    if grep -aq 'name=pm-resumed' "$LOG" 2>/dev/null; then break; fi
    sleep 2
done
if grep -aq 'name=pm-resumed' "$LOG" 2>/dev/null; then
    echo "WAKE: rtc alarm resumed the guest on its own"
else
    echo "WAKE: rtc alarm did NOT resume the guest in 30s — nudging via HMP system_wakeup"
    python3 - <<'PYEOF'
import socket, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmon")
time.sleep(0.5)
s.recv(4096)
s.sendall(b"system_wakeup\n")
time.sleep(1)
print("system_wakeup sent")
PYEOF
    for i in $(seq 1 20); do
        if grep -aq 'name=pm-resumed' "$LOG" 2>/dev/null; then
            echo "WAKE: system_wakeup RESUMED the guest"
            break
        fi
        sleep 2
    done
    grep -aq 'name=pm-resumed' "$LOG" 2>/dev/null && echo "RESULT: WAKE-ASSIST WORKS" || echo "RESULT: GUEST STILL FROZEN"
fi
pkill -f '[q]emu-system' 2>/dev/null || true
exit 0
