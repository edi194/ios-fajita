/*
 * hcitest: talk H4 to the kernel's Bluetooth control (bsd/dev/beryllium_bt_hci.c, boot-arg sweetbt=1)
 * the way bluetoothd and BlueTool do, with no Apple code in the loop:
 *
 *   socket(PF_SYSTEM, SOCK_STREAM, SYSPROTO_CONTROL), CTLIOCGINFO "com.apple.uart.bluetooth",
 *   connect, termios through get/setsockopt(SYSPROTO_CONTROL, TIOCGETA / TIOCSETA),
 *   then HCI Reset, Read Local Version, Read BD_ADDR and the events decoded.
 *
 *   hcitest [-n CTLNAME] [-b BAUD] [-l SECONDS]
 *     -n  control name (default com.apple.uart.bluetooth)
 *     -b  baud in the termios set (default 3000000, what bluetoothd passes)
 *     -l  afterwards print every packet that arrives for SECONDS seconds
 *
 * Only one client can be connected: stop bluetoothd first
 *   launchctl bootout system/com.apple.bluetoothd     (or: launchctl remove com.apple.bluetoothd)
 * The iOS SDK has no <sys/kern_control.h>: the few definitions are repeated here.
 * Exit status 0 when all three commands completed with status 0.
 */
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

#define SYSPROTO_CONTROL        2
#define AF_SYS_CONTROL          2
#define CTLIOCGINFO             0xC0644E03UL            /* _IOWR('N', 3, struct ctl_info) */

struct ctl_info {
	uint32_t ctl_id;
	char ctl_name[96];
};

struct sockaddr_ctl {
	uint8_t sc_len;
	uint8_t sc_family;
	uint16_t ss_sysaddr;
	uint32_t sc_id;
	uint32_t sc_unit;
	uint32_t sc_reserved[5];
};

static uint8_t rxb[8192];
static unsigned rxn;

static double
now(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec + tv.tv_usec / 1e6;
}

static void
hex(const char *what, const uint8_t *p, unsigned n)
{
	printf("%s:", what);
	for (unsigned i = 0; i < n; i++) {
		printf(" %02x", p[i]);
	}
	printf("\n");
}

/* bytes needed for one H4 packet at the head of rxb: 0 = unknown type, else total (may exceed rxn) */
static unsigned
pkt_len(void)
{
	if (rxn < 1) {
		return 0;
	}
	switch (rxb[0]) {
	case 4:
		return rxn >= 3 ? 3u + rxb[2] : 3;
	case 2:
		return rxn >= 5 ? 5u + (rxb[3] | (rxb[4] << 8)) : 5;
	case 3:
		return rxn >= 4 ? 4u + rxb[3] : 4;
	case 5:
		return rxn >= 5 ? 5u + ((rxb[3] | (rxb[4] << 8)) & 0x3fff) : 5;
	default:
		return 0;
	}
}

/* read until one whole packet is buffered; false on timeout/error. The packet stays at rxb[0..len). */
static int
get_packet(int fd, double deadline, unsigned *len)
{
	for (;;) {
		unsigned n = pkt_len();
		if (rxn && n == 0) {
			printf("garbage byte %02x dropped\n", rxb[0]);
			memmove(rxb, rxb + 1, --rxn);
			continue;
		}
		if (n && rxn >= n) {
			*len = n;
			return 1;
		}
		double left = deadline - now();
		if (left <= 0) {
			return 0;
		}
		struct pollfd p = { fd, POLLIN, 0 };
		if (poll(&p, 1, (int)(left * 1000) + 1) <= 0) {
			return 0;
		}
		ssize_t r = read(fd, rxb + rxn, sizeof(rxb) - rxn);
		if (r <= 0) {
			printf("read: %s\n", r == 0 ? "EOF" : strerror(errno));
			return 0;
		}
		rxn += (unsigned)r;
	}
}

static void
drop(unsigned n)
{
	memmove(rxb, rxb + n, rxn - n);
	rxn -= n;
}

/* send a command, print what comes back until its Command Complete/Status; returns the status (-1 no answer) */
static int
command(int fd, unsigned opcode, const uint8_t *par, unsigned plen, uint8_t *ret, unsigned *retlen)
{
	uint8_t pkt[4 + 255];
	pkt[0] = 1;
	pkt[1] = opcode & 0xff;
	pkt[2] = opcode >> 8;
	pkt[3] = plen;
	if (plen) {
		memcpy(pkt + 4, par, plen);
	}
	char what[40];
	snprintf(what, sizeof(what), "TX cmd %#06x", opcode);
	hex(what, pkt, 4 + plen);
	double t0 = now();
	if (write(fd, pkt, 4 + plen) != (ssize_t)(4 + plen)) {
		printf("write: %s\n", strerror(errno));
		return -1;
	}
	double deadline = t0 + 5;
	unsigned n;
	while (get_packet(fd, deadline, &n)) {
		uint8_t *e = rxb;
		hex(e[0] == 4 ? "RX evt" : "RX pkt", e, n);
		if (e[0] == 4 && e[1] == 0x0e && n >= 7 && (e[4] | (e[5] << 8)) == (int)opcode) {
			printf("  Command Complete for %#06x, status %#x, %.1f ms\n", opcode, e[6], (now() - t0) * 1e3);
			if (ret) {
				memcpy(ret, e + 6, n - 6);
				*retlen = n - 6;
			}
			int st = e[6];
			drop(n);
			return st;
		}
		if (e[0] == 4 && e[1] == 0x0f && n >= 7 && (e[5] | (e[6] << 8)) == (int)opcode) {
			printf("  Command Status for %#06x: %#x\n", opcode, e[3]);
			int st = e[3];
			drop(n);
			return st;
		}
		drop(n);
	}
	printf("  no reply to %#06x within 5 s\n", opcode);
	return -1;
}

