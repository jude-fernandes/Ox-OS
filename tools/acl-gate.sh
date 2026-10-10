#!/bin/sh
# ACL gate (chunk 60): oxcom's per-client op ACLs, both sides of the
# boundary in one boot.
#   SYSTEM side:  the shell registers, engages the shield (window-secure
#                 on=true) — the chunk-59 lock-shield flow must keep
#                 working under the ACL.
#   NORMAL side:  acl-selftest's unprivileged oxctl connections must be
#                 REFUSED on window-secure + foreign window-close, and
#                 ALLOWED on its own window-new.
# Refusals journal OXMILESTONE name=acl-refused (oxcom side) AND
# name=acl-normal-refused (selftest side); the allow path journals
# name=acl-allowed op=window-new.
# usage: acl-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="${2:-/nix/store/qf3508h6zl2yq3vx6j236nq3r8dns4d9-linux-aarch64-unknown-linux-gnu-6.18.48/Image}"; TMO="${3:-1800}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$OXDIR/tools/gate-lib.sh"
OUT=/tmp/ox-aclgate
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-acl] %s\n' "$*"; }
fail() { printf '[ox-acl] FAIL: %s\n' "$*" >&2; exit 1; }

wait_ms() {
    _pat="$1"; _max="$2"; _label="$3"
    k=0
    while [ $k -lt "$_max" ]; do
        grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
        if [ $((k % 10)) -eq 5 ]; then
            python3 - <<'PYW' 2>/dev/null || true
import socket
try:
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmon")
    s.settimeout(2)
    s.recv(4096)
    s.sendall(b"system_wakeup" + chr(10).encode())
except Exception:
    pass
PYW
        fi
        sleep 2; k=$((k + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}

LOG="$OUT/serial-acl.log"
(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)
i=0
while [ $i -lt 150 ]; do
    grep -aq "name=shell-locked" "$LOG" 2>/dev/null && break
    sleep 2; i=$((i + 1))
done
grep -aq "name=lockd-ready" "$LOG" || fail "no lockd-ready milestone"

# SYSTEM side: the shell's role + shield under the ACL
# (all waits are GUEST-clock budgets — wait_guest — the 2026-09-27
# sweep caught host-clock waits expiring before slow-boot events)
wait_guest "name=system-client-registered" 360000 1800 "shell never registered as the system client"
wait_guest "name=shell-system-role ok=true" 360000 1800 "shell did not confirm its system role"
wait_guest "name=lock-shield id=[0-9]* on=true" 360000 1800 "shield never engaged under the ACL"
say "SYSTEM side green: shell registered, shield engaged under the ACL"

# NORMAL side: refusals with journal evidence on BOTH sides of the wire
wait_guest "name=acl-normal-refused op=window-secure" 360000 1800 "shield op was not refused for a normal client"
wait_guest "name=acl-normal-refused op=window-close" 360000 1800 "foreign close was not refused for a normal client"
wait_guest "name=acl-allowed op=window-new" 360000 1800 "normal client's own window-new was wrongly refused"
wait_guest "name=acl-refused op=window-secure" 360000 1800 "oxcom did not journal the refusal"
say "NORMAL side green: shield op + foreign close refused, own window-new allowed"

# INPUT side (chunk 61): a foreign PROCESS cannot await the pad's clicks
wait_guest "name=acl-input-refused op=click-recv" 360000 1800 "foreign click-recv on the pad was not refused"
say "INPUT side green: foreign click-recv on the pad refused (SO_PEERCRED)"

# SANDBOX side (chunk 65): a screen.read grant buys pixels, not an
# arbitrary root-owned file write — outside the artifacts dir refuses,
# a flat artifacts path still lands
wait_guest "name=acl-sandbox-refused op=screendump" 360000 1800 "out-of-sandbox screendump was not refused"
wait_guest "name=acl-refused op=screendump app=oxctl reason=outside-artifacts" 360000 1800 "oxcom did not journal the sandbox refusal"
wait_guest "name=acl-sandbox-allowed op=screendump" 360000 1800 "legal artifacts screendump was wrongly blocked"
say "SANDBOX side green: granted screendump confined to /data/ox/artifacts/, refusal journaled"

# IDENTITY side (chunk 68): a granted app's name in the payload confers
# nothing — the consult identity is the kernel-verified peer comm
wait_guest "name=acl-spoof-refused op=contacts-list" 360000 1800 "payload identity claim was accepted (spoof!)"
say "IDENTITY side green: granted-name spoof refused, consult identity is the peer comm"

# WRITE side (chunk 70): the permission store's writers are system-only
# — a COPY of oxctl under another name is a different identity and is
# refused, while the real oxctl still writes (positive control)
wait_guest "name=acl-write-refused op=perm-set caller=not-oxctl" 360000 1800 "an unprivileged comm wrote the permission store!"
wait_guest "name=perm-acl-refused op=set caller=not-oxctl" 360000 1800 "permstored did not journal the write refusal"
wait_guest "name=acl-write-allowed op=perm-set caller=oxctl" 360000 1800 "the real oxctl's write was wrongly refused"
say "WRITE side green: permstored set is system-only, refusal journaled, positive control intact"

say "ALL GREEN — oxcom mutations are owner/system-scoped; the boundary is journaled"
echo "ACL GATE ALL GREEN"
