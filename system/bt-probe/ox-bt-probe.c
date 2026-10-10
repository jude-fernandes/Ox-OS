/* ox-bt-probe: two diagnostic modes for the virtual Bluetooth stack.
 *
 * default: diagnose the /dev/vhci attach step by step (errno per call).
 * Mirrors what bluez btvirt does in vhci_open: open(O_RDWR|O_NONBLOCK),
 * write {0xff, opcode}, read the 4-byte create reply — then polls the
 * fd for 6s to verify the kernel's auto-init command stream (the Reset)
 * actually reaches userspace.
 *
 * scan DEV SECONDS: prove LE discovery end to end — bind a raw HCI
 * socket to an hci device, send LE Set Scan Parameters/Enable, and
 * print every LE advertising report that surfaces. hcitool lescan
 * block-buffers its stdout when piped and `timeout`'s SIGTERM loses
 * it; this mode fflushes per line and exits cleanly, so its output is
 * trustworthy as a gate signal. HCI constants are hand-rolled from
 * linux/bluetooth.h + hci.h — no bluez headers needed.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <time.h>
#include <sys/socket.h>

#define AF_BT          31 /* AF_BLUETOOTH */
#define BTPROTO_HCI     1
#define SOL_HCI         0
#define SO_HCI_FILTER   2
#define HCI_EVENT_PKT   0x04
#define EVT_LE_META     0x3e
#define LE_ADV_REPORT   0x02

struct bt_hci_sa {
	unsigned short family;
	unsigned short dev;
	unsigned short channel;
};

struct bt_hci_flt {
	unsigned int type_mask;
	unsigned int event_mask[2];
	unsigned short opcode;
	unsigned int ptype_mask;
};

