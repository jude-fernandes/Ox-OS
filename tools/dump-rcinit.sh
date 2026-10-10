#!/usr/bin/env bash
cd /tmp/ox-s6/src || exit 1
tar -xzf s6-rc-0.7.0.0.tar.gz s6-rc-0.7.0.0/src/rc/s6-rc-init.c -O > /tmp/rcinit.c 2>/dev/null || {
    tar -tzf s6-rc-0.7.0.0.tar.gz | grep rc/s6-rc-init
    exit 1
}
grep -n 'unable to supervise' /tmp/rcinit.c
