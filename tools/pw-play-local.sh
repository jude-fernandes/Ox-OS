#!/bin/sh
Q=qemu-aarch64-static
P=/nix/store/ff6wlvfazkc2fqhcjdjka3p8v4kr6zsf-pipewire-aarch64-unknown-linux-musl-1.2.7
echo "== pw-play --help =="
"$Q" "$P/bin/pw-play" --help 2>&1 | head -10
echo "rc=$?"
echo "== pw-play bogus invocation =="
"$Q" "$P/bin/pw-play" --target ox-speaker /x.wav 2>&1 | head -8
echo "rc2=$?"