static int scan_main(const char *devname, int seconds)
{
	/* active scan, 10ms interval/window, public addr, no filter policy */
	unsigned char cmd_param[11] = { 0x01, 0x0b, 0x20, 0x07, 0x01,
		0x10, 0x00, 0x10, 0x00, 0x00, 0x00 };
	/* enable, filter_dup=0 (kernel must not dedupe repeats) */
	unsigned char cmd_on[6] = { 0x01, 0x0c, 0x20, 0x02, 0x01, 0x00 };
	unsigned char cmd_off[6] = { 0x01, 0x0c, 0x20, 0x02, 0x00, 0x00 };
	struct bt_hci_sa sa;
	struct bt_hci_flt flt;
	unsigned char buf[512];
	struct pollfd pfd;
	time_t start;
	int dd, dev_id = 0, found = 0;
	ssize_t n;

	if (devname && strncmp(devname, "hci", 3) == 0)
		dev_id = atoi(devname + 3);

	dd = socket(AF_BT, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
	if (dd < 0) {
		printf("scan: socket errno=%d (%s)\n", errno, strerror(errno));
		return 3;
	}
	memset(&sa, 0, sizeof(sa));
	sa.family = AF_BT;
	sa.dev = (unsigned short) dev_id;
	sa.channel = 0;
	if (bind(dd, (struct sockaddr *) &sa, sizeof(sa)) < 0) {
		printf("scan: bind hci%d errno=%d (%s)\n",
		       dev_id, errno, strerror(errno));
		close(dd);
		return 3;
	}

	/* only HCI event packets carrying LE meta events (0x3e) */
	memset(&flt, 0, sizeof(flt));
	flt.type_mask = 1u << HCI_EVENT_PKT;
	flt.event_mask[1] = 1u << (EVT_LE_META - 32);
	flt.ptype_mask = 0xffffffffu;
	if (setsockopt(dd, SOL_HCI, SO_HCI_FILTER, &flt, sizeof(flt)) < 0)
		printf("scan: setsockopt errno=%d (%s)\n", errno, strerror(errno));

	if (write(dd, cmd_param, sizeof(cmd_param)) < 0)
		printf("scan: scan-params errno=%d (%s)\n", errno, strerror(errno));
	if (write(dd, cmd_on, sizeof(cmd_on)) < 0)
		printf("scan: scan-enable errno=%d (%s)\n", errno, strerror(errno));
	printf("scan: hci%d scanning for %ds\n", dev_id, seconds);
	fflush(stdout);

	start = time(NULL);
	while (time(NULL) - start < seconds) {
		pfd.fd = dd;
		pfd.events = POLLIN;
		if (poll(&pfd, 1, 500) <= 0)
			continue;
		n = read(dd, buf, sizeof(buf));
		if (n <= 0)
			continue;
		if (buf[0] != HCI_EVENT_PKT || buf[1] != EVT_LE_META) {
			/* not an LE meta event: hexdump for the log */
			printf("scan: other frame n=%zd:", n);
			for (ssize_t k = 0; k < n && k < 12; k++)
				printf(" %02x", buf[k]);
			printf("\n");
			fflush(stdout);
			continue;
		}
		/* [type][0x3e][plen][subevent][num][reports...] */
		if (buf[3] != LE_ADV_REPORT)
			continue;
		int num = buf[4];
		size_t off = 5; /* past type, evt, plen, subevent, num */
		while (num-- > 0 && off + 10 <= (size_t) n) {
			unsigned char dlen = buf[off + 8];
			printf("ADV %02x:%02x:%02x:%02x:%02x:%02x (addr type %u, adv type %u, %u data bytes)\n",
			       buf[off + 7], buf[off + 6], buf[off + 5],
			       buf[off + 4], buf[off + 3], buf[off + 2],
			       buf[off + 1], buf[off], dlen);
			fflush(stdout);
			found++;
			off += 10 + dlen; /* 9 header bytes + data + rssi */
		}
	}

	if (write(dd, cmd_off, sizeof(cmd_off)) < 0)
		printf("scan: scan-disable errno=%d (%s)\n", errno, strerror(errno));
	close(dd);
	printf("scan: done, %d advert(s) seen\n", found);
	fflush(stdout);
	return found > 0 ? 0 : 4;
}

int main(int argc, char **argv)
{
	const char *path;
	unsigned char req[2] = { 0xff, 0x00 };
	unsigned char rsp[4];
	unsigned char buf[256];
	struct pollfd pfd;
	ssize_t n;
	int fd;

	if (argc > 1 && strcmp(argv[1], "scan") == 0)
		return scan_main(argc > 2 ? argv[2] : "hci0",
				 argc > 3 ? atoi(argv[3]) : 6);

	path = argc > 1 ? argv[1] : "/dev/vhci";
	fd = open(path, O_RDWR | O_NONBLOCK);
	printf("open   fd=%d errno=%d (%s)\n", fd, errno, strerror(errno));
	if (fd < 0)
		return 1;

	n = write(fd, req, sizeof(req));
	printf("write  n=%zd errno=%d (%s)\n", n, errno, strerror(errno));
	if (n != (ssize_t) sizeof(req)) {
		close(fd);
		return 2;
	}

	memset(rsp, 0, sizeof(rsp));
	n = read(fd, rsp, sizeof(rsp));
	printf("read   n=%zd errno=%d (%s) reply=%02x %02x %02x %02x\n",
	       n, errno, strerror(errno),
	       n > 0 ? rsp[0] : 0, n > 1 ? rsp[1] : 0,
	       n > 2 ? rsp[2] : 0, n > 3 ? rsp[3] : 0);

	/* hold the controller and dump the kernel's auto-init stream */
	pfd.fd = fd;
	pfd.events = POLLIN;
	for (int i = 0; i < 6; i++) {
		int pr = poll(&pfd, 1, 2000);
		if (pr <= 0) {
			printf("poll   rc=%d errno=%d\n", pr, errno);
			continue;
		}
		memset(buf, 0, sizeof(buf));
		n = read(fd, buf, sizeof(buf));
		printf("recv   n=%zd:", n);
		for (ssize_t k = 0; k < n && k < 20; k++)
			printf(" %02x", buf[k]);
		printf("\n");
		if (n >= 4 && buf[0] == 0x01) {
			unsigned char cc[7] = { 0x04, 0x0e, 0x04, 0x01,
					    buf[1], buf[2], 0x00 };
			ssize_t w = write(fd, cc, sizeof(cc));
			printf("sent   cc n=%zd\n", w);
		}
	}

	close(fd);
	printf("closed\n");
	return 0;
}
