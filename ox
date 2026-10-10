#!/bin/sh
# ox — Ox OS build/control CLI (Phase 1 scope)
set -eu
TOOLSDIR="$(cd "$(dirname "$0")/tools" && pwd)"
TARGETS="$(cd "$(dirname "$0")/targets" && pwd)"

usage() {
    cat <<EOF
usage: ox <command> [args]

  selftest                 run tool self-tests (keytool roundtrip)
  payload TARGET ROOTFS KERNEL OUTDIR [KEY]
                           build signed boot payload
  boottime LOG [--max-total S] [--budget name=S ...]
                           parse boot milestone log
  qemu PAYLOADDIR KERNEL [LOG]
                           launch virtual target (needs QEMU host)
  help                     show this text
EOF
}

cmd="${1:-help}"; shift || true

case "$cmd" in
selftest)
    python3 "$TOOLSDIR/ox-keytool.py" selftest
    ;;
payload)
    exec bash "$TOOLSDIR/build-payload.sh" "$@"
    ;;
boottime)
    exec python3 "$TOOLSDIR/boottime-parse.py" "$@"
    ;;
qemu)
    exec bash "$TARGETS/qemu-virt-aarch64/run-qemu.sh" "$@"
    ;;
help|--help|-h)
    usage
    ;;
*)
    echo "unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
