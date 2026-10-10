#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/dm-ioctl.h>
#include <sched.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "ox-slotmeta.h"

static void kmsg(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    int n, fd;
    va_start(ap, fmt);
#ifdef OX_HOST_DEBUG
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    va_start(ap, fmt);
#endif
    n = vsnprintf(buf, sizeof(buf) - 16, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    memmove(buf + 12, buf, (size_t)n + 1);
    memcpy(buf, "<6>ox-init: ", 12);
    fd = open("/dev/kmsg", O_WRONLY);
    if (fd >= 0) {
        write(fd, buf, (size_t)n + 12);
        close(fd);
    }
}

static void msleep(long ms)
{
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static int wait_for_path(const char *path, int timeout_ms)
{
    int waited = 0;
    struct stat st;
    while (stat(path, &st) != 0) {
        if (waited >= timeout_ms) return -1;
        msleep(20);
        waited += 20;
    }
    return 0;
}

struct env_entry { const char *key; char val[256]; };

static int read_env(const char *path, struct env_entry *entries, int count)
{
    FILE *f = fopen(path, "r");
    char line[512];
    if (!f) return -1;
    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        int i;
        if (!eq) continue;
        *eq = 0;
        for (i = 0; i < count; i++) {
            size_t klen = strlen(entries[i].key);
            if (strncmp(line, entries[i].key, klen) == 0 &&
                strlen(line) == klen) {
                char *nl = strchr(eq + 1, '\n');
                size_t vlen = nl ? (size_t)(nl - eq - 1) : strlen(eq + 1);
                if (vlen >= sizeof(entries[i].val)) vlen = sizeof(entries[i].val) - 1;
                memcpy(entries[i].val, eq + 1, vlen);
                entries[i].val[vlen] = 0;
            }
        }
    }
    fclose(f);
    return 0;
}

static unsigned long long env_ull(struct env_entry *entries, int count,
                                  const char *key)
{
    int i;
    for (i = 0; i < count; i++)
        if (strcmp(entries[i].key, key) == 0)
            return strtoull(entries[i].val, NULL, 10);
    return 0;
}

#include <dirent.h>

static int find_disk_by_sectors(unsigned long long sectors, char *out,
                                size_t outsz)
{
    DIR *d = opendir("/sys/block");
    struct dirent *e;
    if (!d) return -1;
    while ((e = readdir(d))) {
        char path[256];
        FILE *f;
        unsigned long long sz;
        if (strncmp(e->d_name, "vd", 2) != 0) continue;
        snprintf(path, sizeof(path), "/sys/block/%s/size", e->d_name);
        f = fopen(path, "r");
        if (!f) continue;
        if (fscanf(f, "%llu", &sz) == 1 && sz == sectors) {
            fclose(f);
            closedir(d);
            snprintf(out, outsz, "/dev/%s", e->d_name);
            return 0;
        }
        fclose(f);
    }
    closedir(d);
    return -1;
}

static const char *env_str(struct env_entry *entries, int count,
                           const char *key)
{
    int i;
    for (i = 0; i < count; i++)
        if (strcmp(entries[i].key, key) == 0)
            return entries[i].val;
    return "";
}

static int dm_ctl(unsigned long cmd, struct dm_ioctl *io, size_t sz,
                  const char *what)
{
    int fd = open("/dev/mapper/control", O_RDWR);
    int rc;
    if (fd < 0) {
        kmsg("cannot open /dev/mapper/control for %s", what);
        return -1;
    }
    rc = ioctl(fd, cmd, io);
    if (rc < 0)
        kmsg("%s failed: ioctl rc=%d errno=%d", what, rc, errno);
    close(fd);
    return rc < 0 ? -1 : 0;
}

static size_t io_size(size_t extra) { return sizeof(struct dm_ioctl) + extra; }

static void init_io(char *buf, size_t sz, const char *name)
{
    struct dm_ioctl *io = (struct dm_ioctl *)buf;
    memset(buf, 0, sz);
    io->version[0] = DM_VERSION_MAJOR;
    io->version[1] = DM_VERSION_MINOR;
    io->version[2] = DM_VERSION_PATCHLEVEL;
    io->data_size = (unsigned int)sz;
    io->data_start = (unsigned int)sizeof(struct dm_ioctl);
    strncpy(io->name, name, sizeof(io->name) - 1);
}

static int dm_create_verity(const char *name, unsigned long long sectors,
                            const char *spec, dev_t *dev_out)
{
    char buf[2048];
    struct dm_ioctl *io = (struct dm_ioctl *)buf;
    struct dm_target_spec *tgt;

    init_io(buf, sizeof(buf), name);
    if (dm_ctl(DM_VERSION, io, io_size(0), "DM_VERSION") < 0) return -1;

    init_io(buf, sizeof(buf), name);
    if (dm_ctl(DM_DEV_CREATE, io, io_size(0), "DM_DEV_CREATE") < 0) return -1;

    init_io(buf, sizeof(buf), name);
    tgt = (struct dm_target_spec *)(buf + sizeof(struct dm_ioctl));
    io->data_size = (unsigned int)(sizeof(struct dm_ioctl) +
                    sizeof(struct dm_target_spec) + strlen(spec) + 1);
    io->flags |= DM_READONLY_FLAG;
    io->target_count = 1;
    tgt->sector_start = 0;
    tgt->length = sectors;
    strncpy(tgt->target_type, "verity", sizeof(tgt->target_type) - 1);
    memcpy((char *)(tgt + 1), spec, strlen(spec) + 1);
    tgt->next = 0;
    if (dm_ctl(DM_TABLE_LOAD, io, io->data_size, "DM_TABLE_LOAD") < 0) return -1;

    init_io(buf, sizeof(buf), name);
    if (dm_ctl(DM_DEV_SUSPEND, io, io_size(0), "DM_DEV_SUSPEND") < 0) return -1;
    if (dev_out) *dev_out = io->dev;

    return 0;
}

static void hexlog(const char *label, const unsigned char *b, int len)
{
    char line[256];
    int n = snprintf(line, sizeof(line), "%s:", label);
    int i;
    for (i = 0; i < len && n < (int)sizeof(line) - 3; i++)
        n += snprintf(line + n, sizeof(line) - n, "%02x", b[i]);
    kmsg("%s", line);
}

static unsigned int rrot(unsigned int x, int n)
{
    return (x >> n) | (x << (32 - n));
}

static void sha256_compress(const unsigned char *p, unsigned int h[8])
{
    static const unsigned int k[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,
        0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
        0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,
        0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,
        0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
        0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,
        0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,
        0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
        0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
    unsigned int w[64];
    unsigned int a, b, c, d, e, f, g, hh, t1, t2;
    int j;
    for (j = 0; j < 16; j++)
        w[j] = ((unsigned int)p[j*4] << 24) | (p[j*4+1] << 16) |
               (p[j*4+2] << 8) | p[j*4+3];
    for (j = 16; j < 64; j++) {
        unsigned int s0 = rrot(w[j-15],7) ^ rrot(w[j-15],18) ^ (w[j-15] >> 3);
        unsigned int s1 = rrot(w[j-2],17) ^ rrot(w[j-2],19) ^ (w[j-2] >> 10);
        w[j] = w[j-16] + s0 + w[j-7] + s1;
    }
    a = h[0]; b = h[1]; c = h[2]; d = h[3];
    e = h[4]; f = h[5]; g = h[6]; hh = h[7];
    for (j = 0; j < 64; j++) {
        unsigned int S1 = rrot(e,6) ^ rrot(e,11) ^ rrot(e,25);
        unsigned int ch = (e & f) ^ ((~e) & g);
        t1 = hh + S1 + ch + k[j] + w[j];
        unsigned int S0 = rrot(a,2) ^ rrot(a,13) ^ rrot(a,22);
        unsigned int mj = (a & b) ^ (a & c) ^ (b & c);
        t2 = S0 + mj;
        hh = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

#define SHA_H0 { 0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au, \
                 0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u }

static void sha256_buf(const unsigned char *in, size_t len,
                       unsigned char out[32])
{
    static const unsigned int init[8] = SHA_H0;
    unsigned int h[8];
    unsigned char tail[128];
    size_t full = len & ~(size_t)63;
    size_t rem = len - full;
    size_t padded = (rem < 56) ? 64 : 128;
    unsigned long long bits = (unsigned long long)len * 8;
    int i, j;

    memcpy(h, init, sizeof(h));
    for (i = 0; i < (int)full; i += 64)
        sha256_compress(in + i, h);

    memset(tail, 0, padded);
    memcpy(tail, in + full, rem);
    tail[rem] = 0x80;
    for (j = 0; j < 8; j++)
        tail[padded - 1 - j] = (unsigned char)(bits >> (8 * j));
    sha256_compress(tail, h);
    if (padded == 128)
        sha256_compress(tail + 64, h);

    for (i = 0; i < 8; i++) {
        out[i*4]   = (unsigned char)(h[i] >> 24);
        out[i*4+1] = (unsigned char)(h[i] >> 16);
        out[i*4+2] = (unsigned char)(h[i] >> 8);
        out[i*4+3] = (unsigned char)h[i];
    }
}

static void dump_head(const char *dev, int len)
{
    unsigned char buf[64];
    int fd = open(dev, O_RDONLY);
    if (fd < 0) return;
    if (read(fd, buf, len) == len)
        hexlog(dev, buf, len);
    close(fd);
}

/* ==================== LUKS2 data-volume support (dev) =====================
 * Minimal unlock path for Phase-1 CI containers:
 * luks2 + pbkdf2 keyslot + aes area (cbc-essiv or xts) + af merge
 * + digest validation + dm-crypt table creation.
 * Production requirements (argon2id, keyring, TPM/secure-element binding)
 * land with the Phase-5 security workstream (R-22).
 */

#define AES256 1
#include "tiny-AES-c.c" /* vendored, public domain: kokke/tiny-AES-c */

/* ------------------- verified boot (ed25519, PD impl) -------------------- */
#define ENVN 11
static struct env_entry env_global[ENVN] = {
    { "OX_DATA_SECTORS", "" },
    { "OX_DATA_BLOCKS", "" },
    { "OX_SALT", "" },
    { "OX_ROOT_HASH", "" },
    { "OX_HASH_SECTORS", "" },
    { "OX_M0_SHA", "" },
    { "OX_SKIP_VERITY", "" },
    { "OX_LUKS_DISK_SECTORS", "" },
    { "OX_VERBOSE", "" },
    { "OX_VERIFY_FULL", "" },
    { "OX_ENFORCE_ASYM", "" },
};
/* orlp/ed25519 files are standalone units; de-duplicate their helpers and
 * avoid the libc 'select' collision when compiled as one translation unit. */
#define load_3 sc_load_3
#define load_4 sc_load_4
#define select ge_select
#include "ed25519/fixedint.h"
#include "ed25519/sha512.c"
#include "ed25519/fe.c"
#undef load_3
#undef load_4
#include "ed25519/sc.c"
#include "ed25519/ge.c"
#undef select
#include "ed25519/verify.c"

/* streaming SHA-256 for block-device hashing */
typedef struct {
    unsigned int h[8];
    unsigned char blk[64];
    size_t fill;
    unsigned long long total;
} sha256_stream;

static void sha256s_init(sha256_stream *s)
{
    static const unsigned int init[8] = SHA_H0;
    memcpy(s->h, init, sizeof(s->h));
    s->fill = 0;
    s->total = 0;
}

static void sha256s_update(sha256_stream *s,
                           const unsigned char *data, size_t len)
{
    s->total += len;
    while (len) {
        size_t take = 64 - s->fill;
        if (take > len) take = len;
        memcpy(s->blk + s->fill, data, take);
        s->fill += take;
        data += take;
        len -= take;
        if (s->fill == 64) {
            sha256_compress(s->blk, s->h);
            s->fill = 0;
        }
    }
}

static void sha256s_final(sha256_stream *s, unsigned char out[32])
{
    unsigned char tail[128];
    size_t padded = (s->fill < 56) ? 64 : 128;
    unsigned long long bits = s->total * 8;
    int i, j;
    memset(tail, 0, padded);
    memcpy(tail, s->blk, s->fill);
    tail[s->fill] = 0x80;
    for (j = 0; j < 8; j++)
        tail[padded - 1 - j] = (unsigned char)(bits >> (8 * j));
    sha256_compress(tail, s->h);
    if (padded == 128)
        sha256_compress(tail + 64, s->h);
    for (i = 0; i < 8; i++) {
        out[i*4]   = (unsigned char)(s->h[i] >> 24);
        out[i*4+1] = (unsigned char)(s->h[i] >> 16);
        out[i*4+2] = (unsigned char)(s->h[i] >> 8);
        out[i*4+3] = (unsigned char)s->h[i];
    }
}

static int sha256_device(const char *dev, unsigned char out[32],
                         unsigned long long max_bytes)
{
    sha256_stream s;
    static unsigned char buf[65536];
    int fd = open(dev, O_RDONLY);
    ssize_t r;
    unsigned long long done = 0;
    if (fd < 0) return -1;
    sha256s_init(&s);
    while ((r = read(fd, buf, sizeof(buf))) > 0) {
        if (done + (unsigned long long)r > max_bytes) {
            r = (ssize_t)(max_bytes - done);
        }
        sha256s_update(&s, buf, (size_t)r);
        done += (unsigned long long)r;
        if (done >= max_bytes) break;
    }
    close(fd);
    if (done != max_bytes) return -1;
    sha256s_final(&s, out);
    return 0;
}

static void hmac_sha256(const unsigned char *key, size_t klen,
                        const unsigned char *msg, size_t mlen,
                        unsigned char out[32])
{
    unsigned char k0[64], pad[96], inner[160];
    unsigned char ih[32];
    int i;
    memset(k0, 0, sizeof(k0));
    if (klen > 64) {
        sha256_buf(key, klen, k0);
    } else {
        memcpy(k0, key, klen);
    }
    if (mlen > 96) return;
    for (i = 0; i < 64; i++)
        inner[i] = (unsigned char)(k0[i] ^ 0x36);
    memcpy(inner + 64, msg, mlen);
    sha256_buf(inner, 64 + mlen, ih);
    for (i = 0; i < 64; i++) pad[i] = (unsigned char)(k0[i] ^ 0x5c);
    memcpy(pad + 64, ih, 32);
    sha256_buf(pad, 96, out);
}

static void pbkdf2_sha256(const unsigned char *pw, size_t pwlen,
                          const unsigned char *salt, size_t saltlen,
                          unsigned long iters,
                          unsigned char *dk, size_t dklen)
{
    unsigned long block = 1;
    size_t done = 0;
    while (done < dklen) {
        unsigned char u[32], t[32], ibuf[8];
        unsigned long it;
        size_t blen = dklen - done < 32 ? dklen - done : 32;
        int i;
        ibuf[0] = (unsigned char)(block >> 24);
        ibuf[1] = (unsigned char)(block >> 16);
        ibuf[2] = (unsigned char)(block >> 8);
        ibuf[3] = (unsigned char)block;
        {
            unsigned char *tmp = (unsigned char *)malloc(saltlen + 4);
            if (!tmp) return;
            memcpy(tmp, salt, saltlen);
            memcpy(tmp + saltlen, ibuf, 4);
            hmac_sha256(pw, pwlen, tmp, saltlen + 4, u);
            free(tmp);
        }
        memcpy(t, u, 32);
        for (it = 1; it < iters; it++) {
            hmac_sha256(pw, pwlen, u, 32, u);
            for (i = 0; i < 32; i++) t[i] ^= u[i];
        }
        memcpy(dk + done, t, blen);
        done += blen;
        block++;
    }
}

/* LUKS1-style anti-forensic merge (reference: cryptsetup lib/luks1/af.c).
 * diffuse: dst[i*32..] = SHA256(BE32(i) || src[i*32 .. +len]) truncated. */
static void af_hash_buf(const unsigned char *src, unsigned char *dst,
                        unsigned int iv, size_t len)
{
    unsigned char msg[4 + 512], dig[32];
    msg[0] = (unsigned char)(iv >> 24);
    msg[1] = (unsigned char)(iv >> 16);
    msg[2] = (unsigned char)(iv >> 8);
    msg[3] = (unsigned char)iv;
    memcpy(msg + 4, src, len);
    sha256_buf(msg, 4 + len, dig);
    memcpy(dst, dig, len);
}

static void af_diffuse(unsigned char *buf, size_t size)
{
    unsigned char tmp[512];
    size_t blocks = size / 32, padding = size % 32;
    size_t i;
    memcpy(tmp, buf, size);
    for (i = 0; i < blocks; i++)
        af_hash_buf(tmp + i * 32, buf + i * 32, (unsigned int)i, 32);
    if (padding)
        af_hash_buf(tmp + blocks * 32, buf + blocks * 32,
                    (unsigned int)blocks, padding);
}

static void af_merge(const unsigned char *src, unsigned char *dst,
                     size_t blocksize, unsigned long blocknumbers)
{
    unsigned char *bufblock = calloc(1, blocksize);
    unsigned long i;
    if (!bufblock) return;
    for (i = 0; i + 1 < blocknumbers; i++) {
        size_t j;
        for (j = 0; j < blocksize; j++)
            bufblock[j] ^= src[blocksize * i + j];
        af_diffuse(bufblock, blocksize);
    }
    {
        size_t j;
        for (j = 0; j < blocksize; j++)
            dst[j] = src[blocksize * i + j] ^ bufblock[j];
    }
    free(bufblock);
}

/* XTS-AES decrypt of one data unit split into 16-byte blocks (LE tweak) */
static void xts_decrypt(struct AES_ctx *tweak, struct AES_ctx *data,
                        const unsigned char *in, unsigned char *out,
                        size_t len, unsigned long long unit)
{
    unsigned char tw[16], tt[16], buf[16];
    size_t off;
    int i;
    memset(tw, 0, sizeof(tw));
    for (i = 0; i < 8; i++) tw[i] = (unsigned char)(unit >> (8 * i));
    AES_ECB_encrypt(tweak, tw);
    for (off = 0; off + 16 <= len; off += 16) {
        memcpy(tt, tw, 16);
        for (i = 0; i < 16; i++) buf[i] = in[off + i] ^ tt[i];
        AES_ECB_decrypt(data, buf);
        for (i = 0; i < 16; i++) out[off + i] = buf[i] ^ tt[i];
        /* multiply tweak by x in GF(2^128), LE bit order */
        {
            unsigned char carry = 0;
            for (i = 0; i < 16; i++) {
                unsigned char nc = (unsigned char)(tw[i] >> 7);
                tw[i] = (unsigned char)((tw[i] << 1) | carry);
                carry = nc;
            }
            if (carry) tw[0] ^= 0x87;
        }
    }
}

/* CBC-ESSIV:sha256 decrypt over whole area: per 512B sector, IV derived
 * from the sector index (LE) via AES-ENC under SHA256(key)[0..15]; CBC
 * chains on ciphertext within each sector. */
static void cbc_essiv_decrypt(struct AES_ctx *data, struct AES_ctx *essiv,
                              const unsigned char *in, unsigned char *out,
                              unsigned long nsectors)
{
    unsigned long s;
    for (s = 0; s < nsectors; s++) {
        unsigned char iv[16], prev[16], buf[16];
        int i, j;
        memset(iv, 0, 16);
        for (i = 0; i < 8; i++)
            iv[i] = (unsigned char)(s >> (8 * i)); /* sector index LE */
        AES_ECB_encrypt(essiv, iv);
        memcpy(prev, iv, 16);
        for (j = 0; j < 4; j++) {
            const unsigned char *ct = in + s*512 + j*16;
            for (i = 0; i < 16; i++)
                buf[i] = (unsigned char)(ct[i] ^ prev[i]);
            AES_ECB_decrypt(data, buf);
            memcpy(out + s*512 + j*16, buf, 16);
            memcpy(prev, ct, 16);
        }
    }
}

static int b64_decode(const char *in, size_t inlen,
                      unsigned char *out, size_t outcap)
{
    static const int T[256] = { ['A']=0,['B']=1,['C']=2,['D']=3,['E']=4,['F']=5,
        ['G']=6,['H']=7,['I']=8,['J']=9,['K']=10,['L']=11,['M']=12,['N']=13,
        ['O']=14,['P']=15,['Q']=16,['R']=17,['S']=18,['T']=19,['U']=20,['V']=21,
        ['W']=22,['X']=23,['Y']=24,['Z']=25,['a']=26,['b']=27,['c']=28,['d']=29,
        ['e']=30,['f']=31,['g']=32,['h']=33,['i']=34,['j']=35,['k']=36,['l']=37,
        ['m']=38,['n']=39,['o']=40,['p']=41,['q']=42,['r']=43,['s']=44,['t']=45,
        ['u']=46,['v']=47,['w']=48,['x']=49,['y']=50,['z']=51,['0']=52,['1']=53,
        ['2']=54,['3']=55,['4']=56,['5']=57,['6']=58,['7']=59,['8']=60,['9']=61,
        ['+']=62,['/']=63 };
    size_t o = 0, i;
    unsigned acc = 0;
    int bits = 0;
    for (i = 0; i < inlen && o < outcap; i++) {
        char ch = in[i];
        if (ch == '=' || ch == '\n' || ch == '\r' || ch == ' ') break;
        if (ch == '"') break;
        acc = (acc << 6) | (unsigned)T[(unsigned char)ch];
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[o++] = (unsigned char)(acc >> bits);
        }
    }
    return (int)o;
}

static const char *json_value_ptr(const char *obj, const char *key)
{
    char pat[48];
    const char *p;
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    p = strstr(obj, pat);
    if (!p) return NULL;
    p += strlen(pat);
    p = strchr(p, ':');
    if (!p) return NULL;
    p++;
    while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
    return p;
}

/* copy a JSON string value into out */
static int json_str(const char *obj, const char *key, char *out, size_t cap)
{
    const char *p = json_value_ptr(obj, key);
    const char *e;
    size_t n;
    if (!p || *p != '"') return -1;
    p++;
    e = strchr(p, '"');
    if (!e) return -1;
    n = (size_t)(e - p);
    if (n >= cap) n = cap - 1;
    memcpy(out, p, n);
    out[n] = 0;
    return 0;
}

static int json_ull(const char *obj, const char *key, unsigned long long *out)
{
    const char *p = json_value_ptr(obj, key);
    if (!p) return -1;
    if (*p == '"') {
        p++;
        *out = strtoull(p, NULL, 0);
    } else {
        *out = strtoull(p, NULL, 10);
    }
    return 0;
}

/* pointer to '{' of the object bound to key; *end set past matching '}' */
static const char *json_object_span(const char *js, const char *key,
                                    const char **end);

/* restrict a lookup to a top-level section, e.g. "keyslots"/"segments"/
 * "digests", so bare numeric ids can't match across sections */
static const char *json_section(const char *js, const char *section)
{
    const char *p = json_value_ptr(js, section);
    if (!p || *p != '{') return NULL;
    return p + 1;
}

static const char *json_object_span(const char *js, const char *key,
                                    const char **end)
{
    const char *p = json_value_ptr(js, key);
    int depth = 0;
    if (!p || *p != '{') return NULL;
    for (*end = p; **end; (*end)++) {
        if (**end == '{') depth++;
        else if (**end == '}') {
            depth--;
            if (depth == 0) { (*end)++; break; }
        }
    }
    return p;
}

static int dm_create_crypt(const char *name, unsigned long long sectors,
                           const char *spec, dev_t *out_dev)
{
    char buf[2048];
    struct dm_ioctl *io = (struct dm_ioctl *)buf;
    struct dm_target_spec *tgt;

    init_io(buf, sizeof(buf), name);
    if (dm_ctl(DM_VERSION, io, io_size(0), "DM_VERSION") < 0) return -1;

    init_io(buf, sizeof(buf), name);
    if (dm_ctl(DM_DEV_CREATE, io, io_size(0), "DM_DEV_CREATE") < 0) return -1;
    if (out_dev) *out_dev = io->dev;

    init_io(buf, sizeof(buf), name);
    tgt = (struct dm_target_spec *)(buf + sizeof(struct dm_ioctl));
    {
        /* the first aes-xts allocation can race the boot-time crypto
         * self-test: the cipher stays ENOENT until its larval test
         * completes (seen on qemu tcg — xts(aes) registered ~1s after
         * the first table load). Retry instead of dropping the data
         * volume; the ioctl consumes the buffer, so rebuild it. */
        int attempt;
        for (attempt = 0; ; attempt++) {
            init_io(buf, sizeof(buf), name);
            tgt = (struct dm_target_spec *)(buf + sizeof(struct dm_ioctl));
            io->data_size = (unsigned int)(sizeof(struct dm_ioctl) +
                            sizeof(struct dm_target_spec) + strlen(spec) + 1);
            io->target_count = 1;
            tgt->sector_start = 0;
            tgt->length = sectors;
            strncpy(tgt->target_type, "crypt", sizeof(tgt->target_type) - 1);
            memcpy((char *)(tgt + 1), spec, strlen(spec) + 1);
            tgt->next = 0;
            if (dm_ctl(DM_TABLE_LOAD, io, io->data_size,
                       "DM_TABLE_LOAD") == 0)
                break;
            /* 60x250ms: under tcg the aes/xts self-test queue drains
             * ~28s into boot (xts-aes-ce passed at 28.8s in the
             * 2026-10-09 slotboot red) — 5s of retries missed it */
            if (errno != ENOENT || attempt >= 60) return -1;
            msleep(250);
        }
    }

    init_io(buf, sizeof(buf), name);
    if (dm_ctl(DM_DEV_SUSPEND, io, io_size(0), "DM_DEV_SUSPEND") < 0) return -1;

    return 0;
}

static void hex_to_buf(const char *hex, unsigned char *buf, size_t cap)
{
    size_t i, n = strlen(hex) / 2;
    if (n > cap) n = cap;
    for (i = 0; i < n; i++) {
        char hx[3] = { hex[i*2], hex[i*2+1], 0 };
        buf[i] = (unsigned char)strtoul(hx, NULL, 16);
    }
}

/* returns 0 and fills master key on success */
static int luks_unlock_slot(int fd, const unsigned char *hdr,
                            unsigned long long hdr_size,
                            const char *slotid,
                            const char *secret, size_t seclen,
                            unsigned char *master, size_t master_cap,
                            size_t *master_len)
{
    char obj[4096], enc[64], hash[32], saltb[128], digb[128];
    char areajs[512];
    unsigned long long iters = 0, stripes = 0, key_size = 0;
    unsigned long long a_off = 0, a_size = 0, a_keysize = 0;
    const char *js = (const char *)hdr + 4096;
    const char *sobj, *send;
    unsigned char salt[64], dk[64], *area_ct, *area_pt, *merged;
    unsigned long nsectors;
    size_t saltlen;
    (void)fd;

    sobj = json_object_span(json_section(js, "keyslots") ?: js, slotid, &send);
    if (!sobj || send - sobj >= (ptrdiff_t)sizeof(obj)) {
        kmsg("luks2: slot %s: no/oversized json object", slotid);
        return -1;
    }
    memcpy(obj, sobj, (size_t)(send - sobj));
    obj[send - sobj] = 0;

    if (json_str(obj, "type", hash, sizeof(hash)) || strcmp(hash, "luks2")) {
        kmsg("luks2: slot %s: type!=luks2", slotid);
        return -1;
    }
    json_ull(obj, "key_size", &key_size);
    if (!key_size || key_size > master_cap) {
        kmsg("luks2: slot %s: bad key_size=%llu", slotid, key_size);
        return -1;
    }

    /* --- kdf --- */
    {
        const char *kp, *ke;
        char kdf[512];
        kp = json_object_span(obj, "kdf", &ke);
        if (!kp) return -1;
        snprintf(kdf, sizeof(kdf), "%.*s", (int)(ke - kp), kp);
        if (json_str(kdf, "type", hash, sizeof(hash)) ||
            strcmp(hash, "pbkdf2")) return -1;
        if (json_str(kdf, "hash", hash, sizeof(hash)) ||
            strcmp(hash, "sha256")) return -1;
        json_ull(kdf, "iterations", &iters);
        if (iters < 1000 || iters > 10000000) return -1;
        if (json_str(kdf, "salt", saltb, sizeof(saltb))) return -1;
    }
    saltlen = (size_t)b64_decode(saltb, strlen(saltb), salt, sizeof(salt));

    /* --- area --- */
    {
        const char *ap, *ae;
        ap = json_object_span(obj, "area", &ae);
        if (!ap || ae - ap >= (ptrdiff_t)sizeof(areajs)) return -1;
        memcpy(areajs, ap, (size_t)(ae - ap));
        areajs[ae - ap] = 0;
        if (json_str(areajs, "encryption", enc, sizeof(enc))) return -1;
        json_ull(areajs, "offset", &a_off);
        json_ull(areajs, "size", &a_size);
        json_ull(areajs, "key_size", &a_keysize);
    }

    /* --- af --- */
    {
        const char *fp, *fe;
        char af[256];
        fp = json_object_span(obj, "af", &fe);
        if (!fp) { kmsg("luks2: slot %s: no af", slotid); return -1; }
        snprintf(af, sizeof(af), "%.*s", (int)(fe - fp), fp);
        if (json_str(af, "hash", hash, sizeof(hash)) ||
            strcmp(hash, "sha256")) return -1;
        json_ull(af, "stripes", &stripes);
    }
    if (!stripes || a_size < key_size * stripes) {
        kmsg("luks2: slot %s: af mismatch stripes=%llu a_size=%llu key_size=%llu",
             slotid, stripes, a_size, key_size);
        return -1;
    }

    pbkdf2_sha256((const unsigned char *)secret, seclen,
                  salt, saltlen, iters, dk, a_keysize);
    hexlog("luks2: dk0", dk, 16);
    kmsg("luks2: iters=%llu saltlen=%zu a_keysize=%llu a_off=%llu a_size=%llu",
         iters, saltlen, a_keysize, a_off, a_size);

    area_ct = malloc(a_size ? (size_t)a_size : 1);
    area_pt = malloc(a_size ? (size_t)a_size : 1);
    merged = calloc(1, key_size);
    if (!area_ct || !area_pt || !merged) goto oom;

    if (pread(fd, area_ct, (size_t)a_size, (off_t)a_off) != (ssize_t)a_size)
        goto fail;
    nsectors = (unsigned long)(a_size / 512);

    if (strstr(enc, "cbc-essiv")) {
        struct AES_ctx dk_ctx, essiv_ctx;
        unsigned char essiv_key[16], seed[32];
        sha256_buf(dk, a_keysize, seed);
        memcpy(essiv_key, seed, 16);
        AES_init_ctx(&dk_ctx, dk);
        AES_init_ctx(&essiv_ctx, essiv_key);
        cbc_essiv_decrypt(&dk_ctx, &essiv_ctx, area_ct, area_pt, nsectors);
    } else if (strstr(enc, "xts-plain64")) {
        struct AES_ctx data_ctx, tweak_ctx;
        AES_init_ctx(&data_ctx, dk);        /* first half: data key */
        AES_init_ctx(&tweak_ctx, dk + 32);  /* second half: tweak key */
        {
            unsigned long s;
            unsigned long long base = 0;
            for (s = 0; s < nsectors; s++)
                xts_decrypt(&tweak_ctx, &data_ctx,
                            area_ct + s*512, area_pt + s*512, 512,
                            base + s);
        }
    } else {
        goto fail;
    }

    /* AF merge (LUKS1 diffuse semantics) */
    af_merge(area_pt, merged, key_size, stripes);
    memcpy(master, merged, key_size);
    *master_len = key_size;
    free(area_ct); free(area_pt); free(merged);
    kmsg("luks2: slot %s unlocked (iters=%llu)", slotid, iters);
    return 0;

oom:
    kmsg("luks2: OOM in slot %s", slotid);
fail:
    free(area_ct); free(area_pt); free(merged);
    return -1;
}

static unsigned long long dev_size_bytes(const char *dev)
{
    char path[64];
    FILE *f;
    unsigned long long sectors = 0;
    snprintf(path, sizeof(path), "/sys/class/block/%s/size",
             strrchr(dev, '/') + 1);
    f = fopen(path, "r");
    if (f) {
        if (fscanf(f, "%llu", &sectors) != 1) sectors = 0;
        fclose(f);
    }
    return sectors * 512ULL;
}

/* parse an in-memory key=value text into entries */
static void read_env_mem(char *text, struct env_entry *entries, int count)
{
    char *line, *save = NULL;
    for (line = strtok_r(text, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        char *eq = strchr(line, '=');
        int i;
        if (!eq) continue;
        *eq = 0;
        for (i = 0; i < count; i++) {
            if (!strcmp(line, entries[i].key)) {
                size_t vlen = strlen(eq + 1);
                if (vlen >= sizeof(entries[i].val))
                    vlen = sizeof(entries[i].val) - 1;
                memcpy(entries[i].val, eq + 1, vlen);
                entries[i].val[vlen] = 0;
            }
        }
    }
}

/* Verified boot: check the signed manifest against reality.
 * Refuses (never returns) on any mismatch. */
static void verify_boot(const char *data_dev, const char *hash_dev)
{
    struct env_entry mf[7] = {
        { "target", "" }, { "sys_sha256", "" }, { "hashimg_sha256", "" },
        { "root_hash", "" }, { "sys_bytes", "" }, { "hash_bytes", "" },
        { "mac", "" },
    };
    static unsigned char mfbuf[8192];
    static unsigned char mfcopy[8192];
    unsigned char sig[64], pub[32], want[32], got[32], mac[32], mackey[32];
    ssize_t r;
    int fd;
    size_t mlen;
    int sigok;
    const char *roothash_env;

    fd = open("/etc/ox-manifest.bin", O_RDONLY);
    if (fd < 0) { kmsg("integrity FATAL: manifest missing"); goto refuse; }
    r = read(fd, mfbuf, sizeof(mfbuf));
    close(fd);
    if (r <= 0) { kmsg("integrity FATAL: manifest empty"); goto refuse; }
    /* keep pristine bytes for crypto; parse a mutable copy */
    memcpy(mfcopy, mfbuf, (size_t)r);
    mfcopy[r] = 0;
    read_env_mem((char *)mfcopy, mf, 7);

    fd = open("/etc/ox-manifest.sig", O_RDONLY);
    if (fd < 0) { kmsg("integrity FATAL: signature missing"); goto refuse; }
    r = read(fd, sig, sizeof(sig));
    close(fd);
    if (r != (ssize_t)sizeof(sig)) {
        kmsg("integrity FATAL: bad signature size %zd", (ssize_t)r);
        goto refuse;
    }

    fd = open("/ox-release.pub", O_RDONLY);
    if (fd < 0) { kmsg("integrity FATAL: release key missing"); goto refuse; }
    r = read(fd, pub, sizeof(pub));
    close(fd);
    if (r != (ssize_t)sizeof(pub)) {
        kmsg("integrity FATAL: bad release key size");
        goto refuse;
    }

    mlen = (size_t)r;
    {
        /* signature and MAC cover only the bytes before the trailing
         * "mac=" line */
        const char *mc = strstr((const char *)mfbuf, "\nmac=");
        if (!mc) { kmsg("integrity FATAL: missing mac tag"); goto refuse; }
        mlen = (size_t)(mc - (const char *)mfbuf) + 1;
    }
    {
        const char *enf = env_str(env_global, ENVN, "OX_ENFORCE_ASYM");
        int enforce = enf[0] && strcmp(enf, "0") != 0;
        sigok = ed25519_verify(sig, mfbuf, mlen, pub);
        int macok = 0;
        int mfd = open("/ox-dev.mac-key", O_RDONLY);
        if (mfd >= 0) {
            if (read(mfd, mackey, sizeof(mackey)) == (ssize_t)sizeof(mackey)) {
                hmac_sha256(mackey, sizeof(mackey), mfbuf, mlen, mac);
                hex_to_buf(mf[6].val, want, sizeof(want));
                macok = memcmp(mac, want, 32) == 0;
            }            close(mfd);
        }
        if (sigok) {
            kmsg("verified boot: ed25519 manifest signature valid");
        } else if (enforce) {
            kmsg("integrity FATAL: asymmetric signature invalid (enforced)");
            goto refuse;
        } else if (macok) {
            kmsg("verified boot: MAC valid; asymmetric deferred (R-24)");
        } else {
            kmsg("integrity FATAL: signature invalid and MAC mismatch");
            goto refuse;
        }
    }

    roothash_env = env_str(env_global, ENVN, "OX_ROOT_HASH");
    if (strcmp(mf[3].val, roothash_env) != 0) {
        kmsg("integrity FATAL: root hash mismatch vs manifest");
        goto refuse;
    }

    {
        unsigned long long dsz = dev_size_bytes(data_dev);
        unsigned long long hsz = dev_size_bytes(hash_dev);
        unsigned long long want_s = strtoull(mf[4].val, NULL, 10);
        unsigned long long want_h = strtoull(mf[5].val, NULL, 10);
        if (dsz != want_s || hsz != want_h) {
            kmsg("integrity FATAL: image sizes differ from manifest "
                 "(sys %llu/%llu hash %llu/%llu)",
                 dsz, want_s, hsz, want_h);
            goto refuse;
        }
    }

    if (env_str(env_global, ENVN, "OX_VERIFY_FULL")[0]) {
        hex_to_buf(mf[1].val, want, sizeof(want));
        if (sha256_device(data_dev, got,
                          strtoull(mf[4].val, NULL, 10)) < 0 ||
            memcmp(got, want, 32) != 0) {
            kmsg("integrity FATAL: system image hash mismatch");
            goto refuse;
        }
        hex_to_buf(mf[2].val, want, sizeof(want));
        if (sha256_device(hash_dev, got,
                          strtoull(mf[5].val, NULL, 10)) < 0 ||
            memcmp(got, want, 32) != 0) {
            kmsg("integrity FATAL: hash image mismatch");
            goto refuse;
        }
        kmsg("verified boot OK: full-image digests match signed manifest");
    } else {
        kmsg("verified boot OK: signature valid (full-image verify off)");
    }
    return;

refuse:
    kmsg("integrity: refusing to continue; halting");
    for (;;) pause();
}
static int luks_digest_ok(const unsigned char *hdr,
                          const char *slotid,
                          const unsigned char *master, size_t mlen)
{
    const char *js = (const char *)hdr + 4096;
    char obj[2048], saltb[128], digb[160];
    char dname[8];
    int d;
    for (d = 0; d < 4; d++) {
        const char *dobj, *dend;
        unsigned long long iters = 0;
        unsigned char dsalt[64], dk[32], mac[32], want[32];
        size_t dsaltlen;
        int i;
        snprintf(dname, sizeof(dname), "%d", d);
        dobj = json_object_span(json_section(js, "digests") ?: js, dname,
                                &dend);
        if (!dobj || dend - dobj >= (ptrdiff_t)sizeof(obj)) continue;
        memcpy(obj, dobj, (size_t)(dend - dobj));
        obj[dend - dobj] = 0;
        if (!strstr(obj, slotid)) continue;
        if (json_str(obj, "type", digb, sizeof(digb)) ||
            strcmp(digb, "pbkdf2")) continue;
        if (json_str(obj, "digest", digb, sizeof(digb))) continue;
        if (json_str(obj, "salt", saltb, sizeof(saltb))) continue;
        json_ull(obj, "iterations", &iters);
        if (!iters) continue;
        dsaltlen = (size_t)b64_decode(saltb, strlen(saltb), dsalt, sizeof(dsalt));
        /* LUKS2 pbkdf2 digest: stored = PBKDF2(volume_key, dsalt, iters, 32) */
        pbkdf2_sha256(master, mlen, dsalt, dsaltlen, iters, dk, 32);
        memset(want, 0, sizeof(want));
        {
            int dn = (int)b64_decode(digb, strlen(digb), want, sizeof(want));
            hexlog("luks2: dk_digest", dk, 32);
            hexlog("luks2: hdr_digest", want, 32);
            kmsg("luks2: digest decoded_len=%d", dn);
            if (dn != 32)
                return 0;
        }
        for (i = 0; i < 32; i++) if (dk[i] != want[i]) return 0;
        kmsg("luks2: digest %s validated", dname);
        return 1;
    }
    return 0;
}

static void luks_prompt_secret(char *buf, size_t cap)
{
    int fd = open("/dev/console", O_RDWR);
    size_t n = 0;
    write(fd, "ox-data passphrase: ", 20);
    for (;;) {
        char ch;
        ssize_t r = read(fd, &ch, 1);
        if (r <= 0 || ch == '\n') break;
        if (n + 1 < cap) buf[n++] = ch;
    }
    buf[n] = 0;
    write(fd, "\n", 1);
}

static void luks_try_unlock(const char *dev)
{
    static unsigned char hdr[16384];
    char secret[256];
    unsigned char master[64];
    size_t mlen = 0, seclen;
    unsigned long long version = 0, hdr_size = 0;
    int fd, s;
    const char *js;

    fd = open(dev, O_RDONLY);
    if (fd < 0) {
        kmsg("luks2: cannot open %s (errno=%d)", dev, errno);
        return;
    }
    if (pread(fd, hdr, 16, 0) != 16 ||
        memcmp(hdr, "LUKS\xba\xbe", 6)) {
        hexlog("luks2: no container, head", hdr, 16);
        close(fd);
        return;
    }
    /* load the full binary + JSON header for parsing */
    if (pread(fd, hdr, sizeof(hdr), 0) != (ssize_t)sizeof(hdr)) {
        kmsg("luks2: short header read on %s", dev);
        close(fd);
        return;
    }
    version = ((unsigned long long)hdr[6] << 8) | hdr[7];
    memcpy(&hdr_size, hdr + 8, 8);
    {
        unsigned long long be = 0;
        int i;
        for (i = 0; i < 8; i++)
            be = (be << 8) | hdr[8 + i];
        hdr_size = be;
    }
    (void)version;
    if (hdr_size < 8192 || hdr_size > sizeof(hdr)) {
        kmsg("luks2: unsupported header size %llu", hdr_size);
        close(fd);
        return;
    }
    js = (const char *)hdr + 4096;

    /* secret: embedded dev keyfile first, then console */
    {
        int kfd = open("/ox-data.key", O_RDONLY);
        seclen = 0;
        if (kfd >= 0) {
            ssize_t r = read(kfd, secret, sizeof(secret) - 1);
            if (r > 0) seclen = (size_t)r;
            close(kfd);
            while (seclen && (secret[seclen-1] == '\n' ||
                              secret[seclen-1] == '\r'))
                seclen--;
        }
    }
    if (!seclen) luks_prompt_secret(secret, sizeof(secret));
    if (!seclen) { close(fd); return; }

    kmsg("luks2: container detected on %s, unlocking (%zu bytes secret)",
         dev, seclen);

    for (s = 0; s < 8 && !mlen; s++) {
        char slotid[8];
        snprintf(slotid, sizeof(slotid), "%d", s);
        if (!strstr(js, slotid)) break;
        if (luks_unlock_slot(fd, hdr, hdr_size, slotid,
                             secret, seclen,
                             master, sizeof(master), &mlen) == 0 &&
            !luks_digest_ok(hdr, slotid, master, mlen)) {
            kmsg("luks2: digest mismatch for %s (wrong secret?)", slotid);
            mlen = 0;
        }
    }
    close(fd);
    if (!mlen) {
        kmsg("luks2: UNLOCK FAILED on %s (continuing without data volume)",
             dev);
        return;
    }

    /* data segment -> dm-crypt table */
    {
        char seg[512], enc[64], keyhex[129], spec[512];
        char segid[8];
        unsigned long long off_b = 0, iv_tweak = 0, sector_size = 512;
        unsigned long long data_sectors;
        const char *sobj, *send;
        int i, created = -1;

        /* devtmpfs does not provide the device-mapper control node */
        mkdir("/dev/mapper", 0755);
        mknod("/dev/mapper/control", S_IFCHR | 0600, makedev(10, 236));

        for (i = 0; i < 4 && created < 0; i++) {
            snprintf(segid, sizeof(segid), "%d", i);
            sobj = json_object_span(json_section(js, "segments") ?: js,
                                    segid, &send);
            if (!sobj) continue;
            snprintf(seg, sizeof(seg), "%.*s", (int)(send - sobj), sobj);
            if (strstr(seg, "\"crypt\"")) created = i;
        }
        if (created < 0) { kmsg("luks2: no crypt segment"); return; }
        if (json_str(seg, "encryption", enc, sizeof(enc)) ||
            json_ull(seg, "offset", &off_b)) {
            kmsg("luks2: segment parse failure");
            return;
        }
        json_ull(seg, "iv_tweak", &iv_tweak);
        json_ull(seg, "sector_size", &sector_size);
        if (!sector_size) sector_size = 512;

        for (i = 0; i < (int)mlen; i++)
            snprintf(keyhex + i*2, 3, "%02x", master[i]);

        {
            unsigned long long disk_sectors = 0;
            char spath[64];
            FILE *sf;
            snprintf(spath, sizeof(spath),
                     "/sys/class/block/%s/size", strrchr(dev, '/') + 1);
            sf = fopen(spath, "r");
            if (sf) { fscanf(sf, "%llu", &disk_sectors); fclose(sf); }
            if (!disk_sectors) disk_sectors = off_b / 512 + 1;
            data_sectors = disk_sectors - off_b / 512;
        }

        snprintf(spec, sizeof(spec),
                 "0 %llu crypt %s %s %llu %s %llu 1 sector_size:%llu",
                 data_sectors, enc, keyhex, iv_tweak, dev, off_b / 512,
                 sector_size);
        kmsg("luks2: table=%s", spec);
        {
            dev_t dm_dev = 0;
            char nod[64];
            if (dm_create_crypt("oxdata", data_sectors, spec, &dm_dev) < 0) {
                /* DIAGNOSTIC: dump /proc/crypto algorithm names */
                FILE *pf = fopen("/proc/crypto", "r");
                if (pf) {
                    char pl[128];
                    int pn = 0;
                    while (fgets(pl, sizeof(pl), pf) && pn < 500) {
                        size_t plen = strlen(pl);
                        if (plen && pl[plen-1] == '\n') pl[plen-1] = 0;
                        if (!strncmp(pl, "name", 4) || !strncmp(pl, "type", 4) ||
                            !strncmp(pl, "driver", 6) ||
                            !strncmp(pl, "selftest", 8) ||
                            !strncmp(pl, "internal", 8)) {
                            kmsg("proc-crypto: %s", pl);
                            pn++;
                        }
                    }
                    fclose(pf);
                }
                kmsg("luks2: dm-crypt table load failed "
                     "(see R-23; continuing without data volume)");
                return;
            }
            mkdir("/dev/mapper", 0755);
            snprintf(nod, sizeof(nod), "/dev/mapper/oxdata");
            mknod(nod, S_IFBLK | 0644,
                  makedev((unsigned)major(dm_dev), (unsigned)minor(dm_dev)));
            kmsg("luks2: unlocked volume active at %s (%llu sectors)",
                 nod, data_sectors);
        }
    }
}

/* ---- chunk 77: A/B slot boot (ox.slotmeta=<metadata dev> in cmdline) ----
 * The flashed layout (ox-flash.sh) carries six GPT partitions; the
 * metadata block names the active system slot and counts unconfirmed
 * boots. This path verifies the metadata, applies the rollback rule
 * (attempts exhausted -> other slot), pre-counts the attempt, builds
 * the dm-verity target from the slot's OWN root hash and in-slot hash
 * tree, and unlocks the LUKS data partition. Refuses to boot from
 * metadata that fails its integrity hash — a lying metadata block must
 * not choose what we execute. */
#define OX_SLOT_HASH_OFF_B (2944LL * 1024 * 1024) /* hash tree offset in slot */

static void cmdline_value(const char *key, char *out, size_t outsz)
{
    char buf[2048];
    int fd = open("/proc/cmdline", O_RDONLY);
    size_t n = 0, klen = strlen(key);
    if (fd < 0) { out[0] = 0; return; }
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) { out[0] = 0; return; }
    buf[n] = 0;
    char *p = buf;
    for (;;) {
        while (*p == ' ') p++;
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            p += klen + 1;
            size_t i = 0;
            /* stop at space AND newline: /proc/cmdline is \n-terminated */
            while (*p && *p != ' ' && *p != '\n' && i + 1 < outsz)
                out[i++] = *p++;
            out[i] = 0;
            return;
        }
        p = strchr(p, ' ');
        if (!p) break;
        p++;
    }
    out[0] = 0;
}

static void slot_part(const char *meta_dev, int idx, char *out, size_t outsz)
{
    /* metadata dev is <disk><digits> (vda5) or <disk>p<digits>
     * (mmcblk0p5); the partition device is <disk> + ("p" iff the disk
     * name itself ends in a digit) + <idx> — vda3, mmcblk0p3, loop0p3 */
    size_t bl = strlen(meta_dev);
    char base[64];
    char sep = 0;
    memcpy(base, meta_dev, bl < sizeof(base) - 1 ? bl : sizeof(base) - 1);
    base[bl < sizeof(base) - 1 ? bl : sizeof(base) - 1] = 0;
    while (bl > 0 && base[bl - 1] >= '0' && base[bl - 1] <= '9') bl--;
    if (bl > 0 && base[bl - 1] == 'p') bl--;
    base[bl] = 0;
    if (bl > 0 && base[bl - 1] >= '0' && base[bl - 1] <= '9') sep = 'p';
    /* sep==0 must NOT go through %c — snprintf would embed a literal
     * NUL mid-string and out would truncate to the bare disk name */
    if (sep)
        snprintf(out, outsz, "%s%c%d", base, sep, idx);
    else
        snprintf(out, outsz, "%s%d", base, idx);
}

static int hex2bin64(const char *hex, unsigned char *out)
{
    for (int i = 0; i < 32; i++) {
        char hx[3] = { hex[i*2], hex[i*2+1], 0 };
        if (!hex[i*2] || !hex[i*2+1]) return -1;
        out[i] = (unsigned char)strtoul(hx, NULL, 16);
    }
    return 0;
}

/* returns 0 with root_src = /dev/dm-0 ready; nonzero = refused */
static int slot_boot(const char *meta_dev, int verbose, char *root_src,
                     size_t rsz)
{
    unsigned char blk[4096];
    struct ox_slotmeta m;
    char sys_part[64], data_part[64];
    char roothex[65];
    int fd, rc, slot, rollback = 0;

    fd = open(meta_dev, O_RDONLY);
    if (fd < 0) {
        /* A second devtmpfs mount does not backfill nodes for devices
         * registered before it (the automount already holds them under
         * its shadow). Deterministic fix: mknod from sysfs dev numbers.
         * sysfs layout: /sys/block/<disk>/<part>/dev where <part> is
         * <disk><digits> (vda5) or <disk>p<digits> (mmcblk0p5). */
        char sysdev[192];
        unsigned maj = 0, min = 0;
        int have = 0;
        const char *rel = meta_dev + 5; /* strip "/dev/" */
        size_t dl = strlen(rel);
        while (dl > 0 && rel[dl - 1] >= '0' && rel[dl - 1] <= '9') dl--;
        if (dl > 0 && rel[dl - 1] == 'p') dl--; /* mmcblk0p5 form */
        snprintf(sysdev, sizeof(sysdev), "/sys/block/%.*s/%s/dev",
                 (int)dl, rel, rel);
        {
            int sfd = open(sysdev, O_RDONLY);
            char nb[32];
            ssize_t r = sfd >= 0 ? read(sfd, nb, sizeof(nb) - 1) : -1;
            if (sfd >= 0) close(sfd);
            if (r > 0) {
                nb[r] = 0;
                if (sscanf(nb, "%u:%u", &maj, &min) == 2) have = 1;
            }
            if (!have) {
                DIR *dp = opendir("/sys/block");
                struct dirent *de;
                kmsg("slot: sysfs read %s failed (r=%zd errno=%d)", sysdev,
                     r, errno);
                while (dp && (de = readdir(dp)) != NULL)
                    if (strncmp(de->d_name, "loop", 4) != 0 &&
                        strncmp(de->d_name, "ram", 3) != 0 &&
                        de->d_name[0] != '.')
                        kmsg("slot: /sys/block has %s", de->d_name);
                if (dp) closedir(dp);
                /* list the disk dir too */
                snprintf(sysdev, sizeof(sysdev), "/sys/block/%.*s",
                         (int)dl, rel);
                dp = opendir(sysdev);
                while (dp && (de = readdir(dp)) != NULL)
                    kmsg("slot: %s has %s", sysdev, de->d_name);
                if (dp) closedir(dp);
                /* class path alternative */
                snprintf(sysdev, sizeof(sysdev), "/sys/class/block/%s/dev",
                         rel);
                sfd = open(sysdev, O_RDONLY);
                kmsg("slot: open %s = %d (errno=%d)", sysdev, sfd, errno);
                if (sfd >= 0) {
                    char nb2[32];
                    ssize_t r2 = read(sfd, nb2, sizeof(nb2) - 1);
                    close(sfd);
                    if (r2 > 0) {
                        nb2[r2] = 0;
                        if (sscanf(nb2, "%u:%u", &maj, &min) == 2) have = 1;
                    }
                }
            }
        }
        if (have) {
            kmsg("slot: mknod %s (%u:%u, sysfs %s)", meta_dev, maj, min,
                 sysdev);
            mknod(meta_dev, S_IFBLK | 0600, makedev(maj, min));
            fd = open(meta_dev, O_RDONLY);
        }
    }
    if (fd < 0) {
        /* the virtio/ mmc probe may still be landing */
        if (wait_for_path(meta_dev, 15000) < 0) {
            kmsg("slot: metadata device %s never appeared (stat errno=%d)",
                 meta_dev, errno);
            return -1;
        }
        fd = open(meta_dev, O_RDONLY);
    }
    if (fd < 0) {
        kmsg("slot: cannot open metadata %s (errno=%d)", meta_dev, errno);
        return -1;
    }
    rc = pread(fd, blk, sizeof(blk), 0) == (ssize_t)sizeof(blk)
         ? oxsm_read(blk, sizeof(blk), &m) : -1;
    close(fd);
    if (rc == -2) { kmsg("slot: metadata integrity FAILED — refusing"); return -1; }
    if (rc != 0)   { kmsg("slot: metadata invalid — refusing"); return -1; }

    slot = (int)m.active_slot;
    if (m.boot_attempts >= OXSM_MAX_ATTEMPTS) {
        slot = 1 - slot;
        rollback = 1;
        kmsg("OXMILESTONE name=slot-rollback from=%d attempts=%u",
             m.active_slot, m.boot_attempts);
    }

    /* pre-count the attempt: an unconfirmed boot must survive a crash */
    m.active_slot = (unsigned)slot;
    m.boot_attempts = rollback ? 1 : m.boot_attempts + 1;
    fd = open(meta_dev, O_RDWR);
    if (fd < 0) { kmsg("slot: metadata not writable"); return -1; }
    oxsm_write(blk, &m);
    if (pwrite(fd, blk, OXSM_SIZE, 0) != OXSM_SIZE || fsync(fd) < 0) {
        kmsg("slot: metadata write failed"); close(fd); return -1;
    }
    fsync(fd);
    close(fd);

    kmsg("OXMILESTONE name=slot-boot slot=%d attempts=%u rollback=%d "
         "count_a=%u count_b=%u",
         slot, m.boot_attempts, rollback, m.boot_count_a, m.boot_count_b);

    /* devtmpfs missed the devices registered before its mount: create
     * every partition node from sysfs dev numbers (vda1..vdaN) */
    {
        char base[32];
        size_t bl = strlen(meta_dev);
        int idx;
        while (bl > 0 && meta_dev[bl - 1] >= '0' && meta_dev[bl - 1] <= '9')
            bl--;
        if (bl > 0 && meta_dev[bl - 1] == 'p') bl--;
        memcpy(base, meta_dev, bl);
        base[bl] = 0;
        for (idx = 1; idx <= 6; idx++) {
            char sp[192], nb[32];
            int sfd;
            ssize_t r;
            unsigned maj = 0, min = 0;
            snprintf(sp, sizeof(sp), "%s%d", base, idx);
            if (access(sp, F_OK) == 0) continue;
            snprintf(nb, sizeof(nb), "/sys/block/%s/%s%d/dev",
                     base + 5, base + 5, idx);
            sfd = open(nb, O_RDONLY);
            if (sfd < 0) continue;
            r = read(sfd, nb, sizeof(nb) - 1);
            close(sfd);
            if (r <= 0) continue;
            nb[r] = 0;
            if (sscanf(nb, "%u:%u", &maj, &min) == 2)
                mknod(sp, S_IFBLK | 0600, makedev(maj, min));
        }
    }

    slot_part(meta_dev, slot == 0 ? 3 : 4, sys_part, sizeof(sys_part));
    slot_part(meta_dev, 6, data_part, sizeof(data_part));

    unsigned long long blocks = slot == 0 ? m.data_blocks_a : m.data_blocks_b;
    const unsigned char *rh = slot == 0 ? m.root_hash_a : m.root_hash_b;
    for (int i = 0; i < 32; i++)
        snprintf(roothex + i*2, 3, "%02x", rh[i]);

    char spec[768];
    /* units-clean hash placement: dm-linear "oxhash" maps the system
     * partition starting AT the hash tree (2944MiB in), so the verity
     * hash device begins exactly at tree[0] with hash_start=0 — the
     * same geometry the non-slot path proves. No offset-unit guessing:
     * dm-linear's offset is in 512-byte sectors (documented). */
    mkdir("/dev/mapper", 0755);
    mknod("/dev/mapper/control", S_IFCHR | 0600, makedev(10, 236));
    {
        const char *rel = sys_part + 5; /* "vda3" — the hash tree lives
                                         * in the system slot partition,
                                         * NOT the LUKS data volume */
        char sysdev[192], lspec[256], diskname[32];
        unsigned long long part_sectors = 0;
        const unsigned long long tree_off_sectors =
            (unsigned long long)(OX_SLOT_HASH_OFF_B / 512);
        unsigned long long size_sectors;
        int sfd;
        char nb[32];
        ssize_t r;
        /* partition sysfs nodes nest under the parent disk
         * (/sys/block/vda/vda3/size); /sys/class/block/<part>/size is
         * the flat fallback */
        snprintf(diskname, sizeof(diskname), "%s", rel);
        {
            size_t dl = strlen(diskname);
            while (dl > 0 && diskname[dl - 1] >= '0' && diskname[dl - 1] <= '9')
                dl--;
            diskname[dl] = 0;
        }
        snprintf(sysdev, sizeof(sysdev), "/sys/block/%s/%s/size",
                 diskname, rel);
        sfd = open(sysdev, O_RDONLY);
        if (sfd < 0) {
            snprintf(sysdev, sizeof(sysdev), "/sys/class/block/%s/size",
                     rel);
            sfd = open(sysdev, O_RDONLY);
        }
        if (sfd < 0) { kmsg("slot: no sysfs size for %s", sys_part); return -1; }
        r = read(sfd, nb, sizeof(nb) - 1);
        close(sfd);
        if (r <= 0) { kmsg("slot: sysfs size read failed"); return -1; }
        nb[r] = 0;
        part_sectors = strtoull(nb, NULL, 10);
        if (part_sectors <= tree_off_sectors) {
            kmsg("slot: FATAL: partition too small for the hash tree");
            return -1;
        }
        size_sectors = part_sectors - tree_off_sectors;
        snprintf(lspec, sizeof(lspec), "%s %llu", sys_part,
                 tree_off_sectors);
        kmsg("slot: creating dm-linear oxhash (%llu sectors of %s from "
             "sector %llu)",
             size_sectors, sys_part, tree_off_sectors);
        {
            char buf[2048];
            struct dm_ioctl *io = (struct dm_ioctl *)buf;
            struct dm_target_spec *tgt =
                (struct dm_target_spec *)(buf + sizeof(struct dm_ioctl));
            init_io(buf, sizeof(buf), "oxhash");
            if (dm_ctl(DM_VERSION, io, io_size(0), "DM_VERSION") < 0) return -1;
            init_io(buf, sizeof(buf), "oxhash");
            if (dm_ctl(DM_DEV_CREATE, io, io_size(0), "DM_DEV_CREATE") < 0) return -1;
            {
                /* capture the assigned dev for the /dev node BEFORE the
                 * table-load re-init (the kernel fills io->dev on return) */
                dev_t oxhash_dev = io->dev;
                init_io(buf, sizeof(buf), "oxhash");
                io->data_size = (unsigned int)(sizeof(struct dm_ioctl) +
                                sizeof(struct dm_target_spec) + strlen(lspec) + 1);
                tgt->sector_start = 0;
                tgt->length = size_sectors;
                strncpy(tgt->target_type, "linear", sizeof(tgt->target_type) - 1);
                memcpy((char *)(tgt + 1), lspec, strlen(lspec) + 1);
                tgt->next = 0;
                io->target_count = 1;
                if (dm_ctl(DM_TABLE_LOAD, io, io->data_size,
                           "DM_TABLE_LOAD(oxhash)") < 0) return -1;
                init_io(buf, sizeof(buf), "oxhash");
                if (dm_ctl(DM_DEV_SUSPEND, io, io_size(0),
                           "DM_DEV_SUSPEND(oxhash)") < 0) return -1;
                mknod("/dev/mapper/oxhash", S_IFBLK | 0600, oxhash_dev);
            }
        }
    }

    snprintf(spec, sizeof(spec),
             "1 %s /dev/mapper/oxhash 4096 4096 %llu 0 "
             "sha256 %s %s 1 restart_on_corruption",
             /* the table is <algorithm> <digest> <salt> — digest FIRST
              * (dm-verity ctr argv[8]/argv[9]); swapped, every verify
             * failed as "metadata block 0 is corrupted" (2026-10-09) */
             sys_part, blocks, roothex,
             env_str(env_global, ENVN, "OX_SALT"));
    dev_t oxsys_dev = 0;
    if (dm_create_verity("oxsys", blocks * 8, spec, &oxsys_dev) != 0) {
        kmsg("slot: FATAL: verity target failed for slot %d", slot);
        return -1;
    }
    /* the verity device's dev_t comes straight from the SUSPEND ioctl
     * return — mknod /dev/mapper/oxsys ourselves (devtmpfs names may
     * lag or differ), and mount through it */
    /* mknod with the EXACT dev_t from the SUSPEND ioctl: devtmpfs may
     * name the node differently (oxhash took dm-0) */
    mknod("/dev/mapper/oxsys", S_IFBLK | 0600, oxsys_dev);
    {
        int sfd = open("/dev/mapper/oxsys", O_RDONLY);
        if (sfd < 0) { kmsg("slot: FATAL: oxsys node absent"); return -1; }
        close(sfd);
    }
    snprintf(root_src, rsz, "/dev/mapper/oxsys");

    /* the data volume: LUKS2 under the embedded dev key (R-22) */
    luks_try_unlock(data_part);

    /* slot mode mounts the root itself; main() joins at have_root */
    if (mount(root_src, "/newroot", "squashfs", MS_RDONLY, NULL) < 0) {
        kmsg("slot: FATAL: mount root from %s failed", root_src);
        return -1;
    }
    kmsg("OXMILESTONE name=slot-root slot=%d rollback=%d", slot, rollback);
    return 0;
}
/* ---- end slot boot ---- */

int main(void)
{
    char spec[768];
    char data_dev[32], hash_dev[32];
    const char *roothash;
    const int verbose = env_str(env_global, ENVN, "OX_VERBOSE")[0] &&
                        strcmp(env_str(env_global, ENVN, "OX_VERBOSE"), "0") != 0;

    mkdir("/proc", 0755); mkdir("/sys", 0755); mkdir("/dev", 0755);
    mkdir("/newroot", 0755);
    if (mount("proc", "/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL) < 0)
        kmsg("mount proc failed");
    if (mount("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL) < 0)
        kmsg("mount sysfs failed");
    if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755") < 0)
        kmsg("mount devtmpfs failed");

    if (read_env("/etc/verity.env", env_global, ENVN) < 0)
        kmsg("FATAL: cannot read /etc/verity.env");

    /* chunk 77: A/B slot mode — the flashed layout boots from GPT
     * partitions chosen by the metadata block (ox.slotmeta=<dev>) */
    {
        char slotmeta_dev[64] = "";
        char slot_root[32];
        cmdline_value("ox.slotmeta", slotmeta_dev, sizeof(slotmeta_dev));
        if (slotmeta_dev[0]) {
            if (slot_boot(slotmeta_dev, verbose, slot_root,
                          sizeof(slot_root)) != 0) {
                kmsg("FATAL: slot boot refused (metadata/verity)");
                for (;;) pause();
            }
            goto have_root;
        }
    }

    msleep(300);
    if (find_disk_by_sectors(env_ull(env_global, ENVN, "OX_DATA_SECTORS"),
                             data_dev, sizeof(data_dev)) < 0) {
        kmsg("FATAL: no disk matches system image size");
        for (;;) pause();
    }
    if (find_disk_by_sectors(env_ull(env_global, ENVN, "OX_HASH_SECTORS"),
                             hash_dev, sizeof(hash_dev)) < 0) {
        kmsg("FATAL: no disk matches hash image size");
        for (;;) pause();
    }
    kmsg("verity disks: data=%s hash=%s", data_dev, hash_dev);

    /* verified boot gate: signature + manifest vs reality */
    verify_boot(data_dev, hash_dev);

    if (verbose) {
        dump_head(data_dev, 32);
        dump_head(hash_dev, 48);
    }

    if (verbose) {
        unsigned char blk[4096], d[32], salt[32];
        int fd = open(hash_dev, O_RDONLY);
        size_t slen = strlen(env_str(env_global, ENVN, "OX_SALT"));
        int i;
        if (slen == 64) {
            for (i = 0; i < 32; i++) {
                char hx[3] = { env_str(env_global, ENVN, "OX_SALT")[i*2],
                               env_str(env_global, ENVN, "OX_SALT")[i*2+1], 0 };
                salt[i] = (unsigned char)strtoul(hx, NULL, 16);
            }
        }
        sha256_buf((const unsigned char *)"abc", 3, d);
        hexlog("H(abc)", d, 32);
        if (fd >= 0 && pread(fd, blk, sizeof(blk), 0) == (ssize_t)sizeof(blk)) {
            sha256_buf(blk, sizeof(blk), d);
            hexlog("guest_H_m0", d, 32);
            if (slen == 64) {
                unsigned char cat[4096 + 64];
                memcpy(cat, salt, 32);
                memcpy(cat + 32, blk, 4096);
                sha256_buf(cat, 4096 + 32, d);
                hexlog("guest_H_salt_m0", d, 32);
                kmsg("expected m0 from host=%s",
                     env_str(env_global, ENVN, "OX_M0_SHA"));
            }
        } else {
            kmsg("debug read of hash block failed");
        }
        if (fd >= 0) close(fd);
    }

    roothash = env_str(env_global, ENVN, "OX_ROOT_HASH");
    snprintf(spec, sizeof(spec),
             "1 %s %s 4096 4096 %llu 0 sha256 %s %s "
             "1 restart_on_corruption",
             /* table order: <algorithm> <digest> <salt> — digest FIRST
              * (dm-verity ctr argv[8]/argv[9]); was swapped (unnoticed:
              * the qemu payload defaults to OX_SKIP_VERITY=1, R-19) */
             data_dev, hash_dev,
             env_ull(env_global, ENVN, "OX_DATA_BLOCKS"), roothash,
             env_str(env_global, ENVN, "OX_SALT"));

    if (env_str(env_global, ENVN, "OX_SKIP_VERITY")[0]) {
        kmsg("integrity: skip-verity mode (payload signature enforced)");
    } else if (strlen(roothash) == 64 &&
        dm_create_verity("oxsys", env_ull(env_global, ENVN, "OX_DATA_SECTORS"), spec, NULL) == 0) {
        kmsg("verity target oxsys active");
    } else {
        kmsg("FATAL: verity target creation failed");
    }

    if (env_str(env_global, ENVN, "OX_SKIP_VERITY")[0]) {
        kmsg("mounting system directly from %s (skip-verity)", data_dev);
    } else if (wait_for_path("/dev/dm-0", 10000) < 0) {
        kmsg("FATAL: /dev/dm-0 absent");
    }

    /* data volume: unlock LUKS2 container if the payload declares one */
    if (env_ull(env_global, ENVN, "OX_LUKS_DISK_SECTORS")) {
        char dsk[32];
        if (find_disk_by_sectors(env_ull(env_global, ENVN, "OX_LUKS_DISK_SECTORS"),
                                 dsk, sizeof(dsk)) == 0) {
            kmsg("luks2: probing %s for encrypted data volume", dsk);
            luks_try_unlock(dsk);
        }
    }

    {
        const char *root_src = env_str(env_global, ENVN, "OX_SKIP_VERITY")[0]
                                   ? data_dev : "/dev/dm-0";
        kmsg("mounting root from %s", root_src);
        if (mount(root_src, "/newroot", "squashfs", MS_RDONLY, NULL) < 0) {
            kmsg("FATAL: mount root failed");
            for (;;) pause();
        }
    }

have_root:
    mount("/dev", "/newroot/dev", NULL, MS_MOVE, NULL);
    mount("proc", "/newroot/proc", NULL, MS_MOVE, NULL);
    mount("sysfs", "/newroot/sys", NULL, MS_MOVE, NULL);

    if (chdir("/newroot") < 0 || mount(".", "/", NULL, MS_MOVE, NULL) < 0 ||
        chroot(".") < 0 || chdir("/") < 0) {
        kmsg("FATAL: switch_root failed");
        for (;;) pause();
    }

    kmsg("handing off to /sbin/ox-init-stage2");
    {
        int cfd = open("/dev/console", O_RDWR);
        if (cfd >= 0) {
            dup2(cfd, 0);
            dup2(cfd, 1);
            dup2(cfd, 2);
            if (cfd > 2) close(cfd);
        } else {
            kmsg("warning: cannot reopen console for stage2 fds");
        }
    }
    char *argv[] = { "/sbin/ox-init-stage2", NULL };
    char *envp[] = { "PATH=/bin:/sbin:/usr/bin:/usr/sbin", "HOME=/", NULL };
    execve(argv[0], argv, envp);
    {
        char msg[64];
        int tfd = open("/dev/ttyAMA0", O_WRONLY);
        int n = snprintf(msg, sizeof(msg), "EXECVE_FAIL errno=%d\n", errno);
        if (tfd >= 0) {
            write(tfd, msg, (size_t)n);
            close(tfd);
        }
        kmsg("FATAL: execve stage2 failed errno=%d", errno);
    }
    kmsg("FATAL: execve stage2 failed");
    for (;;) pause();
}
