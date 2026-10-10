#!/bin/sh
# Payment-UI milestone chain: tests -> Nix build (daemons incl. oxctl) ->
# rootfs -> payload -> run the pay gate.
set -eu
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox"
for f in flake.nix system/rootfs.nix system/s6-rc-source/paydemo/run \
         system/s6-rc-source/paydemo/type system/s6-rc-source/default/contents \
         tools/pay-gate.sh rust/Cargo.toml; do
    sed -i 's/\r$//' "$f"
done

echo "== cargo tests =="
export PATH="$HOME/.cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    for c in /root/.rustup/toolchains/*/bin/cargo /home/*/.cargo/bin/cargo; do
        [ -x "$c" ] && DIR=$(dirname "$c") && export PATH="$DIR:$PATH" && break
    done
fi
cd rust
CARGO_TARGET_DIR=/tmp/ox-hyg cargo test -p oxpaymentsd --quiet 2>&1 | grep "test result" | tail -2
CARGO_TARGET_DIR=/tmp/ox-hyg cargo build --workspace --all-targets 2>&1 | grep -c "^warning" | xargs -I{} echo "host warnings: {}"
cd ..

echo "== Nix build =="
nix build -L .#guest-daemons 2>&1 | grep -E "warning|error" | head -3 || true
nix build -L .#guest-daemons .#kernel-qemu --no-link --print-out-paths > /tmp/ox-nix-paths
G=$(sed -n 1p /tmp/ox-nix-paths)
K=$(sed -n 2p /tmp/ox-nix-paths)
ls "$G/bin/oxctl" && echo "oxctl in guest-daemons"
echo "== build payload =="
nix build -L .#payload-qemu --no-link --print-out-paths > /tmp/ox-nix-paths2
P=$(sed -n 1p /tmp/ox-nix-paths2)
echo "payload: $P"
echo "== pay gate =="
rm -rf /tmp/ox-pay-payload && mkdir -p /tmp/ox-pay-payload
cp -r "$P"/. /tmp/ox-pay-payload/
bash tools/pay-gate.sh /tmp/ox-pay-payload "$K/Image"
echo "PAYMENT UI MILESTONE COMPLETE"
