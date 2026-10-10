#!/bin/sh
set -eu
G="$(sed -n 1p /tmp/ox-nix-paths)"
echo "guest-daemons: $G"
strings "$G/bin/oxpaymentsd" | grep -c 'paymentsd-confirm' || true
strings "$G/bin/oxpaymentsd" | grep 'wake-lock' | head -3 || true
P="$(sed -n 1p /tmp/ox-nix-paths2)"
echo "payload: $P"
