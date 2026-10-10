/* Standalone ed25519 verdict for given pub/message/signature files. */
#define main ox_init_main
#include "../initramfs/ox-init.c"
#undef main

int main(int argc, char **argv)
{
    unsigned char pub[32], sig[64];
    static unsigned char msg[65536];
    FILE *f;
    size_t mlen;
    if (argc != 4) { printf("usage: ed-probe PUB MSG SIG\n"); return 2; }
    f = fopen(argv[1], "rb");
    if (!f || fread(pub, 1, 32, f) != 32) return 2;
    fclose(f);
    f = fopen(argv[3], "rb");
    if (!f || fread(sig, 1, 64, f) != 64) return 2;
    fclose(f);
    f = fopen(argv[2], "rb");
    if (!f) return 2;
    mlen = fread(msg, 1, sizeof(msg), f);
    fclose(f);
    printf("mlen=%zu verdict=%d\n", mlen,
           ed25519_verify(sig, msg, mlen, pub));
    return 0;
}
