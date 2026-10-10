#!/bin/sh
# Wi-Fi gate (Phase 4): the REAL wireless stack on virtual radios.
# mac80211_hwsim gives the guest two radios (wlan0 client, wlan1 AP);
# hostapd runs a WPA2-PSK AP on wlan1 and wpa_supplicant associates on
# wlan0 — real 802.11 userspace and kernel mac80211, virtual radio.
# The gate requires, on-device: both interfaces, WPA2 association
# (wpa_state=COMPLETED), an ICMP ping ACROSS the authenticated link
# (10.10.0.2 -> 10.10.0.1), oxwifid scan listing the AP (granted
# wifi.scan), and the Settings Wi-Fi panel rendering live results.
# usage: wifi-gate.sh PAYLOAD_DIR KERNEL [TIMEOUT_S]
set -eu
PAYLOAD="$1"; KERNEL="$2"; TMO="${3:-3600}"
OXDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$OXDIR/tools/gate-lib.sh"   # chunk-54 guest-time waits
OUT=/tmp/ox-wfg
LOG="$OUT/serial-wifi.log"
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f /tmp/ox-qmp /tmp/ox-qmon

say() { printf '[ox-wf] %s\n' "$*"; }
fail() { printf '[ox-wf] FAIL: %s\n' "$*" >&2; exit 1; }

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1

