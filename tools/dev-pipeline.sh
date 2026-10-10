#!/bin/sh
# End-to-end Phase-1 pipeline test on any Linux host, no root required.
# Produces a complete signed payload using a stub kernel (assembly test only).
set -eu
OUT="${1:-/tmp/ox-out}"
TOOLSDIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$TOOLSDIR/.." && pwd)"
ROOTFS="$OUT/rootfs"
rm -rf "$ROOTFS"
mkdir -p "$OUT" "$ROOTFS"/{bin,sbin,etc,data,dev,proc,sys,run,tmp,newroot}
chmod 1777 "$ROOTFS/tmp"

BUSYBOX="${OX_BUSYBOX:-$(command -v busybox)}"
[ -n "$BUSYBOX" ] || { echo "ERROR: install busybox-static" >&2; exit 3; }
case "${TARGET:-qemu-virt-aarch64}" in
    *aarch64*)
        if command -v file >/dev/null 2>&1; then
            file "$BUSYBOX" | grep -qi aarch64 || {
                echo "ERROR: busybox is not aarch64 (build one: tools/build-busybox.sh;" >&2
                echo "       then rerun with OX_BUSYBOX=<path>)" >&2
                exit 3; }
        fi
        ;;
esac
cp -L "$BUSYBOX" "$ROOTFS/bin/busybox"
HOST_BB="$(command -v busybox)"
for applet in $("$HOST_BB" --list); do
    [ "$applet" = "busybox" ] && continue
    ln -sf busybox "$ROOTFS/bin/$applet"
done
[ -f "$ROOTFS/bin/busybox" ] && [ ! -L "$ROOTFS/bin/busybox" ] \
    || { echo "ERROR: bin/busybox corrupted during applet install" >&2; exit 4; }
[ -L "$ROOTFS/bin/sh" ] && [ -e "$ROOTFS/bin/sh" ] \
    || { echo "ERROR: bin/sh applet link missing" >&2; exit 4; }
LINKS=$(find "$ROOTFS/bin" -type l | wc -l)
[ "$LINKS" -gt 50 ] || { echo "ERROR: only $LINKS applet links created" >&2; exit 4; }

# --- s6/s6-rc runtime + compiled service database -----------------------------
S6BIN="${OX_S6_AARCH64:-/tmp/ox-s6/aarch64/usr/bin}"
RCOMP="${OX_S6_RC_COMPILE:-/tmp/ox-s6/host/usr/bin/s6-rc-compile}"
SRCDIR="$(cd "$(dirname "$0")/../system/s6-rc-source" && pwd)"
if [ -x "$S6BIN/s6-svscan" ] && [ -d "$SRCDIR/default" ]; then
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/libexec"
    cp -f "$S6BIN"/* "$ROOTFS/usr/bin/"
    cp -f /tmp/ox-s6/aarch64/usr/libexec/* "$ROOTFS/usr/libexec/"
    rm -rf "$ROOTFS/etc/s6-rc"
    mkdir -p "$ROOTFS/etc/s6-rc"
    if ! "$RCOMP" "$ROOTFS/etc/s6-rc/compiled.new" "$SRCDIR"; then
        find "$SRCDIR" -mindepth 1 -maxdepth 1 -type d | sort | \
            "$RCOMP" "$ROOTFS/etc/s6-rc/compiled.new"
    fi
    mv "$ROOTFS/etc/s6-rc/compiled.new" "$ROOTFS/etc/s6-rc/compiled"
    echo "[pipeline] s6 runtime installed; service DB compiled ($(ls "$ROOTFS/etc/s6-rc/compiled" | wc -l) entries)"
fi

cp "$SRC/system/sbin/ox-init-stage2" "$ROOTFS/sbin/"
chmod +x "$ROOTFS/sbin/ox-init-stage2"

# --- guest Rust daemons (static aarch64, built by tools/build-oxcom.sh) -------
install_guest_bin() {
    SRC_BIN="$1"; NAME="$2"
    [ -f "$SRC_BIN" ] || { echo "[pipeline] $NAME: no guest binary at $SRC_BIN (skipped)"; return 0; }
    if command -v file >/dev/null 2>&1; then
        file "$SRC_BIN" | grep -qi aarch64 || {
            echo "ERROR: $SRC_BIN is not aarch64 (rebuild via tools/build-oxcom.sh)" >&2
            exit 3; }
        file "$SRC_BIN" | grep -qi "statically linked" || {
            echo "ERROR: $SRC_BIN is dynamically linked; guest has no shared libc" >&2
            exit 3; }
    fi
    cp -f "$SRC_BIN" "$ROOTFS/usr/bin/$NAME"
    chmod +x "$ROOTFS/usr/bin/$NAME"
    echo "[pipeline] guest daemon installed: /usr/bin/$NAME"
}
install_guest_bin "${OXCOM_BIN:-/tmp/ox-rust/oxcom}" oxcom
install_guest_bin "${OXPAY_BIN:-/tmp/ox-rust/oxpaymentsd}" oxpaymentsd
install_guest_bin "${OXSTATUS_BIN:-/tmp/ox-rust/ox-status}" ox-status
install_guest_bin "${OXINPUT_BIN:-/tmp/ox-rust/inputd}" inputd
install_guest_bin "${OXPOWER_BIN:-/tmp/ox-rust/powerd}" powerd
install_guest_bin "${OXCTL_BIN:-/tmp/ox-rust/oxctl}" oxctl

mkdir -p "$ROOTFS/etc/s6-rc/source"
cp -r "$SRC/system/s6-rc-source/." "$ROOTFS/etc/s6-rc/source/"

STUB_KERNEL="$OUT/stub-Image"
dd if=/dev/urandom of="$STUB_KERNEL" bs=1M count=8 status=none
echo "NOTE: stub kernel used for assembly/signing test only"

bash "$TOOLSDIR/build-payload.sh" qemu-virt-aarch64 \
    "$ROOTFS" "$STUB_KERNEL" "$OUT/payload"

echo "--- payload contents ---"
ls -l "$OUT/payload"
echo "PIPELINE OK"
