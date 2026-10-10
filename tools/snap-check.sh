#!/bin/sh
# diagnostic: do the newest store source snapshots carry slot-confirm?
ls -dt /nix/store/*-source 2>/dev/null | head -4 | while read -r s; do
    n=$(ls "$s/system/s6-rc-source/" 2>/dev/null | grep -c slot-confirm)
    echo "$n slot-confirm-dirs in $s"
done
# and what does cleanSource do with the slot-confirm dir RIGHT NOW?
cd /root/oxbuild
N=/nix/var/nix/profiles/per-user/root/profile/bin/nix
OUT=$($N eval --impure --raw --expr '
  let f = (builtins.getFlake (toString /root/oxbuild)).inputs.nixpkgs.lib;
      s = f.cleanSource /root/oxbuild/system/s6-rc-source/slot-confirm;
  in toString s' 2>/tmp/snap-err.txt) || { echo EVAL_FAIL; cat /tmp/snap-err.txt; exit 1; }
echo "cleaned slot-confirm -> $OUT"
ls "$OUT" 2>/dev/null
