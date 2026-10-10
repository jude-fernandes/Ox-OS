#!/bin/sh
# Assemble the Ox OS system image (erofs) from a rootfs directory.
# usage: mksystem-image.sh ROOTFS_DIR OUT.img
set -eu

[ $# -eq 2 ] || { echo "usage: $0 ROOTFS_DIR OUT.img" >&2; exit 2; }
ROOTFS="$1"; OUT="$2"
[ -d "$ROOTFS" ] || { echo "no such rootfs dir: $ROOTFS" >&2; exit 2; }

command -v mkfs.erofs >/dev/null 2>&1 || {
    echo "ERROR: mkfs.erofs not found (apt install erofs-utils)" >&2; exit 3; }

IMG_FMT="${OX_IMG_FMT:-squashfs}"

TREE_HASH="$(tar -C "$ROOTFS" --sort=name --mtime=0 --owner=0 --group=0 \
    --numeric-owner --clamp-mtime -cf - . | sha256sum | cut -d' ' -f1)"

rm -f "$OUT"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
ROOTFS_ABS="$(cd "$ROOTFS" && pwd)"
PARENT="$(dirname "$ROOTFS_ABS")"
BASE="$(basename "$ROOTFS_ABS")"

if [ "$IMG_FMT" = "squashfs" ]; then
    command -v mksquashfs >/dev/null 2>&1 || {
        echo "ERROR: mksquashfs not found (apt install squashfs-tools)" >&2; exit 3; }
    SORTF="$(mktemp)"
    # mksquashfs sort-file entries are whitespace-separated from the
    # priority, so paths containing spaces (e.g. alsa-ucm-conf's
    # "Librem 5.conf", which arrived with the bluez closure) cannot be
    # listed at all — exclude them; they just use default inode order.
    (cd "$ROOTFS_ABS" && find . | sed 's|^\./||' | LC_ALL=C sort |
        grep -vx '.' | grep -v ' ' | sed 's/$/ 0/' > "$SORTF")
    (cd "$PARENT" && mksquashfs "$BASE" "$OUT_ABS" \
        -comp zstd -Xcompression-level 15 \
        -all-root -all-time 0 -root-time 0 -mkfs-time 0 \
        -no-exports -no-recovery -quiet -no-progress \
        -processors 1 -sort "$SORTF")
    rm -f "$SORTF"
else
    UUID="$(printf '%s-%s-%s-%s-%s' \
        "$(printf '%s' "$TREE_HASH" | cut -c1-8)" \
        "$(printf '%s' "$TREE_HASH" | cut -c9-12)" \
        "$(printf '%s' "$TREE_HASH" | cut -c13-16)" \
        "$(printf '%s' "$TREE_HASH" | cut -c17-20)" \
        "$(printf '%s' "$TREE_HASH" | cut -c21-32)")"
    (cd "$PARENT" \
        && mkfs.erofs -U "$UUID" -T 0 -C 65536 --all-root \
             -E fragments=4096 "$OUT_ABS" "$BASE")
fi

OXM_TMS="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)"
echo "OXMILESTONE name=system-image-built tms=$OXM_TMS size=$(wc -c <"$OUT") fmt=$IMG_FMT treehash=$TREE_HASH"
