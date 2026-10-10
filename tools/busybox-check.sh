#!/bin/sh
B=/nix/store/q901s2w8j6712spjx03n9p161pqpwr9x-ox-busybox-aarch64-1.36.1/bin/busybox
echo "=== applet list (ip/udhcpc/route/ifconfig) ==="
for a in ip udhcpc route ifconfig; do
    if strings "$B" | grep -qx "$a"; then echo "$a: yes"; else echo "$a: NO"; fi
done
