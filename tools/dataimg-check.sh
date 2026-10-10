#!/bin/sh
D=/tmp/ox-notifg-payload
echo "=== runner has the ext4 interim? ==="
grep -c "R-23 interim" /tmp/notification-gate-run.sh 2>/dev/null || echo 0
echo "=== data.img signature ==="
echo "LUKSIG=$(dd if=$D/data.img bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \n')"
echo "EXTSIG=$(dd if=$D/data.img bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')"
ls -la "$D" | grep -a data
