#!/bin/sh
# Host-side verification of the data/hash pair against the recorded root hash.
# usage: verify-host.sh PAYLOAD_DIR
set -eu
P="$1"
cd "$P"
. "$P/digest.env"
echo "roothash=$OX_ROOT_HASH salt=$OX_SALT blocks=$OX_DATA_BLOCKS"
veritysetup verify --no-superblock --salt="$OX_SALT" \
    system.img system.hash.img "$OX_ROOT_HASH"
echo HOST_VERIFY_OK
