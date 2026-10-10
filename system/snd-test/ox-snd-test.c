/* ox-snd-test: minimal audio-path selftest for the Ox OS virtual target.
 *
 * Plays a 440 Hz triangle wave (1 s, S16_LE mono @ 48 kHz) through the OSS
 * emulation interface (/dev/dsp, backed by snd-pcm-oss over snd-virtio in
 * the QEMU target). Integer-only NCO — no libm. The gate harness dumps the
 * host-side stream to a wav via QEMU's `wav` audiodev and verifies it is
 * non-silent, proving device → kernel → userspace end to end.
 *
 * Exit 0 + "OXMILESTONE name=audio-played" on success.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/soundcard.h>
#include <unistd.h>

#define RATE 48000
#define FREQ 440
#define SECONDS 1
#define AMPL 12000
#define CHUNK 4800 /* 100 ms */

static void klog(const char *msg)
{
    int fd = open("/dev/kmsg", O_WRONLY);
    if (fd >= 0) {
        dprintf(fd, "<6>%s\n", msg);
        close(fd);
    }
    fputs(msg, stderr);
    fputc('\n', stderr);
}

int main(void)
{
    int fd = open("/dev/dsp", O_WRONLY);
    if (fd < 0) {
        klog("ox-snd-test: /dev/dsp unavailable (no OSS emulation or sound device)");
        return 1;
    }

    int fmt = AFMT_S16_LE;
    if (ioctl(fd, SNDCTL_DSP_SETFMT, &fmt) < 0 || fmt != AFMT_S16_LE) {
        klog("ox-snd-test: SETFMT S16_LE failed");
        return 1;
    }
    int ch = 1;
    if (ioctl(fd, SNDCTL_DSP_CHANNELS, &ch) < 0 || ch != 1) {
        klog("ox-snd-test: CHANNELS=1 failed");
        return 1;
    }
    int rate = RATE;
    if (ioctl(fd, SNDCTL_DSP_SPEED, &rate) < 0) {
        klog("ox-snd-test: SPEED ioctl failed");
        return 1;
    }

    /* Triangle NCO: phase in [0,65536), full cycle = FREQ Hz. */
    const long step = (long)FREQ * 65536 / RATE;
    long phase = 0;
    short buf[CHUNK];
    int written = 0;
    const int total = RATE * SECONDS;

    while (written < total) {
        int n = (total - written < CHUNK) ? total - written : CHUNK;
        for (int i = 0; i < n; i++) {
            long p = phase & 0xffff;
            long d = (p >= 32768) ? 65536 - p : p; /* 0..32768 distance from trough */
            buf[i] = (short)((d * 2 * AMPL / 32768) - AMPL);
            phase += step;
        }
        ssize_t r = write(fd, buf, (size_t)n * sizeof(short));
        if (r < 0) {
            klog("ox-snd-test: write failed");
            return 1;
        }
        written += n;
    }

    int zero = 0;
    ioctl(fd, SNDCTL_DSP_SYNC, &zero);
    close(fd);

    char msg[128];
    snprintf(msg, sizeof(msg),
             "OXMILESTONE name=audio-played rate=%d fmt=s16le frames=%d freq=%d",
             rate, total, FREQ);
    klog(msg);
    return 0;
}
