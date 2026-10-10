#!/usr/bin/env python3
"""Diagnostic: dump the registered-algorithm inventory from /proc/crypto
to the console when the dm-crypt table fails (removed after diagnosis)."""

path = "initramfs/ox-init.c"
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read().replace("\r\n", "\n")

old = '''            if (dm_create_crypt("oxdata", data_sectors, spec, &dm_dev) < 0) {
                kmsg("luks2: dm-crypt table load failed "
                     "(see R-23; continuing without data volume)");
                return;
            }'''
new = '''            if (dm_create_crypt("oxdata", data_sectors, spec, &dm_dev) < 0) {
                /* DIAGNOSTIC: dump /proc/crypto algorithm names */
                FILE *pf = fopen("/proc/crypto", "r");
                if (pf) {
                    char pl[128];
                    int pn = 0;
                    while (fgets(pl, sizeof(pl), pf) && pn < 60) {
                        size_t plen = strlen(pl);
                        if (plen && pl[plen-1] == '\\n') pl[plen-1] = 0;
                        if (!strncmp(pl, "name", 4) || !strncmp(pl, "type", 4) ||
                            !strncmp(pl, "driver", 6)) {
                            kmsg("proc-crypto: %s", pl);
                            pn++;
                        }
                    }
                    fclose(pf);
                }
                kmsg("luks2: dm-crypt table load failed "
                     "(see R-23; continuing without data volume)");
                return;
            }'''
assert text.count(old) == 1, text.count(old)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text.replace(old, new))
print("patched", path)
