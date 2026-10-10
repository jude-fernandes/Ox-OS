#!/usr/bin/env python3
"""Fix wake-lock acquire (request was never sent) + gate key-press retries."""

def patch(path, subs):
    with open(path, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    text = text.replace("\r\n", "\n")
    for old, new in subs:
        n = text.count(old)
        assert n == 1, f"{path}: anchor found {n}x (expected 1):\n{old[:80]}"
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print(f"patched {path} ({len(subs)} edits)")

patch("rust/crates/oxpaymentsd/src/main.rs", [
    ('''    let pwr = connect_retry(&sock);
    if pwr.is_none() {
        eprintln!("paymentsd: powerd unreachable — confirm runs without wake lock");
    }
    WakeGuard { pwr, id }''',
     '''    let pwr = connect_retry(&sock);
    match pwr.as_ref() {
        Some(p) => {
            let _ = p.request("wake-lock", json!({ "id": id }));
        }
        None => {
            eprintln!("paymentsd: powerd unreachable — confirm runs without wake lock");
        }
    }
    WakeGuard { pwr, id }'''),
])

patch("tools/pay-gate.sh", [
    ('''# 3. accept via the compositor keyboard
python3 - <<'PYEOF'
import socket, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmon")
s.settimeout(2)
def drain():
    try:
        return s.recv(65536).decode(errors="replace")
    except socket.timeout:
        return ""
drain()
s.send(b"sendkey a\\n")
time.sleep(0.2)
drain()
s.close()
print("[ox-pay] sent 'a' (accept)")
PYEOF''',
     '''# 3. accept via the compositor keyboard — retry: the boot-time power
# self-test suspends the machine for ~8 s and keys pressed while frozen are
# lost; a press after resume still reaches the pending key-recv.
send_a() {
    python3 - <<'PYEOF'
import socket, time
s = socket.socket(socket.AF_UNIX)
s.connect("/tmp/ox-qmon")
s.settimeout(2)
def drain():
    try:
        return s.recv(65536).decode(errors="replace")
    except socket.timeout:
        return ""
drain()
s.send(b"sendkey a\\n")
time.sleep(0.2)
drain()
s.close()
PYEOF
}
n=1
while [ "$n" -le 5 ]; do
    grep -q "name=payment-authorized" "$LOG" 2>/dev/null && break
    send_a
    say "sent 'a' (accept) [attempt $n]"
    w=0
    while [ "$w" -lt 8 ]; do
        grep -q "name=payment-authorized" "$LOG" 2>/dev/null && break
        sleep 1; w=$((w + 1))
    done
    n=$((n + 1))
done'''),
])

print("ALL PATCHES OK")
