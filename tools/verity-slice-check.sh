#!/bin/sh
# decisive round 4: control passes with --salt. Add --salt to the slice
# verify (the earlier slice run omitted the salt!).
set -eu
IMG=/tmp/ox-slotboot-debug/flash.img
PPP=$(ls -dt /nix/store/*image-pinephone-pro-0.1.0-chunk72 2>/dev/null | grep -v drv | head -1)
. "$PPP/digest.env"
rm -f /tmp/vs-data /tmp/vs-hash
dd if="$IMG" of=/tmp/vs-data bs=1M skip=144 count=257 status=none
dd if="$IMG" of=/tmp/vs-hash bs=1M skip=3088 count=1 status=none
echo "== slice verify with --salt:"
veritysetup verify --no-superblock --salt="$OX_SALT" \
    /tmp/vs-data /tmp/vs-hash "$OX_ROOT_HASH" && echo SLICE_OK
