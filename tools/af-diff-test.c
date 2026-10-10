/* Differential test: cryptsetup's reference AF_split vs ox-init's af_merge.
 * If merge(split(x)) == x, our anti-forensic merge is byte-exact. */
#define main ox_init_main
#include "../initramfs/ox-init.c"
#undef main

/* ---- minimal shims so the reference af.c compiles against us ---- */
#define CRYPT_RND_NORMAL 2
#define SECTOR_SIZE 512
struct crypt_device;
struct crypt_hash {
    unsigned char buf[2048];
    size_t len;
};
int crypt_hash_init(struct crypt_hash **h, const char *name)
{
    (void)name;
    *h = calloc(1, sizeof(**h));
    return *h ? 0 : -1;
}
int crypt_hash_write(struct crypt_hash *h, const char *src, size_t n)
{
    if (h->len + n > sizeof(h->buf)) return -1;
    memcpy(h->buf + h->len, src, n);
    h->len += n;
    return 0;
}
int crypt_hash_final(struct crypt_hash *h, char *dst, size_t len)
{
    unsigned char dig[32];
    if (len > 32) return -1;
    sha256_buf(h->buf, h->len, dig);
    memcpy(dst, dig, len);
    return 0;
}
void crypt_hash_destroy(struct crypt_hash *h) { free(h); }
void *crypt_safe_alloc(size_t n) { return calloc(1, n); }
void crypt_safe_free(void *p) { free(p); }
static uint32_t be32_to_cpu(uint32_t v)
{
    return ((v & 0xff) << 24) | ((v & 0xff00) << 8) |
           ((v >> 8) & 0xff00) | (v >> 24);
}
static int crypt_hash_size(const char *name)
{
    (void)name;
    return 32;
}
struct crypt_random_ctx;
int crypt_random_get(struct crypt_device *ctx, char *buf, size_t len, int quality)
{
    size_t i;
    (void)ctx; (void)quality;
    for (i = 0; i < len; i++) buf[i] = (char)(random() & 0xff);
    return 0;
}
#define internal_h_INTERNAL_H_SHIM
#include "af_ref_shim.h"

#define main af_reference_main_unused
#include "/tmp/cryptsetup-2.7.5/lib/luks1/af.c"
#undef main

#include <stdio.h>

int main(void)
{
    unsigned char src[64], split[64 * 4000], out[64];
    unsigned long i;

    srandom(1234);
    for (i = 0; i < 64; i++) src[i] = (unsigned char)random();

    if (AF_split(NULL, (char *)src, (char *)split, 64, 4000, "sha256")) {
        puts("ref split failed");
        return 1;
    }
    af_merge(split, out, 64, 4000);
    if (memcmp(out, src, 64)) {
        puts("AF DIFF FAIL: merged != source");
        hexlog("got ", out, 16);
        hexlog("want", src, 16);
        return 2;
    }
    puts("AF merge matches reference implementation");
    return 0;
}