(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=1 timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

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


tap_until() {
    _sx="$1"; _sy="$2"; _pat="$3"; _rounds="$4"; _pollrounds="$5"; _label="$6"
    attempt=0
    while [ $attempt -lt "$_rounds" ]; do
        qmp_tap "$_sx" "$_sy"
        k=0
        while [ $k -lt "$_pollrounds" ]; do
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
        attempt=$((attempt + 1))
        say "$_label not observed (retry $((attempt + 1)))"
    done
    fail "$_label"
}

qmp_tap() {
    python3 - "$1" "$2" <<'PYEOF'
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
def ev(events):
    r = send({"execute": "input-send-event", "arguments": {"events": events}})
    assert "error" not in r, r
    time.sleep(0.15)
sx, sy = float(sys.argv[1]), float(sys.argv[2])
move1 = [{"type": "abs", "data": {"axis": "x", "value": int(sx * 32767 / 1280)}},
         {"type": "abs", "data": {"axis": "y", "value": int(sy * 32767 / 800)}}]
ev(move1)
time.sleep(0.4)
ev(move1)
ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
print("[ox-wf] tap injected at %s,%s" % (sys.argv[1], sys.argv[2]))
PYEOF
}

qmp_pin() {
    python3 - "$1" "$2" <<'PYEOF'
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
def ev(events):
    r = send({"execute": "input-send-event", "arguments": {"events": events}})
    assert "error" not in r, r
    time.sleep(0.15)
def tap(sx, sy):
    move1 = [{"type": "abs", "data": {"axis": "x", "value": int(sx * 32767 / 1280)}},
             {"type": "abs", "data": {"axis": "y", "value": int(sy * 32767 / 800)}}]
    ev(move1)
    time.sleep(0.4)
    ev(move1)
    ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
    ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "OK"]
rects = [(353 + (i % 3) * 102, 420 + (i // 3) * 68, 90, 56) for i in range(12)]
def unlocked():
    try:
        with open(sys.argv[2], "rb") as f:
            return f.read().count(b"name=shell-unlocked")
    except Exception:
        return 0
for ch in sys.argv[1]:
    if unlocked() > 0:
        print("[ox-wf] unlock already observed - aborting remaining PIN taps")
        sys.exit(0)
    i = keys.index(ch)
    x, y, w, h = rects[i]
    tap(x + w / 2, y + h / 2)
    time.sleep(1.0)
if unlocked() > 0:
    print("[ox-wf] unlock already observed - skipping OK tap")
    sys.exit(0)
i = keys.index("OK")
x, y, w, h = rects[i]
tap(x + w / 2, y + h / 2)
print("[ox-wf] PIN digits + OK injected")
PYEOF
}

# 1. the stack came up: hwsim radios, hostapd AP, wpa_supplicant client
wait_ms "mac80211_hwsim" 60 "hwsim never probed (kernel lacks the radio)"
say "hwsim radios present"

# 2. the selftest's on-device assertions — the honest join flow:
#    no factory credentials, then deny/fake/grant with the radio
#    staying clean until the grant
wait_ms "name=wifi-iface-ok" 300 "wlan0/wlan1 did not appear"
say "interfaces: wlan0 (client) + wlan1 (AP)"
wait_ms "name=wifi-no-factory-join" 60 "boot joined a network without permission (factory credential?)"
say "no factory join: client idle at boot"
wait_ms "name=wifi-join-denied-ok" 60 "connect was not refused under wifi.join deny"
say "join refused under the bound deny"
wait_ms "name=wifi-join-fake-ok" 60 "fake join did not answer synthetic"
wait_ms "name=wifi-join-fake-radio-clean" 60 "fake join touched the radio (PSK leak)"
say "fake join: synthetic answer, radio never saw the PSK"
# The selftest owns the association verdict: it polls 120s, then dumps
# radio diagnostics and nudges (wpa_cli reassociate = the user's retry
# tap), and journals EITHER wifi-associated OR wifi-failed
# reason=no-association. The gate reads the verdict with a generous
# budget (host clock runs ~3x guest under load).
k=0
while [ $k -lt 700 ]; do
    grep -aq "name=wifi-associated ssid=ox-virt-ap" "$LOG" 2>/dev/null && break
    grep -aq "name=wifi-failed reason=no-association" "$LOG" 2>/dev/null && break
    sleep 2; k=$((k + 1))
done
grep -aq "name=wifi-associated ssid=ox-virt-ap" "$LOG" 2>/dev/null     || fail "association never completed (selftest dumped diagnostics: DBG-WIFI-FAILSTATE)"
say "association: WPA2-PSK COMPLETED with ox-virt-ap (granted join)"
wait_ms "name=wifi-join-grant-ok" 60 "grant-leg join never completed"
wait_ms "name=wifi-ping-ok" 60 "ICMP did not cross the authenticated link"
wait_ms "name=wifi-stack-ok" 10 "stack did not complete"
say "ICMP crossed the authenticated link (10.10.0.2 -> 10.10.0.1)"
wait_ms "name=wifi-credentials-stored ssid=ox-virt-ap" 60 "granted join did not persist its credential"
say "granted join persisted its credential to the store"

# 2b. PIN unlock (needed for the Settings panel leg later; the panel
#     is unreachable while the lock screen is up)
attempt=0
UNLOCKED=no
while [ $attempt -lt 3 ]; do
    N0=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
    qmp_pin 1234 "$LOG"
    k=0
    while [ $k -lt 300 ]; do
        N1=$(grep -ac "name=shell-unlocked" "$LOG" 2>/dev/null || true)
        [ "$N1" -gt "$N0" ] 2>/dev/null && break
        sleep 2; k=$((k + 1))
    done
    grep -aq "name=shell-unlocked" "$LOG" 2>/dev/null && { UNLOCKED=yes; break; }
    attempt=$((attempt + 1))
    say "unlock not observed yet (retry $((attempt + 1)))"
done
[ "$UNLOCKED" = yes ] || fail "no shell-unlocked milestone"
say "unlocked"

# post-unlock hygiene (see tiles-gate): drain lagging PIN-pad clicks,
# then tap the app Close button twice - inert on the bare home screen,
# closes any stray app window launched by a lagging tap.
sleep 30
qmp_tap 877 662
sleep 6
qmp_tap 877 662
sleep 3

# 3. oxwifid: the selftest grants Settings wifi.scan and scans through
#    the daemon — the AP must appear in the served results
wait_ms "name=wifi-scan-found" 60 "oxwifid scan did not include ox-virt-ap"
say "oxwifid scan (granted wifi.scan) lists ox-virt-ap"

# 4. the Settings Wi-Fi panel: launch Settings, tap Wi-Fi, require the
#    panel journal with at least one network (button center on screen:
#    window (570+75, 538+24) + window origin (190,80) = (835,642)).
#    Chunk 68: aim 12px HIGHER — (835,642) sits in the shell footer's
#    band (y>=640), and when the footer is raised above the Settings
#    window the click hits the footer (the uninstall pixel-boundary
#    lesson). y=630 is inside the button (window y 550 of [538,586))
#    and above the footer strip.
sleep 3
# pollrounds 30 (~60s/attempt): click DELIVERY lag under TCG can
# exceed 40s — the tap lands, the milestone just arrives late
tap_until_guest 158 195 "name=settings-ready" 720000 300 "Settings did not launch"
tap_until_guest 835 630 "name=wifi-panel-shown networks=" 180000 300 "Wi-Fi panel did not open"
say "Settings Wi-Fi panel opened with live scan results"
grep -a "name=wifi-panel-shown" "$LOG" | tail -1 | sed 's/^/[ox-wf]   /'

# 5. close Settings
tap_until_guest 967 712 "name=settings-close" 360000 1800 "Settings did not close"

# ---- PHASE 2: persistence across reboot. Reboot the SAME data
# volume (data.img kept): the remembered network must autojoin on the
# cold boot — the driver replaying stored consent — BEFORE the
# selftest's own join legs run, and the forget leg must empty the
# store at the end.
say "PHASE 2: rebooting the same data volume for the persistence proof"
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 2
LOG="$OUT/serial-wifi2.log"
(OX_KERNEL_EXTRA=" ox.pm_drill=off" OX_GFX=0 OX_VERBOSE=1 \
    timeout "$TMO" bash "$OXDIR/targets/qemu-virt-aarch64/run-qemu.sh" \
    "$PAYLOAD" "$KERNEL" "$LOG" >/dev/null 2>&1 &)

wait_ms "name=pm-drill-skipped\|name=pm-resumed" 200 "powerd PM selftest never resumed (boot 2)"
# NO UI waits here: boot 2 is headless (OX_GFX=0 — the compositor has
# no display and the shell exits by design). Every phase-2 assertion
# is daemon/selftest-level (autojoin, matrix re-walk, forget); the
# shell-locked wait that stood here briefly made this phase
# unpassable.

# keep the guest wakeable through idle suspends: a 15s system_wakeup
# is a no-op while awake and plays the power button while suspended
(while :; do
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
    sleep 15
done) 2>/dev/null &
wait_guest "name=wifi-autojoined ssid=ox-virt-ap" 2700000 300 "remembered network never autojoined on the cold boot"
say "autojoined the remembered network on a cold boot (consent replay)"
wait_guest "DBG-WIFI-JOIN-DENY" 720000 1800 "boot-2 selftest never started its walk"
A=$(grep -an 'name=wifi-autojoined' "$LOG" | head -1 | cut -d: -f1)
B=$(grep -an 'DBG-WIFI-JOIN-DENY' "$LOG" | head -1 | cut -d: -f1)
if [ -n "$A" ] && [ -n "$B" ] && [ "$A" -lt "$B" ]; then
    say "ordering proven: autojoin (line $A) preceded the selftest walk (line $B)"
else
    fail "autojoin did not precede the selftest's own join legs (evidence inconclusive)"
fi
# 480s: the matrix re-walk includes another grant association (the
# flaky leg) plus the selftest's 120s poll + diagnostic dump before
# forget
wait_ms "name=wifi-forget-ok" 480 "forget leg never emptied the store"
say "forget: the credential left the store (least privilege)"
say "boot-2 matrix re-walked on the remembered boot"

pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1
say "ALL GREEN — Wi-Fi stack: real cfg80211/mac80211 + wpa_supplicant + hostapd, WPA2 association, authenticated-link ping, oxwifid + Settings panel; credentials persist and autojoin across reboot, forget works"
echo "WIFI GATE ALL GREEN"
