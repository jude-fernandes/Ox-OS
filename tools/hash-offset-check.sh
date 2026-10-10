#!/bin/sh
# diagnostic: is the verity hash tree present at the in-slot offset?
I=/nix/store/5zpnjsmi6v8nzv7dqswa86mar3xfvlw4-image-pinephone-pro-0.1.0-chunk72
echo "hash img head:"
dd if="$I/system.hash.img" bs=4096 count=1 status=none | od -A n -t x1 | head -2
echo "flash @ (144+2944)MiB = sector 6311936:"
dd if=/tmp/ox-slotboot-debug/flash.img bs=4096 skip=791552 count=1 status=none | od -A n -t x1 | head -2
echo "hash img size (blocks):"
stat -c %s "$I/system.hash.img"
