#!/bin/sh
# Ox gate library — guest-time primitives (chunk 54).
#
# PROBLEM: gate waits are HOST wall-clock, but guest speed varies ~10x
# between boots (TCG load, drop_caches drills, host sleep). A fixed
# 120s host budget samples a distribution it sometimes loses — the
# "moving lottery" of sweep failures (2026-09-18-phase4-close.md).
#
# FIX: measure deadlines in GUEST time. The kernel prints its clock on
# every console line ([ 123.456789] ...); wait_guest / tap_until_guest
# fail only when the GUEST's own clock has advanced past the budget.
# A stalled guest extends its own deadline; the host cap is a backstop
# for a genuinely dead guest (no serial output at all for cap seconds).
#
# Requires from the including gate: LOG (serial log path), qmp_tap,
# say, fail — resolved at call time in the gate's scope.

# Print the LAST kernel timestamp in the log, in milliseconds.
guest_ts() {
    [ -f "$LOG" ] || return 0
    grep -a -o '\[[ ]*[0-9][0-9]*\.[0-9][0-9]*\]' "$LOG" 2>/dev/null \
        | tail -1 | tr -d '[] ' | awk -F. '{ printf "%d", $1 * 1000 + substr($2, 1, 3) }'
}

# Wake the guest through an idle suspend (no-op while awake).
_wake() {
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
}

# wait_guest PATTERN GUEST_MS HOST_CAP_S LABEL
# Pass as soon as PATTERN appears in $LOG. Fail when the guest clock
# has advanced GUEST_MS past the wait's start, or when the serial log
# has produced no new bytes for HOST_CAP_S seconds (guest presumed
# dead), whichever comes first.
wait_guest() {
    _pat="$1"; _gms="$2"; _cap="$3"; _label="$4"
    _start=$(guest_ts); [ -n "$_start" ] || _start=0
    _lastsize=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    _lastchange=$(date +%s)
    k=0
    while :; do
        grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
        _now=$(guest_ts); [ -n "$_now" ] || _now=0
        [ $((_now - _start)) -ge "$_gms" ] && break
        _sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
        if [ "$_sz" != "$_lastsize" ]; then
            _lastsize=$_sz; _lastchange=$(date +%s)
        else
            [ $(( $(date +%s) - _lastchange )) -ge "$_cap" ] && break
        fi
        if [ $((k % 15)) -eq 7 ]; then _wake; fi
        sleep 1; k=$((k + 1))
    done
    grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
    fail "$_label (pattern not observed: $_pat)"
}

# tap_until_guest X Y PATTERN GUEST_MS HOST_CAP_S LABEL
# Tap until PATTERN appears, with the same guest-clock deadline as
# wait_guest. Taps repeat every ~6s of guest progress; under a stall
# the loop simply waits the guest out instead of exhausting rounds.
tap_until_guest() {
    _sx="$1"; _sy="$2"; _pat="$3"; _gms="$4"; _cap="$5"; _label="$6"
    _start=$(guest_ts); [ -n "$_start" ] || _start=0
    _lastsize=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    _lastchange=$(date +%s)
    k=0
    while :; do
        grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
        _now=$(guest_ts); [ -n "$_now" ] || _now=0
        [ $((_now - _start)) -ge "$_gms" ] && break
        _sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
        if [ "$_sz" != "$_lastsize" ]; then
            _lastsize=$_sz; _lastchange=$(date +%s)
        else
            [ $(( $(date +%s) - _lastchange )) -ge "$_cap" ] && break
        fi
        if [ $((k % 6)) -eq 0 ]; then
            qmp_tap "$_sx" "$_sy"
        fi
        if [ $((k % 30)) -eq 15 ]; then _wake; fi
        sleep 2; k=$((k + 1))
    done
    grep -aq "$_pat" "$LOG" 2>/dev/null && return 0
    fail "$_label (pattern not observed: $_pat)"
}

# s6_integrity_guard PAYLOAD_DIR (chunk 68): the payload's compiled s6
# runtime must carry EVERY service directory the tree defines. The
# Oct-5 contacts-gate failure was this exact class — a build raced the
# tree and shipped a DB missing oxcom, failing the gate hours later on
# an unrelated pattern. Fail fast at build time, by name.
# NOTE: needs $PAYLOAD set and unsquashfs; callers invoke AFTER build.
s6_integrity_guard() {
    IN_TREE=$(ls "$OXDIR/system/s6-rc-source" | wc -l)
    rm -rf /tmp/sqcheck && unsquashfs -q -d /tmp/sqcheck "$1/system.img" >/dev/null 2>&1
    IN_IMG=$(ls /tmp/sqcheck/etc/s6-rc/source 2>/dev/null | wc -l)
    rm -rf /tmp/sqcheck
    echo "S6 INTEGRITY tree=$IN_TREE image=$IN_IMG"
    [ "$IN_IMG" -ge "$IN_TREE" ] || {
        echo "S6 INTEGRITY FAILED — payload is incomplete (missing service dirs)"
        exit 1
    }
}
