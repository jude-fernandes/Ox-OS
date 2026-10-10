/* ox-slotmeta.h — the A/B slot metadata format, shared by the stage-1
 * initramfs reader (ox-init.c) and documented in tools/ox-slotmeta.py
 * (the host-side packer/verifier; the format authority).
 *
 * The first 4KiB of the ox-metadata partition, little-endian:
 *   0   4   magic "OXSB"
 *   4   4   version (1)
 *   8   4   active_slot (0=a, 1=b)
 *   12  4   boot_attempts (unconfirmed boots of the active slot)
 *   16  4   boot_count_a
 *   20  4   boot_count_b
 *   24  32  root_hash_a
 *   56  32  root_hash_b
 *   88  8   data_blocks_a (dm-verity data blocks of slot a)
 *   96  8   data_blocks_b
 *   104 32  sha256 over bytes 0..104
 * Everything after byte 136 on the partition stays zero.
 */
#ifndef OX_SLOTMETA_H
#define OX_SLOTMETA_H

#include <string.h>
#include <stdint.h>

#define OXSM_MAGIC "OXSB"
#define OXSM_VERSION 1
#define OXSM_SIZE 136
#define OXSM_MAX_ATTEMPTS 3

/* the including translation unit provides the hash (ox-init.c's
 * software sha256) */
static void sha256_buf(const unsigned char *, size_t, unsigned char *);

struct ox_slotmeta {
    uint32_t active_slot;
    uint32_t boot_attempts;
    uint32_t boot_count_a;
    uint32_t boot_count_b;
    unsigned char root_hash_a[32];
    unsigned char root_hash_b[32];
    uint64_t data_blocks_a;
    uint64_t data_blocks_b;
};

/* returns 0 and fills *m on a valid block; -1 on magic/version failure,
 * -2 on integrity failure (the caller journals the reason) */
static int oxsm_read(const unsigned char *buf, size_t len,
                     struct ox_slotmeta *m)
{
    unsigned char sum[32];
    if (len < OXSM_SIZE)
        return -1;
    if (memcmp(buf, OXSM_MAGIC, 4) != 0)
        return -1;
    uint32_t version;
    memcpy(&version, buf + 4, 4);
    if (version != OXSM_VERSION)
        return -1;
    sha256_buf(buf, 104, sum);
    if (memcmp(sum, buf + 104, 32) != 0)
        return -2; /* tampered */
    memcpy(&m->active_slot, buf + 8, 4);
    memcpy(&m->boot_attempts, buf + 12, 4);
    memcpy(&m->boot_count_a, buf + 16, 4);
    memcpy(&m->boot_count_b, buf + 20, 4);
    memcpy(m->root_hash_a, buf + 24, 32);
    memcpy(m->root_hash_b, buf + 56, 32);
    memcpy(&m->data_blocks_a, buf + 88, 8);
    memcpy(&m->data_blocks_b, buf + 96, 8);
    return 0;
}

/* serialize into buf (OXSM_SIZE bytes; caller zeroes the rest) */
static void oxsm_write(unsigned char *buf, const struct ox_slotmeta *m)
{
    memset(buf, 0, OXSM_SIZE);
    memcpy(buf, OXSM_MAGIC, 4);
    uint32_t version = OXSM_VERSION;
    memcpy(buf + 4, &version, 4);
    memcpy(buf + 8, &m->active_slot, 4);
    memcpy(buf + 12, &m->boot_attempts, 4);
    memcpy(buf + 16, &m->boot_count_a, 4);
    memcpy(buf + 20, &m->boot_count_b, 4);
    memcpy(buf + 24, m->root_hash_a, 32);
    memcpy(buf + 56, m->root_hash_b, 32);
    memcpy(buf + 88, &m->data_blocks_a, 8);
    memcpy(buf + 96, &m->data_blocks_b, 8);
    sha256_buf(buf, 104, buf + 104);
}

#endif /* OX_SLOTMETA_H */
