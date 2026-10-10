#!/usr/bin/env python3
"""LUKS2 data volume: build-payload ships a formatted-but-empty encrypted
data image + dev key (R-22); run-qemu stops mistaking LUKS for unformatted."""

def patch(path, subs):
    with open(path, "r", encoding="utf-8", newline="") as f:
        text = f.read().replace("\r\n", "\n")
    for old, new in subs:
        n = text.count(old)
        assert n == 1, f"{path}: anchor found {n}x (expected 1):\n{old[:80]}"
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print(f"patched {path} ({len(subs)} edits)")

patch("tools/build-payload.sh", [
    ('''{
    echo "OX_DATA_SECTORS=$OX_DATA_SECTORS"''',
     '''# --- dev data volume: LUKS2 container, unlocked natively by ox-init --------
# The data volume is per-deployment state (like a factory-provisioned
# phone): the image ships pre-formatted but empty. The passphrase is the
# documented DEV passphrase (risk R-22) and must never become a production
# secret. The guest unlocker (ox-init luks_try_unlock) supports LUKS2 with
# a pbkdf2 keyslot and xts-plain64 area encryption — pinned here, because
# cryptsetup's default keyslot KDF (argon2id) is not implemented there.
if [ ! -f "$OUT/data.img" ]; then
    dd if=/dev/zero of="$OUT/data.img" bs=1M count=256 status=none
fi
if [ ! -f "$OUT/data.img.key" ]; then
    printf 'ox-dev-data-passphrase-1\\n' >"$OUT/data.img.key"
    chmod 600 "$OUT/data.img.key"
fi
LUKSIG="$(head -c 6 "$OUT/data.img" | od -An -tx1 | tr -d ' \\n')"
if [ "$LUKSIG" != "4c554b53babe" ]; then
    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \\
        --pbkdf-force-iterations 10000 --batch-mode \\
        --key-file "$OUT/data.img.key" "$OUT/data.img"
fi

{
    echo "OX_DATA_SECTORS=$OX_DATA_SECTORS"'''),
])

patch("targets/qemu-virt-aarch64/run-qemu.sh", [
    ('''# The data volume ships unformatted; put an ext4 signature on it once so the
# guest can mount /dev/vdc at /data. Dev path: plain, unencrypted — the LUKS
# formatting flow is the follow-up.
SIG="$(dd if="$DATA_IMG" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \\n')"
if [ "$SIG" != "53ef" ]; then
    command -v mkfs.ext4 >/dev/null 2>&1 || {
        echo "ERROR: mkfs.ext4 needed to format $DATA_IMG" >&2; exit 5; }
    mkfs.ext4 -q -F "$DATA_IMG"
fi''',
     '''# Data volume signature policy: LUKS (the designed path) and plain ext4
# payloads boot as they are; a blank image gets LUKS2-formatted with the
# payload's dev key (risk R-22) when available, ext4 otherwise.
LUKSIG="$(dd if="$DATA_IMG" bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \\n')"
EXTSIG="$(dd if="$DATA_IMG" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \\n')"
if [ "$LUKSIG" != "4c554b53babe" ] && [ "$EXTSIG" != "53ef" ]; then
    if [ -f "$PAYLOAD/data.img.key" ] && command -v cryptsetup >/dev/null 2>&1; then
        cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \\
            --pbkdf-force-iterations 10000 --batch-mode \\
            --key-file "$PAYLOAD/data.img.key" "$DATA_IMG"
    else
        command -v mkfs.ext4 >/dev/null 2>&1 || {
            echo "ERROR: cryptsetup or mkfs.ext4 needed to format $DATA_IMG" >&2
            exit 5; }
        mkfs.ext4 -q -F "$DATA_IMG"
    fi
fi'''),
])

print("ALL PATCHES OK")
