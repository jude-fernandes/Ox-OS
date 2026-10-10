#!/usr/bin/env bash
# Boot-attack suite for the Phase-1 virtual target (verified boot).
# Control boot must succeed; each tampered variant must be REFUSED
# ("integrity FATAL" on the console and no userspace-ready milestone).
#
# usage: boot-attack.sh [TIMEOUT_S_PER_BOOT]   (default 300)
set -u
OX="$(cd "$(dirname "$0")/.." && pwd)"
TMO="${1:-300}"
P=/tmp/ox-attack/payload
LOGD=/tmp/ox-attack-logs
K=/tmp/ox-kbuild/Image
FAIL=0
mkdir -p "$LOGD"

say() { printf '[boot-attack] %s\n' "$*"; }
bad() { printf '[boot-attack] FAIL: %s\n' "$*" >&2; FAIL=1; }

run_boot() { # $1 = label, $2 = expected: ok|refuse
    local attempt log want_ok
    want_ok=0; [ "$2" = "ok" ] && want_ok=1
    for attempt in 1 2; do
        bash "$OX/tools/boot-test.sh" "$P" "$K" "$TMO" >/dev/null 2>&1
        log="$P/serial.log"
        cp "$log" "$LOGD/serial-$1-try$attempt.log" 2>/dev/null
        if grep -aq "integrity FATAL" "$log"; then
            if [ "$want_ok" = 1 ]; then
                bad "$1: legitimate boot refused!"; return 1
            fi
            grep -aq "userspace-ready" "$log" &&
                { bad "$1: FATAL yet booted?!"; return 1; }
            say "refused as expected ($1)"
            return 0
        fi
        if grep -aq "userspace-ready" "$log"; then
            if [ "$want_ok" = 1 ]; then
                say "booted as expected ($1)"
                return 0
            fi
            bad "$1: tampered payload BOOTED"
            return 1
        fi
        # R-20: occasional TCG stalls produce silent runs; retry once
        [ "$attempt" = 1 ] && say "$1: silent run (R-20?), retrying"
    done
    bad "$1: neither refused nor reached userspace-ready"
    return 1
}

build() {
    rm -rf "$P"
    OX_IMG_FMT=squashfs OX_VERBOSE=0 OX_SKIP_VERITY=1 \
        OX_VERIFY_FULL=1 OX_BUSYBOX=/tmp/ox-aarch64/busybox \
        bash "$OX/tools/build-payload.sh" qemu-virt-aarch64 \
        /tmp/ox-boot/rootfs "$K" "$P" >/dev/null 2>&1
    [ -f "$P/system.img" ] || { echo "payload build failed" >&2; exit 3; }
    chmod a+r "$P"/system*.img "$P/initramfs.img"
}

cp "$P/system.img" "$LOGD/system.img.bak" 2>/dev/null || true
build
cp "$P/system.img" "$LOGD/system.img.bak"

say "control boot (verified, full-image)"
run_boot control ok || true

say "attack A: flip one byte inside system image"
printf '\xFF' | dd of="$P/system.img" bs=1 seek=4194304 conv=notrunc status=none
run_boot attack-A refuse || true
cp "$LOGD/system.img.bak" "$P/system.img"

say "attack B: falsify image size inside signed manifest"
rm -rf /tmp/ox-attack/irdb && mkdir -p /tmp/ox-attack/irdb
(cd /tmp/ox-attack/irdb && zcat "$P/initramfs.img" | cpio -idm --quiet)
sed -i 's/^sys_bytes=.*/sys_bytes=1/' \
    /tmp/ox-attack/irdb/etc/ox-manifest.bin
(cd /tmp/ox-attack/irdb && find . | cpio -o -H newc --owner 0:0 2>/dev/null |
    gzip -9) >"$P/initramfs.img"
chmod a+r "$P/initramfs.img"
run_boot attack-B refuse || true
build   # cheapest clean restore

say "attack C: tamper signed manifest inside initramfs"
rm -rf /tmp/ox-attack/ird && mkdir -p /tmp/ox-attack/ird
(cd /tmp/ox-attack/ird && zcat "$P/initramfs.img" | cpio -idm --quiet)
sed -i 's/^root_hash=./root_hash=0/' /tmp/ox-attack/ird/etc/ox-manifest.bin
(cd /tmp/ox-attack/ird && find . | cpio -o -H newc --owner 0:0 2>/dev/null |
    gzip -9) >"$P/initramfs.img"
chmod a+r "$P/initramfs.img"
run_boot attack-C refuse || true

[ "$FAIL" -eq 0 ] && say "ALL GREEN" || say "SUITE FAILED"
exit "$FAIL"
