#!/bin/sh
# Chain job: wait for the running kernel build to write its verdict,
# then immediately build the payload and run the modem gate. All the
# waiting happens inside WSL — the session is not involved.
while :; do
    grep -q "^KERNEL_OK" /tmp/kout.txt 2>/dev/null && break
    grep -q "KERNEL BUILD FAILED" /tmp/kout.txt 2>/dev/null && break
    # if the build process died without a verdict, stop waiting
    if ! pgrep -f kernel-rebuild.sh >/dev/null 2>&1; then
        sleep 5
        pgrep -f kernel-rebuild.sh >/dev/null 2>&1 || break
    fi
    sleep 60
done
grep -q "^KERNEL_OK" /tmp/kout.txt 2>/dev/null || {
    echo "KERNEL BUILD FAILED"
    tail -6 /tmp/kerr.txt 2>/dev/null
    exit 1
}
cat /tmp/kout.txt
bash /tmp/modem-gate-run.sh
