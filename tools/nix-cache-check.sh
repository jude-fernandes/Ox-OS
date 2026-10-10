#!/bin/sh
# Check whether cache.nixos.org has substitutes for the outputs of a drv.
export PATH=/nix/var/nix/profiles/per-user/root/profile/bin:$PATH

DRV="$1"
if [ -z "$DRV" ]; then
    DRV=/nix/store/0i31dzcs4k9vpwi0brkl1rr60w715dwp-llvm-18.1.8.drv
fi

echo "== outputs of $DRV =="
for p in $(nix-store -q --outputs "$DRV" 2>/dev/null); do
    h=$(basename "$p" | cut -d- -f1)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://cache.nixos.org/$h.narinfo")
    echo "$code $p"
done
