#!/usr/bin/env python3
"""Diagnostic probe: when the LUKS data-segment dm table fails to load,
retry with alternative cipher specs and log which ones the guest kernel
can actually allocate (removed again after diagnosis)."""

path = "initramfs/ox-init.c"
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read().replace("\r\n", "\n")

old = '''            if (dm_create_crypt("oxdata", data_sectors, spec, &dm_dev) < 0) {
                kmsg("luks2: dm-crypt table load failed "
                     "(see R-23; continuing without data volume)");
                return;
            }'''
new = '''            if (dm_create_crypt("oxdata", data_sectors, spec, &dm_dev) < 0) {
                /* DIAGNOSTIC PROBE (remove after diagnosis): try
                 * alternative cipher specs and log which allocate. */
                static const char *probes[] = {
                    "aes-ecb", "capi:xts(aes)-plain64", "aes-cbc-plain64"
                };
                char probe[512];
                int pi;
                kmsg("luks2: dm-crypt table load failed (probing)");
                for (pi = 0; pi < 3; pi++) {
                    snprintf(probe, sizeof(probe),
                             "0 %llu crypt %s %s %llu %s %llu 1 sector_size:%llu",
                             data_sectors, probes[pi], keyhex, iv_tweak, dev,
                             off_b / 512, sector_size);
                    if (dm_create_crypt("oxprobe", data_sectors, probe,
                                        &dm_dev) == 0) {
                        kmsg("luks2: PROBE %s OK", probes[pi]);
                        break;
                    }
                    kmsg("luks2: PROBE %s failed", probes[pi]);
                }
                kmsg("luks2: dm-crypt table load failed "
                     "(see R-23; continuing without data volume)");
                return;
            }'''
assert text.count(old) == 1, text.count(old)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text.replace(old, new))
print("patched", path)
