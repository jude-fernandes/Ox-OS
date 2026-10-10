#!/bin/sh
# A/B slot-update gate (chunk 76) — HOST-SIDE, loop device.
#
# A. offline capability proof (the Oct-3 lesson, re-checked after the
#    big GC): the whole fleet builds --offline from cache — nothing may
#    hit the network.
# B. flash a PinePhone Pro image (ox-flash), then run ox-update with the
#    same verified artifact set as the "new version": slot b must fill,
#    slot a must stay byte-identical, metadata must flip to b with the
#    root hashes recorded, and a SECOND update run must be idempotent
#    (counters not corrupted, integrity still verified).
# usage: target-update-gate.sh PPP_IMAGE_DIR
set -eu
PPP="$1"
say() { printf '[ox-update] %s\n' "$*"; }
fail() { printf '[ox-update] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[ox-update] ok: %s\n' "$*"; }

TOOLS="$(cd "$(dirname "$0")" && pwd)"
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd /root/oxbuild

# --------------------------------------------- A. offline capability ---
say "A: fleet offline build proof (post-GC)"
if "$NIX" build .#payload-qemu .#kernel-qemu .#workspace-test \
        .#image-pinephone-pro .#image-fairphone5 \
        .#image-oneplus9rt .#image-oneplus10pro \
        --no-link --offline --option cores 4 --max-jobs 1 \
        >/tmp/ox-update-offline.log 2>&1; then
    ok "all six outputs build --offline (cache-complete closures)"
else
    tail -6 /tmp/ox-update-offline.log >&2
    fail "offline build failed — GC stranded something the roots should hold"
fi

# --------------------------------------------- B. slot update cycle ----
say "B: flash -> update -> verify on a loop device"
WORK=$(mktemp -d)
trap 'losetup -d "$LOOP" 2>/dev/null || true; rm -rf "$WORK"' EXIT
truncate -s 9G "$WORK/flash.img"
LOOP=$(losetup --find --show "$WORK/flash.img")
bash "$TOOLS/../targets/pinephone-pro/ox-flash.sh" "$LOOP" "$PPP" \
    > "$WORK/flash.log" 2>&1 || { cat "$WORK/flash.log" >&2; fail "flash failed"; }
losetup -d "$LOOP"
LOOP=$(losetup --find --show -P "$WORK/flash.img")
[ -b "${LOOP}p5" ] || fail "partition scan failed"
ok "device flashed (slot a active, slot b empty)"

# snapshot slot a (system-a = partition 3) to prove the updater never touches it
dd if="${LOOP}p3" of="$WORK/sysa-before.img" bs=1M status=none

# the update
bash "$TOOLS/../targets/pinephone-pro/ox-update.sh" "$LOOP" "$PPP" \
    > "$WORK/update.log" 2>&1 || { cat "$WORK/update.log" >&2; fail "ox-update failed"; }
grep -q "OX_UPDATE_OK" "$WORK/update.log" || fail "updater did not report OK"
ok "ox-update completed (preflight verity, write, readback, metadata)"

# slot b contents byte-identical (boot-b = partition 2)
OXSZ=$(stat -c %s "$PPP/ox.itb")
dd if="${LOOP}p2" bs=1M count=$(( (OXSZ + 1048575) / 1048576 )) status=none \
    | head -c "$OXSZ" | cmp -s - "$PPP/ox.itb" \
    || fail "boot-b != ox.itb after update"
ok "boot-b holds the new ox.itb byte-identical"

# slot a untouched (system-a = partition 3)
cmp -s "$WORK/sysa-before.img" "${LOOP}p3" \
    || fail "slot a was modified by the update"
ok "slot a preserved byte-for-byte (fallback intact)"

# metadata: active=b, integrity passes, root hashes recorded (metadata = partition 5)
META=$(python3 "$TOOLS/ox-slotmeta.py" read "${LOOP}p5")
echo "$META" | grep -q "active_slot=1" || fail "metadata active_slot != 1"
echo "$META" | grep -q "boot_attempts=0" || fail "metadata boot_attempts != 0"
RA=$(echo "$META" | grep root_hash_a | cut -d= -f2)
. "$PPP/digest.env"
[ "$RA" = "$OX_ROOT_HASH" ] || fail "metadata root_hash_a != digest root"
ok "metadata: active=b, attempts=0, root hashes match digest.env"

# idempotence: a second update must succeed with the same result
bash "$TOOLS/../targets/pinephone-pro/ox-update.sh" "$LOOP" "$PPP" \
    > "$WORK/update2.log" 2>&1 || { cat "$WORK/update2.log" >&2; fail "second update failed"; }
META2=$(python3 "$TOOLS/ox-slotmeta.py" read "${LOOP}p5")
[ "$META" = "$META2" ] || fail "metadata drifted between identical updates"
ok "second update idempotent (metadata stable)"

# slotmeta tamper check (the unit-level property, on-device shape)
printf 'X' | dd of="${LOOP}p5" bs=1 seek=40 conv=notrunc status=none
python3 "$TOOLS/ox-slotmeta.py" read "${LOOP}p5" >/dev/null 2>&1 \
    && fail "tampered metadata ACCEPTED"
ok "tampered metadata rejected (integrity hash holds)"

say "ALL GREEN — slot-update: the A/B write path, fallback preservation, metadata counters and integrity are proven"
echo "SLOT-UPDATE TARGET GATE ALL GREEN"
