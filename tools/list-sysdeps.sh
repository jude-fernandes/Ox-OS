#!/usr/bin/env bash
cd /tmp/ox-s6/src || exit 1
tar -xzOf skalibs-2.15.1.0.tar.gz skalibs-2.15.1.0/configure > /tmp/sk-conf.sh
grep -nE 'trysysdep|sysdep [a-z]+=' /tmp/sk-conf.sh | head -30
echo ====
grep -oE '(addsysdep|trysysdep) +[a-z]+' /tmp/sk-conf.sh | sort -u
