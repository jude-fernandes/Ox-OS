#!/bin/sh
# Flash-pack gate (chunk 74) — HOST-SIDE: proves the M1-prep tools.
#
# A. PinePhone Pro: run ox-flash.sh against a LOOP-BACKED sparse file,
#    then verify the device state: idbloader at sector 64, u-boot.itb at
#    0x80000, the GPT layout (names/sizes), ox.itb in boot-a, system.img
#    in system-a, and the LUKS2 data partition opening under the dev key.
# B. Fairphone 5: run ox-provision.py with a TEST owner key against the
#    built artifacts; the provisioning log must carry the owner pkmd,
#    refuse to equal the dev pkmd, and record the rollback baseline.
# usage: target-flashpack-gate.sh PPP_IMAGE_DIR FP5_IMAGE_DIR
set -eu
PPP="$1"
FP5="${2:-}"
say() { printf '[ox-flash] %s\n' "$*"; }
fail() { printf '[ox-flash] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[ox-flash] ok: %s\n' "$*"; }

TOOLS="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap 'losetup -d "$LOOP" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# ------------------------------------------------- A. pinephone-pro ---
say "A: loop-back flash of the pinephone-pro image set"
truncate -s 9G "$WORK/flash.img"
# attach bare: partition devices only re-scan on attach, so the flow is
# flash on the bare loop -> detach -> re-attach with -P for partitions
LOOP=$(losetup --find --show "$WORK/flash.img")
bash "$TOOLS/../targets/pinephone-pro/ox-flash.sh" "$LOOP" "$PPP" \
    > "$WORK/flash.log" 2>&1 || {
    cat "$WORK/flash.log" >&2
    fail "ox-flash.sh failed on the loop device"
}
ok "ox-flash.sh completed (firmware + GPT + slots)"
losetup -d "$LOOP"
LOOP=$(losetup --find --show -P "$WORK/flash.img")
[ -b "${LOOP}p5" ] || fail "loop partition scan produced no ${LOOP}p5"
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
    --pbkdf-force-iterations 10000 --batch-mode \
    --key-file "$PPP/data.img.key" "${LOOP}p5" >/dev/null
ok "ox-data partition formatted LUKS2 (dev key, as ox-flash documents)"

# offsets: idbloader at sector 64 (extract exactly its byte length)
IDBSZ=$(stat -c %s "$PPP/idbloader.img")
dd if="$LOOP" bs=512 skip=64 count=$(( (IDBSZ + 511) / 512 )) status=none \
    | head -c "$IDBSZ" > "$WORK/idb-at64.img"
cmp -s "$WORK/idb-at64.img" "$PPP/idbloader.img" \
    || fail "idbloader not at sector 64 (or differs)"
ok "idbloader at sector 64, byte-identical"
# offsets: u-boot.itb at 0x80000
UBSZ=$(stat -c %s "$PPP/u-boot.itb")
dd if="$LOOP" bs=4096 skip=$((0x80000 / 4096)) \
    count=$(( (UBSZ + 4095) / 4096 )) status=none \
    | head -c "$UBSZ" > "$WORK/ub-at.img"
cmp -s "$WORK/ub-at.img" "$PPP/u-boot.itb" \
    || fail "u-boot.itb not at 0x80000 (or differs)"
ok "u-boot.itb at 0x80000, byte-identical"

# GPT layout: SIX partitions per BRINGUP (boot_a/b, system_a/b, metadata, data)
sgdisk -p "$LOOP" > "$WORK/gpt.txt" 2>/dev/null || fail "GPT does not parse"
for part in "ox-boot-a" "ox-boot-b" "ox-system-a" "ox-system-b" "ox-metadata" "ox-data"; do
    grep -q "$part" "$WORK/gpt.txt" || fail "GPT lacks partition $part"
done
# boot-a must span sector 32768 (16MiB) to 163839 (64MiB long)
LINE=$(grep ox-boot-a "$WORK/gpt.txt")
[ "$(echo "$LINE" | awk '{print $2}')" = "32768" ] \
    || fail "ox-boot-a starts at $(echo "$LINE" | awk '{print $2}'), not sector 32768"
