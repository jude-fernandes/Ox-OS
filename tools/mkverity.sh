#!/bin/sh
# Generate dm-verity hash tree (no superblock) for a system image.
# usage: mkverity.sh DATA.img OUT.hash.img OUT.digest.env
set -eu

[ $# -eq 3 ] || { echo "usage: $0 DATA.img OUT.hash.img OUT.digest.env" >&2; exit 2; }
DATA="$1"; HASH="$2"; ENVOUT="$3"

command -v veritysetup >/dev/null 2>&1 || {
    echo "ERROR: veritysetup not found (apt install cryptsetup-bin)" >&2; exit 3; }

SALT="$(sha256sum "$DATA" | cut -d' ' -f1)"
rm -f "$HASH"
FORMAT_OUT="$(veritysetup format --no-superblock --salt="$SALT" "$DATA" "$HASH")"
ROOT_HASH="$(printf '%s\n' "$FORMAT_OUT" | sed -n 's/^Root hash:\s*//p')"
[ -n "$ROOT_HASH" ] || { echo "ERROR: no root hash in veritysetup output" >&2; exit 4; }

DATA_BYTES=$(wc -c <"$DATA")
DATA_BLOCKS=$(( DATA_BYTES / 4096 ))
[ $(( DATA_BYTES % 4096 )) -eq 0 ] || {
    echo "ERROR: data image not 4096-aligned ($DATA_BYTES bytes)" >&2; exit 5; }
[ "$DATA_BLOCKS" -ge 32 ] || {
    echo "ERROR: suspiciously small system image ($DATA_BYTES bytes); refusing to hash" >&2
    exit 6; }
DATA_SECTORS=$(( DATA_BYTES / 512 ))

{
    echo "OX_ROOT_HASH=$ROOT_HASH"
    echo "OX_SALT=$SALT"
    echo "OX_DATA_BLOCKS=$DATA_BLOCKS"
    echo "OX_DATA_SECTORS=$DATA_SECTORS"
} >"$ENVOUT"

echo "OXMILESTONE name=verity-built tms=0 blocks=$DATA_BLOCKS roothash=$ROOT_HASH"
