#!/bin/sh
# Local (qemu-user) pipewire lab: start the guest pipewire with a dummy
# config, then try sink-creation variants with instant feedback.
set -eu
QEMU=qemu-aarch64-static
PW=/nix/store/ff6wlvfazkc2fqhcjdjka3p8v4kr6zsf-pipewire-aarch64-unknown-linux-musl-1.2.7
LAB=/tmp/ox-pwlab
rm -rf "$LAB"; mkdir -p "$LAB/run" "$LAB/conf"
export PIPEWIRE_RUNTIME_DIR="$LAB/run"
export XDG_RUNTIME_DIR="$LAB/run"
export LD_LIBRARY_PATH="$PW/lib/pipewire-0.3:$PW/lib/spa-0.2:$PW/lib"
export PIPEWIRE_CONFIG_DIR="$LAB/conf"
export PIPEWIRE_DEBUG=2

# Minimal config: dummy driver only (no ALSA on this host, which is fine —
# we are testing node-creation syntax, not audio capture).
cat > "$LAB/conf/pipewire.conf" <<'EOF'
context.properties = { default.clock.rate = 48000 }
context.modules = [
    { name = libpipewire-module-rtkit
      flags = [ "ifexists" "nofail" ] }
    { name = libpipewire-module-protocol-native }
]
context.objects = [
]
EOF
cp "$PW/share/pipewire/client.conf" "$LAB/conf/client.conf"

"$QEMU" "$PW/bin/pipewire" > "$LAB/server.log" 2>&1 &
SRV=$!
i=0
while [ $i -lt 20 ]; do
    [ -S "$LAB/run/pipewire-0" ] && break
    sleep 1; i=$((i + 1))
done
echo "== socket after ${i}s: $(ls "$LAB/run" 2>/dev/null | tr '\n' ' ') =="
echo "== server alive: $(kill -0 $SRV 2>/dev/null && echo yes || echo NO) =="
echo "== server log =="
head -6 "$LAB/server.log"

echo "== ls Node =="
"$QEMU" "$PW/bin/pw-cli" ls Node 2>&1 | grep -a 'node.name' | head -4

echo "== create-node attempt A: key=value pairs =="
"$QEMU" "$PW/bin/pw-cli" create-node spa-node-factory \
    factory.name=api.alsa.pcm.sink api.alsa.path=hw:0,0 \
    node.name=ox-speaker 2>&1 | head -4 || true

echo "== create-node attempt B: JSON one-arg =="
"$QEMU" "$PW/bin/pw-cli" create-node spa-node-factory \
    '{ "factory.name": "api.alsa.pcm.sink", "api.alsa.path": "hw:0,0", "node.name": "ox-speaker" }' 2>&1 | head -4 || true

echo "== nodes after attempts =="
"$QEMU" "$PW/bin/pw-cli" ls Node 2>&1 | grep -a 'node.name' | head -6
kill $SRV 2>/dev/null || true