int
main(int argc, char **argv)
{
	const char *name = "com.apple.uart.bluetooth";
	unsigned long baud = 3000000;
	int listen_s = 0, ch;

	while ((ch = getopt(argc, argv, "n:b:l:")) != -1) {
		switch (ch) {
		case 'n': name = optarg; break;
		case 'b': baud = strtoul(optarg, NULL, 0); break;
		case 'l': listen_s = atoi(optarg); break;
		default:
			fprintf(stderr, "usage: hcitest [-n ctlname] [-b baud] [-l seconds]\n");
			return 2;
		}
	}
	int fd = socket(32 /* PF_SYSTEM */, SOCK_STREAM, SYSPROTO_CONTROL);
	if (fd < 0) {
		perror("socket(PF_SYSTEM, SOCK_STREAM, SYSPROTO_CONTROL)");
		return 1;
	}
	struct ctl_info info;
	memset(&info, 0, sizeof(info));
	strlcpy(info.ctl_name, name, sizeof(info.ctl_name));
	if (ioctl(fd, CTLIOCGINFO, &info) < 0) {
		fprintf(stderr, "CTLIOCGINFO %s: %s (is sweetbt=1 up? look for 'SWEET BT: transport up' in the kernel log)\n",
		    name, strerror(errno));
		return 1;
	}
	struct sockaddr_ctl sc;
	memset(&sc, 0, sizeof(sc));
	sc.sc_len = sizeof(sc);
	sc.sc_family = 32 /* AF_SYSTEM */;
	sc.ss_sysaddr = AF_SYS_CONTROL;
	sc.sc_id = info.ctl_id;
	sc.sc_unit = 0;
	if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) {
		fprintf(stderr, "connect %s (id %u): %s%s\n", name, info.ctl_id, strerror(errno),
		    errno == EBUSY ? " (another client is connected: stop bluetoothd)" : "");
		return 1;
	}
	printf("connected to %s (ctl id %u)\n", name, info.ctl_id);

	struct termios t;
	socklen_t tl = sizeof(t);
	if (getsockopt(fd, SYSPROTO_CONTROL, 0x40487413 /* TIOCGETA */, &t, &tl) < 0) {
		printf("TIOCGETA: %s\n", strerror(errno));
	} else {
		printf("TIOCGETA: %u bytes, cflag %#lx, speed %lu/%lu\n", tl, t.c_cflag, t.c_ispeed, t.c_ospeed);
	}
	/* what bluetoothd does for mode 0: cfmakeraw, cfsetspeed, c_iflag |= 4, c_cflag = 0x38B00 */
	cfmakeraw(&t);
	cfsetspeed(&t, baud);
	t.c_iflag |= 4;
	t.c_cflag = 0x38B00;
	if (setsockopt(fd, SYSPROTO_CONTROL, 0x80487414 /* TIOCSETA */, &t, sizeof(t)) < 0) {
		printf("TIOCSETA %lu baud: %s\n", baud, strerror(errno));
	} else {
		printf("TIOCSETA %lu baud ok\n", baud);
	}
	tl = sizeof(t);
	if (getsockopt(fd, SYSPROTO_CONTROL, 0x40487413, &t, &tl) == 0) {
		printf("TIOCGETA after set: speed %lu/%lu cflag %#lx\n", t.c_ispeed, t.c_ospeed, t.c_cflag);
	}

	int bad = 0;
	uint8_t r[64];
	unsigned rl = 0;

	if (command(fd, 0x0c03, NULL, 0, NULL, NULL) != 0) {                    /* Reset */
		bad++;
	}
	if (command(fd, 0x1001, NULL, 0, r, &rl) != 0 || rl < 9) {               /* Read_Local_Version_Information */
		bad++;
	} else {
		printf("  HCI version %u revision %#06x, LMP version %u, manufacturer %#06x, LMP subversion %#06x\n",
		    r[1], r[2] | (r[3] << 8), r[4], r[5] | (r[6] << 8), r[7] | (r[8] << 8));
	}
	if (command(fd, 0x1009, NULL, 0, r, &rl) != 0 || rl < 7) {               /* Read_BD_ADDR */
		bad++;
	} else {
		printf("  BD_ADDR %02x:%02x:%02x:%02x:%02x:%02x\n", r[6], r[5], r[4], r[3], r[2], r[1]);
	}
	if (listen_s > 0) {
		printf("listening for %d s\n", listen_s);
		double end = now() + listen_s;
		unsigned n;
		while (get_packet(fd, end, &n)) {
			hex("RX", rxb, n);
			drop(n);
		}
	}
	printf("%s\n", bad ? "FAILED" : "all commands completed with status 0");
	close(fd);
	return bad ? 1 : 0;
}
