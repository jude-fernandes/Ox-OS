#!/bin/sh
# Interactive serial-console probe (v4): the piped stdin subshell polls
# the serial LOG for prompts/marker echoes before typing each next line.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"

if ! grep -q 'ox-payload-qemu' /tmp/nixout.txt 2>/dev/null; then
    "$NIX" build .#payload-qemu .#kernel-qemu --no-link --print-out-paths \
        2>/dev/null > /tmp/nixout.txt
fi
P="$(sed -n 1p /tmp/nixout.txt)"
K="$(sed -n 2p /tmp/nixout.txt)/Image"
[ -d "$P" ] || { echo "bad payload path: $P"; exit 1; }
rm -rf /tmp/ox-pwc-payload && mkdir -p /tmp/ox-pwc-payload
cp -r "$P"/. /tmp/ox-pwc-payload/
OUT=/tmp/ox-pwc
LOG="$OUT/serial.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon
pkill -f qemu-system-aarch64 2>/dev/null || true
sleep 1

# poll_log PATTERN [TIMEOUT_S]: wait until the serial log contains it
poll_log() {
    pat="$1"; t="${2:-30}"; i=0
    while [ $i -lt "$t" ]; do
        grep -aq "$pat" "$LOG" 2>/dev/null && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

{
    poll_log 'login:' 150 && printf 'root\n'
    if poll_log 'Password:' 15; then
        printf '\n'            # empty password from root::0:0 passwd entry
    fi
    printf 'echo MARKER-SHELL\n'
    poll_log 'MARKER-SHELL' 20 || {
        printf 'root\n'
        if poll_log 'Password:' 15; then printf '\n'; fi
        sleep 2
        printf 'echo MARKER-SHELL\n'
        poll_log 'MARKER-SHELL' 20 || true
    }
    printf 'pw-debug-probe\n'
    poll_log 'DBG-END' 90 || true
    sleep 2
    printf 'echo MARKER-EXIT\n'
    sleep 3
} | OX_GFX=1 OX_VERBOSE=1 \
    OX_QEMU_EXTRA="-audiodev driver=wav,id=oxwav,path=$OUT/dump.wav -device virtio-sound-pci,audiodev=oxwav" \
    timeout 200 bash targets/qemu-virt-aarch64/run-qemu.sh \
    /tmp/ox-pwc-payload "$K" "$LOG" > /dev/null 2>&1 || true

echo "== probe markers =="
grep -a 'MARKER-\|DBG-BEGIN\|DBG-END\|DBG-PLAY-RC' "$LOG" | head -10
echo "== node state (ox-speaker) =="
grep -a -A26 'DBG-NODES' "$LOG" | grep -a 'id \|node.name\|state\|media.class' | head -14
echo "== ports =="
grep -a -A34 'DBG-PORTS' "$LOG" | head -38
echo "== play rc + debug log =="
grep -a 'DBG-PLAY-RC' "$LOG" | head -2
grep -a -A80 'DBG-PLAY-LOG' "$LOG" | grep -a 'stream\|state\|error\|failed\|Link\|param\|format' | head -34
