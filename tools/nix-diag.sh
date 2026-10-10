#!/bin/sh
# Diagnose why the nix build compiles from source instead of substituting.
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH

echo "== substituters =="
nix config show 2>/dev/null | grep -E '^(substituters|trusted-public-keys|require-sigs|max-jobs|cores|sandbox)'

echo "== outputs of the LLVM drv currently building =="
DRV=/nix/store/0i31dzcs4k9vpwi0brkl1rr60w715dwp-llvm-18.1.8.drv
nix derivation show "$DRV" 2>/dev/null > /tmp/llvm-drv.json
python3 - <<'EOF'
import json
d = json.load(open('/tmp/llvm-drv.json'))
for _, drv in d.items():
    for k, v in drv['outputs'].items():
        print(k, v['path'])
EOF
