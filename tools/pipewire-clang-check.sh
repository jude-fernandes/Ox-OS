#!/bin/sh
# Search the NEWEST pipewire drv graph (the one currently building) for
# clang derivations, and print the clang drv's own inputs.
set -eu
NIX=/nix/var/nix/profiles/per-user/root/profile/bin/nix
NEW="$(ls -t /nix/store/*pipewire*aarch64*.drv | head -1)"
echo "newest pipewire drv: $NEW"
"$NIX" derivation show -r "$NEW" > /tmp/pw-graph.json
python3 - <<'EOF'
import json
data = json.load(open("/tmp/pw-graph.json"))["derivations"]
print("graph:", len(data))
hits = [k for k in data if "clang" in k.rsplit("/", 1)[-1]]
print("clang drvs:", len(hits))
for h in hits[:3]:
    print("  ", h.rsplit("/", 1)[-1])
# who depends on the first clang drv?
if hits:
    t = hits[0]
    for k, node in data.items():
        if t in (node.get("inputDrvs") or {}):
            print("parent:", k.rsplit("/", 1)[-1])
EOF
