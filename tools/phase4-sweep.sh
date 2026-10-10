#!/bin/sh
# Phase-4 close-out sweep: EVERY Phase-4 gate on the FINAL payload.
# Each gate's own -run.sh is used (fresh payload clone + clean data
# volume per gate, exactly as originally proven). Gates run
# sequentially; a failure does not stop the sweep (a stray QEMU is
# killed between gates) so one run collects the full picture.
set -u
cd /root/oxbuild
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
"$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths --offline \
    --option cores 4 --max-jobs 1 \
    2>/tmp/nixerr.txt > /tmp/nixout.txt || { echo "BUILD FAILED"; tail -6 /tmp/nixerr.txt; exit 1; }
echo "BUILD OK"
# Chunk 66: root the fresh outputs so no future nix-collect-garbage can
# strand --offline builds (the Oct-3 store loss: toolchain tarballs
# unreachable + one mirror's cert expired = hours of re-fetch).
bash tools/gc-keep-current.sh >/dev/null 2>&1 || true

# s6 integrity guard (2026-09-27): a build that read a partial tree once
# produced a payload whose s6 runtime was missing services (lockd gone →
# unlock impossible → five hours of garbage gate failures). ~1 minute
# here now fails the sweep fast instead. Extract the image and count
# service dirs; they must match the repo tree.
P="$(sed -n 1p /tmp/nixout.txt)"
IN_TREE=$(ls system/s6-rc-source | wc -l)
rm -rf /tmp/sqcheck && unsquashfs -q -d /tmp/sqcheck "$P/system.img" >/dev/null 2>&1
IN_IMG=$(ls /tmp/sqcheck/etc/s6-rc/source 2>/dev/null | wc -l)
rm -rf /tmp/sqcheck
echo "S6 INTEGRITY tree=$IN_TREE image=$IN_IMG"
[ "$IN_IMG" -ge "$IN_TREE" ] || { echo "S6 INTEGRITY FAILED — payload is incomplete"; exit 1; }

GATES="modem-gate gnss-gate bt-gate wifi-gate camera-gate camera-app-gate \
dialer-app-gate mt-call-gate sms-app-gate sms-recv-gate \
messages-store-gate nfc-gate usb-gate tiles-gate grid-event-gate uninstall-gate"

pass=""
fail=""
for g in $GATES; do
    pkill -f '[q]emu-system-aarch64' >/dev/null 2>&1 || true
    pkill -f 'modem-emu.py' >/dev/null 2>&1 || true
    pkill -f 'gnss-emu.py' >/dev/null 2>&1 || true
    pkill -f 'nfc-emu.py' >/dev/null 2>&1 || true
    sleep 3
    echo "=== SWEEP $g $(date -u +%H:%M:%S)"
    if bash "tools/$g-run.sh" > "/tmp/sweep-$g.log" 2>&1; then
        echo "PASS $g"
        pass="$pass $g"
    else
        echo "FAIL $g (log: /tmp/sweep-$g.log)"
        fail="$fail $g"
    fi
done
pkill -f '[q]emu-system-aarch64' >/dev/null 2>&1 || true
echo "SWEEP PASS:$pass"
echo "SWEEP FAIL:${fail:- none}"
if [ -z "$fail" ]; then
    echo "PHASE4 SWEEP ALL GREEN"
else
    echo "PHASE4 SWEEP HAD FAILURES"
    exit 1
fi
