#!/bin/sh
# Ox OS Phase-1 self-test suite: syntax, keytool roundtrip, boottime parser,
# full image pipeline. Runs unprivileged on any Linux host.
set -eu
cd "$(dirname "$0")/.."
FAIL=0

say() { printf '[ox-selftest] %s\n' "$*"; }
bad() { printf '[ox-selftest] FAIL: %s\n' "$*" >&2; FAIL=1; }

for f in tools/*.sh targets/qemu-virt-aarch64/run-qemu.sh \
         system/sbin/ox-init-stage2 ox; do
    if sh -n "$f"; then say "syntax ok   $f"; else bad "syntax     $f"; fi
done

python3 -m py_compile tools/ox-keytool.py tools/boottime-parse.py \
    && say "py_compile ok" || bad "py_compile"

if python3 tools/ox-keytool.py selftest; then say "keytool ok"; else bad "keytool"; fi

if sh tools/test-bootimg.sh >/tmp/ox-bootimg.log 2>&1; then
    say "bootimg packager ok"
else
    bad "bootimg packager ($(tail -2 /tmp/ox-bootimg.log | head -1))"
fi

if sh tools/test-fit.sh >/tmp/ox-fit.log 2>&1; then
    say "fit packager ok"
else
    bad "fit packager ($(tail -2 /tmp/ox-fit.log | head -1))"
fi

if sh tools/test-rust.sh >/tmp/ox-rust-test.log 2>&1; then
    tail -1 /tmp/ox-rust-test.log | sed 's/^/[ox-selftest] rust: /'
else
    bad "rust workspace ($(tail -2 /tmp/ox-rust-test.log | head -1))"
fi

if sh tools/build-oxcom.sh >/tmp/ox-cross.log 2>&1; then
    say "guest daemon cross-build ok (aarch64 musl static)"
elif grep -q "SKIP: no cargo toolchain" /tmp/ox-cross.log; then
    say "guest daemon cross-build SKIPPED (no toolchain)"
else
    bad "guest daemon cross-build ($(tail -2 /tmp/ox-cross.log | head -1))"
fi

if python3 tools/boottime-parse.py tools/TEST-sample-boot.log \
        --max-total 8 --budget userspace-ready=4 >/dev/null 2>&1; then
    say "boottime fixture ok"
else
    bad "boottime fixture"
fi

NEG="$(mktemp)"
printf 'OXMILESTONE name=a tms=0.1\nOXMILESTONE name=b tms=9.5\n' >"$NEG"
if python3 tools/boottime-parse.py "$NEG" --max-total 8 >/dev/null 2>&1; then
    bad "boottime negative case unexpectedly passed"
else
    say "boottime budget enforcement ok"
fi
rm -f "$NEG"

if command -v mkfs.erofs >/dev/null 2>&1 && command -v veritysetup >/dev/null 2>&1; then
    if [ ! -f "${OX_BUSYBOX:-/tmp/ox-aarch64/busybox}" ]; then
        say "image pipeline SKIPPED (no aarch64 busybox; run tools/build-busybox.sh)"
    elif OX_IMG_FMT=squashfs OX_BUSYBOX="${OX_BUSYBOX:-/tmp/ox-aarch64/busybox}" \
         bash tools/dev-pipeline.sh /tmp/ox-selftest-out >/dev/null 2>&1; then
        say "image pipeline ok (squashfs CI fmt)"
    else
        bad "image pipeline"
    fi

    if command -v mksquashfs >/dev/null 2>&1; then
        OX_IMG_FMT=squashfs OX_BUSYBOX="${OX_BUSYBOX:-/tmp/ox-aarch64/busybox}" \
            bash tools/dev-pipeline.sh /tmp/ox-selftest-out2 >/dev/null 2>&1
        for artifact in system.img system.hash.img; do
            H1=$(sha256sum "/tmp/ox-selftest-out/payload/$artifact" | cut -d' ' -f1)
            H2=$(sha256sum "/tmp/ox-selftest-out2/payload/$artifact" | cut -d' ' -f1)
            if [ "$H1" = "$H2" ]; then
                say "reproducible  $artifact ($H1)"
            else
                bad "reproducible $artifact: $H1 != $H2"
            fi
        done
    fi
else
    say "SKIP pipeline (install erofs-utils + cryptsetup-bin)"
fi

# LUKS2 unlock-path validation (host-side; requires root for cryptsetup)
if [ "$(id -u)" = 0 ] && command -v cryptsetup >/dev/null 2>&1; then
    if bash tools/luks-selftest.sh >/dev/null 2>&1; then
        say "luks2 unlock path ok (volume key matches cryptsetup)"
    else
        bad "luks2 unlock path"
    fi
else
    say "SKIP luks2 (needs root + cryptsetup)"
fi

[ "$FAIL" -eq 0 ] && say "ALL GREEN" || say "SUITE FAILED"
exit "$FAIL"
