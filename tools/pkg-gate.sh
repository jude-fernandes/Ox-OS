#!/bin/sh
# Package gate: the .oxp packaging path, end to end. At boot the
# pkg-selftest service installs the staged hello.oxp through oxpkg ->
# intentd (which validates the manifest and copies it into
# /data/ox/apps), requires a broken package to be REFUSED, starts the
# installed app by manifest resolution (not a built-in), and requires
# the full lifecycle: intent-start -> hello-ready -> hello-exit ->
# intent-exit app=Hello.
# usage: pkg-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-900}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/ox-pkggate
LOG="$OUT/serial-pkg.log"
PPM="$OUT/pkg-screendump.ppm"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-pkg] %s\n' "$*"; }
fail() { printf '[ox-pkg] FAIL: %s\n' "$*" >&2; exit 1; }

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

(OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

# wait_milestone GREP MAX_POLLS LABEL — bounded wait for a log line
wait_ms() {
    _pat="$1"; _max="$2"; _label="$3"
    k=0
    while [ $k -lt "$_max" ]; do
        grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
        if [ $((k % 10)) -eq 5 ]; then
            # PM wake assist: nudge the machine like a power button —
            # the RTC alarm can miss under host load (guest clock lag
            # arms the wakealarm in the past); no-op while awake.
            python3 - <<'PYW' 2>/dev/null || true
import socket
try:
    s = socket.socket(socket.AF_UNIX)
    s.connect("/tmp/ox-qmon")
    s.settimeout(2)
    s.recv(4096)
    s.sendall(b"system_wakeup\n")
except Exception:
    pass
PYW
        fi
        sleep 2; k=$((k + 1))
    done
    fail "$_label (pattern not observed: $_pat)"
}

# 1. boot basics
wait_ms "name=shell-home" 150 "no shell-home milestone (shell did not draw)"
grep -aq "name=intentd-ready" "$LOG" || fail "no intentd-ready milestone"
say "shell up, intentd supervised"

# 2. packaging flow: install ok (signature verified), broken refused,
#    evil (valid shape, mismatched signature) refused, list shows it
wait_ms "name=intent-sig-ok app=Hello" 120 "hello.oxp signature was not verified (no intent-sig-ok)"
say "hello.oxp signature verified against the pinned package key"
wait_ms "name=intent-install app=Hello" 120 "hello.oxp was not installed (no intent-install)"
say "hello.oxp installed into /data/ox/apps"
wait_ms "intent-refused src=/usr/share/ox/packages/broken.oxp" 120 "broken package was NOT refused"
say "broken package refused by manifest validation:"
grep -a "intent-refused src=/usr/share/ox/packages/broken.oxp" "$LOG" | tail -1 | sed 's/^/[ox-pkg]   /'
wait_ms "intent-refused src=/usr/share/ox/packages/evil.oxp reason=bad-signature" 120 "evil package was NOT refused by signature"
say "evil package refused by signature verification:"
grep -a "intent-refused src=/usr/share/ox/packages/evil.oxp" "$LOG" | tail -1 | sed 's/^/[ox-pkg]   /'
wait_ms "name=install-refused-reserved bin=ox-settings" 120 "the impersonating package was NOT refused by reserved bin"
say "impersonation package (valid signature, bin=ox-settings) refused: reserved system identity"
wait_ms "name=perm-bound app=Hello" 120 "manifest permissions were not bound into permstored"
say "manifest permissions bound into permstored (default deny)"
wait_ms "name=pkg-flow-ok" 30 "pkg-selftest did not pass"
say "pkg-selftest: install ok, broken refused, evil refused, list ok, deny->grant->post ok"

# 3. launch the installed app by manifest resolution
wait_ms "name=intent-start app=Hello pid=" 60 "installed Hello was not started"
wait_ms "name=hello-ready" 60 "hello app did not draw"
say "installed package spawned and drew:"
grep -a -e "name=intent-start app=Hello" -e "name=hello-ready" "$LOG" | tail -2 | sed 's/^/[ox-pkg]   /'

# 4. artifact: screendump (hello's window if within its demo window)
sleep 2
python3 - "$PPM" <<'PYEOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmp")
f = s.makefile("rw")
f.readline()
def send(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    return json.loads(f.readline())
send({"execute": "qmp_capabilities"})
send({"execute": "system_wakeup"})
time.sleep(2.0)
r = send({"execute": "screendump", "arguments": {"filename": sys.argv[1]}})
assert "error" not in r, r
print("[ox-pkg] screendump ok")
PYEOF

# 5. the app must exit and be reaped
wait_ms "name=hello-exit" 60 "hello app did not exit after its demo window"
wait_ms "intent-exit app=Hello" 60 "intentd did not reap the installed app"
say "installed app exited and was reaped"

grep -aq "name=pkg-flow-failed" "$LOG" && fail "pkg-selftest reported failure"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — .oxp packaging: install, refuse-broken, list, manifest-spawn, exit, reap"
echo "PKG GATE ALL GREEN"