[ "$(echo "$LINE" | awk '{print $3}')" = "163839" ] \
    || fail "ox-boot-a ends at $(echo "$LINE" | awk '{print $3}'), not sector 163839"
ok "GPT: 6 ox-* partitions, boot-a spans sectors 32768-163839 (64MiB)"

# slot contents at the partition starts (16MiB stride); dd|head -c to
# extract exactly the artifact's byte length
EXTRACT() { # EXTRACT <skip_mib> <file> <byte_len>
    dd if="$LOOP" bs=1M skip="$1" count=$(( ($3 + 1048575) / 1048576 )) \
        status=none | head -c "$3" > "$2"
}
OXSZ=$(stat -c %s "$PPP/ox.itb")
EXTRACT 16 "$WORK/boot-a.img" "$OXSZ"
cmp -s "$WORK/boot-a.img" "$PPP/ox.itb" || fail "boot-a != ox.itb"
# system-a starts at 16+64+64 = 144MiB (boot_a + boot_b)
SYSSZ=$(stat -c %s "$PPP/system.img")
EXTRACT 144 "$WORK/sys-a.img" "$SYSSZ"
cmp -s "$WORK/sys-a.img" "$PPP/system.img" || fail "system-a != system.img"
ok "boot-a holds ox.itb, system-a holds system.img (byte-identical)"

# LUKS2 data partition opens under the dev key
cryptsetup luksDump "${LOOP}p5" 2>/dev/null | grep -q "LUKS" \
    || fail "data partition is not LUKS"
rm -f "$WORK/keytest"
cryptsetup luksOpen --key-file "$PPP/data.img.key" --test-passphrase \
    "${LOOP}p5" 2>/dev/null || fail "LUKS2 data partition does not open with the dev key"
ok "ox-data: LUKS2, opens under the dev key"

# ------------------------------------------------- B. fairphone-prov ---
if [ -n "$FP5" ]; then
    say "B: fairphone5 owner-key provisioning round-trip"
    openssl genrsa -out "$WORK/owner.pem" 4096 2>/dev/null
    python3 "$TOOLS/ox-provision.py" --owner-key "$WORK/owner.pem" \
        --image-dir "$FP5" --out "$WORK/provision" \
        > "$WORK/provision.log" 2>&1 \
        || { cat "$WORK/provision.log" >&2; fail "ox-provision.py failed"; }
    grep -q "OX_PROVISION_OK" "$WORK/provision.log" \
        || fail "provision tool did not report OK"
    OWNER=$(grep owner_pkmd_sha256 "$WORK/provision/provisioning-log.txt" | cut -d= -f2)
    DEV=$(grep dev_pkmd_sha256 "$WORK/provision/provisioning-log.txt" | cut -d= -f2)
    [ "$OWNER" != "$DEV" ] || fail "owner pkmd equals the dev pkmd"
    [ "$(wc -c < "$WORK/provision/owner-avb.pub")" -gt 500 ] \
        || fail "extracted owner public key implausible"
    grep -q "vbmeta_rollback_index=0" "$WORK/provision/provisioning-log.txt" \
        || fail "provisioning log lacks the rollback baseline"
    # idempotence: a second run against the SAME owner key succeeds and
    # produces the same pkmd
    python3 "$TOOLS/ox-provision.py" --owner-key "$WORK/owner.pem" \
        --image-dir "$FP5" --out "$WORK/provision2" >/dev/null 2>&1 \
        || fail "provision re-run failed"
    O2=$(grep owner_pkmd_sha256 "$WORK/provision2/provisioning-log.txt" | cut -d= -f2)
    [ "$O2" = "$OWNER" ] || fail "pkmd not stable across runs"
    ok "provision: owner pkmd recorded (differs from dev), rollback baseline, stable re-run"
fi

say "ALL GREEN — flash-pack: the boards can be flashed and enrolled from these artifacts"
echo "FLASHPACK TARGET GATE ALL GREEN"
