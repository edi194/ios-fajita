/*
 * Polled DWC3 device-mode driver for the Poco F1 (SDM845) fastboot gadget.
 *
 * Everything here runs with the MMU off, so all memory is Device-nGnRnE:
 * CPU writes reach DRAM directly and the controller's DMA needs no
 * cache maintenance, except for dirty lines ABL may have left behind in
 * memory we are about to DMA into (cache_ci / cache_inv below). Accesses are
 * aligned and no libc is used (-mstrict-align, no memcpy).
 *
 * The bring-up order is the one that finally enumerated in xnu
 * (xnu/patches 0072..0109, sweet_usb.c "sweetusbfix=7"): ABL leaves the
 * QUSB2 PHY powered down after `fastboot boot` (PWR_CTRL1.POWER_DOWN set),
 * so a plain "take over the halted controller" times out in the first
 * SETEPCONFIG. Sequence: PIPE clock from the UTMI clock, QUSB2 power-up, Linux
 * core + PHY soft reset, DCTL soft reset, restore ABL's GCTL (RAMCLKSEL),
 * HS-only quirks, GUCTL1 bit 26, apps_smmu stream 0x740 -> identity
 * context bank, event buffer, ep0, VBUS override, RUN_STOP.
 */
#include <stdint.h>
#include "board.h"
#include "usb_dwc3.h"

#define GCC_BASE		0x00100000UL
#define GCC_USB30_PRIM_GDSCR	0x0f004
#define CBCR_CLK_OFF		(1u << 31)

static const uint32_t usb_cbcr[] = {
	0x0f010,	/* [0] master */
	0x0f014,	/* sleep */
	0x0f018,	/* utmi */
	0x0502c,	/* [3] cfg-noc-axi */
	0x8201c,	/* aggre-axi */
	0x6a004,	/* [5] ahb2phy */
	0x8c010,	/* clkref */
};
#define N_CBCR		(sizeof usb_cbcr / sizeof usb_cbcr[0])

#define DWC3_BASE	0x0a600000UL
#define QUSB2_BASE	0x088e2000UL
#define QUSB2_PWR_CTRL1	0x210
#define QUSB2_PLL_STATUS 0x1a0
#define QUSB2_PWR_DOWN	0x01u
#define QUSB2_CLAMP_N_EN 0x02u
#define QUSB2_PLL_LOCKED 0x20u
/* Qualcomm wrapper ("QSCRATCH") */
#define QSCRATCH_BASE		0x0a6f8800UL
#define QS_GENERAL_CFG		0x08
#define QS_HS_PHY_CTRL		0x10
#define   UTMI_OTG_VBUS_VALID	(1u << 20)
#define   SW_SESSVLD_SEL	(1u << 28)
#define QS_SS_PHY_CTRL		0x30
#define   LANE0_PWR_PRESENT	(1u << 24)

#define GCTL		0xc110
#define GUCTL1		0xc11c
#define GSTS		0xc118
#define GSNPSID		0xc120
#define GUSB2PHYCFG	0xc200
#define GUSB3PIPECTL	0xc2c0
#define GEVNTADRLO	0xc400
#define GEVNTADRHI	0xc404
#define GEVNTSIZ	0xc408
#define GEVNTCOUNT	0xc40c
#define DCFG		0xc700
#define DCTL		0xc704
#define DEVTEN		0xc708
#define DSTS		0xc70c
#define DALEPENA	0xc720
#define DEPCMDPAR2(n)	(0xc800 + 0x10 * (n))
#define DEPCMDPAR1(n)	(0xc804 + 0x10 * (n))
#define DEPCMDPAR0(n)	(0xc808 + 0x10 * (n))
#define DEPCMD(n)	(0xc80c + 0x10 * (n))

#define GCTL_CORESOFTRESET	(1u << 11)
#define GUSBPHYCFG_PHYSOFTRST	(1u << 31)
#define DCTL_RUN_STOP		(1u << 31)
#define DCTL_CSFTRST		(1u << 30)
#define DSTS_DEVCTRLHLT		(1u << 22)

#define DEPCMD_SETEPCONFIG	1
#define DEPCMD_SETTRANSFRESOURCE 2
#define DEPCMD_SETSTALL		4
#define DEPCMD_CLEARSTALL	5
#define DEPCMD_STARTTRANSFER	6
#define DEPCMD_ENDTRANSFER	8
#define DEPCMD_FORCERM		(1u << 11)
#define DEPCMD_DEPSTARTCFG	9
#define DEPCMD_CMDACT		(1u << 10)

#define TRB_HWO		(1u << 0)
#define TRB_LST		(1u << 1)
#define TRB_ISP_IMI	(1u << 10)
#define TRB_IOC		(1u << 11)
#define TRBCTL_NORMAL	(1u << 4)
#define TRBCTL_SETUP	(2u << 4)
#define TRBCTL_STATUS2	(3u << 4)
#define TRBCTL_STATUS3	(4u << 4)
#define TRBCTL_DATA	(5u << 4)

/* Physical endpoints: 2n = OUT, 2n+1 = IN */
#define EP_RX		2	/* 0x01 bulk OUT */
#define EP_TX		3	/* 0x81 bulk IN */
#define N_EP		4

/* DMA area (inside our image, 4 KiB aligned at run time) */
#define UD_EVT		0x0000	/* event buffer */
#define UD_EVT_SIZE	0x1000
#define UD_TRB_OUT	0x1000	/* ep0 OUT */
#define UD_TRB_IN	0x1010	/* ep0 IN */
#define UD_TRB_RX	0x1020	/* ep1 OUT */
#define UD_TRB_TX	0x1030	/* ep1 IN */
#define UD_SETUP	0x1040
#define UD_DATA		0x1100	/* ep0 data stage, 512 bytes */
#define UD_CMD		0x1400	/* received command packet, 512 bytes */
#define UD_TXB		0x1600	/* response packet, 256 bytes */
#define UD_SIZE		0x2000
#define CMD_MAX		512u
#define TXB_MAX		256u

#define DL_TRB_MAX	0x800000u	/* one TRB: < 16 MiB, multiple of 512 */

struct usb_dwc3_info usb_info;

static uint8_t dma_raw[UD_SIZE + 4096] __attribute__((aligned(16)));
static uint64_t l1_raw[2 * 512] __attribute__((aligned(16)));

static struct {
	uintptr_t dma;
	uint32_t evt_pos;
	enum usb_state state;
	enum { EP0_SETUP, EP0_DATA, EP0_WAIT_STATUS2, EP0_WAIT_STATUS3, EP0_STATUS } ep0;
	int data_in;
	uint8_t active[N_EP];
	uint8_t res[N_EP];
	uint32_t link_gen;	/* bumped on every bus reset / disconnect */
	uint32_t cmd_gen_seen;
	int rx_armed, rx_done, tx_done;
	uint32_t rx_resid;
	uint32_t qs_hs_saved, qs_ss_saved;
	int qs_saved;
	int touched;		/* usb_dwc3_init got as far as programming the controller */
} ud;

static inline uint32_t rd(uint32_t off)
{
	uint32_t v = *(volatile uint32_t *)(DWC3_BASE + off);
	__asm__ volatile("dmb sy" ::: "memory");
	return v;
}

static inline void wr(uint32_t off, uint32_t v)
{
	*(volatile uint32_t *)(DWC3_BASE + off) = v;
	__asm__ volatile("dsb sy" ::: "memory");
}

static inline uint32_t rd_at(uintptr_t a)
{
	uint32_t v = *(volatile uint32_t *)a;
	__asm__ volatile("dmb sy" ::: "memory");
	return v;
}

static inline void wr_at(uintptr_t a, uint32_t v)
{
	*(volatile uint32_t *)a = v;
	__asm__ volatile("dsb sy" ::: "memory");
}

static uint64_t ticks(void)
{
	uint64_t t;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t) : : "memory");
	return t;
}

static uint64_t ticks_per_us(void)
{
	uint64_t f;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	return f / 1000000 ? f / 1000000 : 1;
}

static void udelay(unsigned us)
{
	uint64_t end = ticks() + ticks_per_us() * us;
	while (ticks() < end)
		;
}

/* Clean+invalidate / invalidate by address; works with the MMU off (PA == VA). */
static void cache_ci(uintptr_t a, uint64_t n)
{
	uint64_t ctr;
	__asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
	uint64_t line = 4UL << ((ctr >> 16) & 0xf);
	for (uintptr_t p = a & ~(line - 1); p < a + n; p += line)
		__asm__ volatile("dc civac, %0" : : "r"(p) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

static void cache_inv(uintptr_t a, uint64_t n)
{
	uint64_t ctr;
	__asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
	uint64_t line = 4UL << ((ctr >> 16) & 0xf);
	for (uintptr_t p = a & ~(line - 1); p < a + n; p += line)
		__asm__ volatile("dc ivac, %0" : : "r"(p) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

static void zero(uintptr_t a, unsigned n)
{
	volatile uint8_t *b = (volatile uint8_t *)a;
	for (unsigned i = 0; i < n; i++)
		b[i] = 0;
}

static void note(void)
{
	usb_info.change++;
}

/* ---- apps_smmu: stream 0x740 -> identity-mapped stage-1 bank (xnu sweet_smmu.c) ---- */

#define SMMU_BASE	0x15000000UL
#define SMMU_SID	0x740u

static struct {
	int cb;			/* our context bank, -1 none */
	int smr;		/* SMR index we touched, -1 none */
	int matched;		/* 1: retargeted an existing exact SMR, 0: took a free one */
	uint32_t old_smr, old_s2cr;
	uintptr_t cbx;		/* context-bank register page */
} sm = { -1, -1, 0, 0, 0, 0 };

static uint32_t smmu_rd(uint32_t off)
{
	uint32_t v = *(volatile uint32_t *)(SMMU_BASE + off);
	__asm__ volatile("dmb oshld" ::: "memory");
	return v;
}

static void smmu_wr(uint32_t off, uint32_t v)
{
	__asm__ volatile("dmb oshst" ::: "memory");
	*(volatile uint32_t *)(SMMU_BASE + off) = v;
	__asm__ volatile("dsb osh" ::: "memory");
}

static void smmu_wr64(uint32_t off, uint64_t v)
{
	__asm__ volatile("dmb oshst" ::: "memory");
	*(volatile uint64_t *)(SMMU_BASE + off) = v;
	__asm__ volatile("dsb osh" ::: "memory");
}

/* Returns 0 or a negative reason (-1 no bank, -2 SMR trouble, -3 refused). */
static int smmu_map(void)
{
	uint32_t id0 = smmu_rd(0x20), id1 = smmu_rd(0x24);
	unsigned pgshift = (id1 >> 31) ? 16 : 12;
	unsigned ncb = id1 & 0xff, ns2cb = (id1 >> 16) & 0xff;
	uint32_t gr1 = 1u << pgshift;
	uint32_t cb0 = (1u << (((id1 >> 28) & 7) + 1)) << pgshift;
	unsigned nsmr = id0 & 0xff;
	uint32_t used[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };

	if (nsmr > 128)
		nsmr = 128;
	for (unsigned i = 0; i < nsmr; i++) {
		uint32_t smr = smmu_rd(0x800 + 4 * i), s2cr = smmu_rd(0xc00 + 4 * i);
		if ((smr & (1u << 31)) && ((s2cr >> 16) & 3) == 0 && (s2cr & 0xff) < 256)
			used[(s2cr & 0xff) / 32] |= 1u << ((s2cr & 0xff) % 32);
	}
	for (unsigned c = ns2cb; c < ncb && sm.cb < 0 && c < 256; c++)
		if (!(used[c / 32] & (1u << (c % 32))) && !(smmu_rd(cb0 + (c << pgshift)) & 1))
			sm.cb = (int)c;
	if (sm.cb < 0)
		return -1;

	/* Level-1 table: DRAM 0x80000000..0x27fffffff in 1 GiB blocks, Normal NC, RW. */
	volatile uint64_t *l1 = (volatile uint64_t *)(((uintptr_t)l1_raw + 4095) & ~4095UL);
	for (unsigned i = 0; i < 512; i++)
		l1[i] = 0;
	for (unsigned i = 2; i < 10; i++)
		l1[i] = (uint64_t)i << 30 | 1u << 10 | 2u << 8 | 1u << 6 | 1;
	cache_ci((uintptr_t)l1, 4096);
	uint64_t l1_pa = (uintptr_t)l1;

	uint32_t cb = cb0 + ((uint32_t)sm.cb << pgshift);
	unsigned asid = (unsigned)sm.cb;
	smmu_wr(cb + 0x0, 0);					/* SCTLR off while programming */
	smmu_wr(cb + 0x58, 0xffffffffu);			/* FSR clear */
	smmu_wr(gr1 + 0x800 + 4 * (unsigned)sm.cb, 1);		/* CBA2R: VA64 */
	smmu_wr(gr1 + 4 * (unsigned)sm.cb, 1u << 16 | 0xfu << 12 | 3u << 8); /* CBAR: S1+S2 bypass, WB, NSH */
	smmu_wr(cb + 0x10, 7u << 15 | 2);			/* TCR2 */
	smmu_wr(cb + 0x30, 25 | 1u << 23);			/* TCR: T0SZ 25, 4K, NC walks, EPD1 */
	smmu_wr(cb + 0x34, asid);				/* CONTEXTIDR */
	smmu_wr64(cb + 0x20, l1_pa | (uint64_t)asid << 48);	/* TTBR0 */
	smmu_wr64(cb + 0x28, 0);
	smmu_wr(cb + 0x38, 0x44);				/* MAIR0: Normal NC */
	smmu_wr(cb + 0x618, 0);					/* TLBIALL */
	smmu_wr(cb + 0x7f0, 0);					/* TLBSYNC */
	for (int t = 0; t < 100000 && (smmu_rd(cb + 0x7f4) & 1); t++)
		udelay(1);
	smmu_wr(cb + 0x0, 1u << 6 | 1u << 5 | 1u << 2 | 1u << 1 | 1);	/* CFIE CFRE AFE TRE M */
	if (!(smmu_rd(cb + 0x0) & 1))
		return -3;
	sm.cbx = SMMU_BASE + cb;

	/* An SMR may already match the stream (ABL used the controller for fastboot). */
	int free_smr = -1, match = -1;
	for (unsigned i = 0; i < nsmr; i++) {
		uint32_t smr = smmu_rd(0x800 + 4 * i);
		if (!(smr & (1u << 31))) {
			if (free_smr < 0)
				free_smr = (int)i;
			continue;
		}
		uint32_t mask = (smr >> 16) & 0x7fff;
		if (((smr ^ SMMU_SID) & ~mask & 0x7fff) == 0 && match < 0)
			match = (int)i;
	}
	if (match >= 0) {
		uint32_t smr = smmu_rd(0x800 + 4 * (unsigned)match);
		uint32_t s2cr = smmu_rd(0xc00 + 4 * (unsigned)match);
		if ((smr >> 16) & 0x7fff) {	/* masked entry also covers other streams: leave it */
			usb_info.smmu_info = (uint32_t)match << 24 | (s2cr & 0xffffff);
			return -2;
		}
		sm.smr = match;
		sm.matched = 1;
		sm.old_smr = smr;
		sm.old_s2cr = s2cr;
		smmu_wr(0xc00 + 4 * (unsigned)match, (uint32_t)sm.cb);
	} else {
		if (free_smr < 0)
			return -2;
		sm.smr = free_smr;
		sm.matched = 0;
		sm.old_smr = smmu_rd(0x800 + 4 * (unsigned)free_smr);
		sm.old_s2cr = smmu_rd(0xc00 + 4 * (unsigned)free_smr);
		smmu_wr(0xc00 + 4 * (unsigned)free_smr, (uint32_t)sm.cb);
		smmu_wr(0x800 + 4 * (unsigned)free_smr, 1u << 31 | SMMU_SID);
	}
	uint32_t s2cr = smmu_rd(0xc00 + 4 * (unsigned)sm.smr);
	usb_info.smmu_info = (uint32_t)sm.smr << 24 | (s2cr & 0xffffff);
	if (((s2cr >> 16) & 3) != 0 || (s2cr & 0xff) != (uint32_t)sm.cb)
		return -3;
	return 0;
}

static void smmu_unmap(void)
{
	if (sm.smr >= 0) {
		if (sm.matched) {
			smmu_wr(0xc00 + 4 * (unsigned)sm.smr, sm.old_s2cr);
		} else {
			smmu_wr(0x800 + 4 * (unsigned)sm.smr, sm.old_smr);	/* invalid again */
			smmu_wr(0xc00 + 4 * (unsigned)sm.smr, sm.old_s2cr);
		}
		sm.smr = -1;
	}
	if (sm.cbx) {
		*(volatile uint32_t *)sm.cbx = 0;			/* SCTLR: bank off, free again */
		__asm__ volatile("dsb osh" ::: "memory");
		sm.cbx = 0;
	}
	sm.cb = -1;
}

/* ---- endpoint commands, TRBs ---- */

static int ud_epcmd(unsigned ep, uint32_t cmd, uint32_t p0, uint32_t p1, uint32_t p2)
{
	wr(DEPCMDPAR0(ep), p0);
	wr(DEPCMDPAR1(ep), p1);
	wr(DEPCMDPAR2(ep), p2);
	wr(DEPCMD(ep), cmd | DEPCMD_CMDACT);
	for (int i = 0; i < 50000; i++) {	/* 50 ms: DWC3 3.00a can be slow */
		uint32_t v = rd(DEPCMD(ep));
		if (!(v & DEPCMD_CMDACT))
			return ((v >> 12) & 0xf) ? -1 : 0;
		udelay(1);
	}
	return -2;
}

static void trb_set(uintptr_t trb, uint64_t buf, uint32_t len, uint32_t ctl)
{
	volatile uint32_t *t = (volatile uint32_t *)trb;
	t[0] = (uint32_t)buf;
	t[1] = (uint32_t)(buf >> 32);
	t[2] = len;
	t[3] = ctl | TRB_HWO | TRB_LST | TRB_ISP_IMI | TRB_IOC;
	__asm__ volatile("dsb sy" ::: "memory");
}

static int ud_start_trb(unsigned ep, uint32_t trb_off, uint64_t buf, uint32_t len, uint32_t ctl)
{
	uintptr_t trb = ud.dma + trb_off;
	trb_set(trb, buf, len, ctl);
	int rc = ud_epcmd(ep, DEPCMD_STARTTRANSFER, (uint32_t)(trb >> 32), (uint32_t)trb, 0);
	if (rc == 0) {
		ud.res[ep] = (uint8_t)((rd(DEPCMD(ep)) >> 16) & 0x7f);
		ud.active[ep] = 1;
	}
	return rc;
}

static void ud_end_transfer(unsigned ep)
{
	if (ud.active[ep]) {
		ud_epcmd(ep, DEPCMD_ENDTRANSFER | DEPCMD_FORCERM | ((uint32_t)ud.res[ep] << 16), 0, 0, 0);
		ud.active[ep] = 0;
	}
}

static void ud_start_setup(void)
{
	ud.ep0 = EP0_SETUP;
	ud_start_trb(0, UD_TRB_OUT, ud.dma + UD_SETUP, 8, TRBCTL_SETUP);
}

static void ud_stall(void)
{
	ud_epcmd(0, DEPCMD_SETSTALL, 0, 0, 0);
	ud_start_setup();
}

/* ---- descriptors: VID 0x18d1 PID 0x4ee0, fastboot interface ff/42/03, bulk 0x81/0x01 ---- */

static const uint8_t dev_desc[18] = {
	18, 1, 0x00, 0x02, 0x00, 0x00, 0x00, 64,
	0xd1, 0x18, 0xe0, 0x4e, 0x00, 0x01, 1, 2, 3, 1,
};
static const uint8_t dev_qual[10] = { 10, 6, 0x00, 0x02, 0, 0, 0, 64, 1, 0 };
static const uint8_t cfg_desc[32] = {
	9, 2, 32, 0, 1, 1, 0, 0x80, 250,
	9, 4, 0, 0, 2, 0xff, 0x42, 0x03, 0,
	7, 5, 0x81, 0x02, 0x00, 0x02, 0,
	7, 5, 0x01, 0x02, 0x00, 0x02, 0,
};
static const char str_mfr[] = "Bergamota";
static const char str_prod[] = "Bergamota fastboot";
static const char str_ser[] = "bergamota0001";

static unsigned ud_string(unsigned idx, volatile uint8_t *out)
{
	const char *s;
	if (idx == 0) {
		out[0] = 4; out[1] = 3; out[2] = 0x09; out[3] = 0x04;	/* en-US */
		return 4;
	}
	s = idx == 1 ? str_mfr : idx == 2 ? str_prod : idx == 3 ? str_ser : 0;
	if (!s)
		return 0;
	unsigned n = 2;
	for (; *s && n < 126; s++) {
		out[n++] = (uint8_t)*s;
		out[n++] = 0;
	}
	out[0] = (uint8_t)n;
	out[1] = 3;
	return n;
}

static unsigned put_desc(volatile uint8_t *out, const uint8_t *d, unsigned n)
{
	for (unsigned i = 0; i < n; i++)
		out[i] = d[i];
	return n;
}

static void ud_rx_disarm(void)
{
	ud_end_transfer(EP_RX);
	ud.rx_armed = 0;
	ud.rx_done = 0;
}

static void ud_configure(void)
{
	if (ud.state == USB_ST_CONFIGURED)
		return;
	if (ud_epcmd(0, DEPCMD_DEPSTARTCFG | (2u << 16), 0, 0, 0) ||
	    ud_epcmd(EP_RX, DEPCMD_SETEPCONFIG, (2u << 1) | (512u << 3), (1u << 8) | ((uint32_t)EP_RX << 25), 0) ||
	    ud_epcmd(EP_RX, DEPCMD_SETTRANSFRESOURCE, 1, 0, 0) ||
	    ud_epcmd(EP_TX, DEPCMD_SETEPCONFIG, (2u << 1) | (512u << 3) | (1u << 17), (1u << 8) | ((uint32_t)EP_TX << 25), 0) ||
	    ud_epcmd(EP_TX, DEPCMD_SETTRANSFRESOURCE, 1, 0, 0))
		return;
	wr(DALEPENA, rd(DALEPENA) | (1u << EP_RX) | (1u << EP_TX));
	ud.state = USB_ST_CONFIGURED;
	ud.rx_armed = ud.rx_done = ud.tx_done = 0;
	note();
}

static void ud_setup(void)
{
	volatile uint8_t *st = (volatile uint8_t *)(ud.dma + UD_SETUP);
	volatile uint8_t *data = (volatile uint8_t *)(ud.dma + UD_DATA);
	uint8_t type = st[0], req = st[1];
	uint16_t value = (uint16_t)(st[2] | st[3] << 8);
	uint16_t index = (uint16_t)(st[4] | st[5] << 8);
	uint16_t length = (uint16_t)(st[6] | st[7] << 8);
	unsigned n = 0;
	int ok = 1;

	for (int i = 0; i < 8; i++)
		usb_info.last_setup[i] = st[i];
	usb_info.setups++;
	note();
	ud.data_in = (type & 0x80) != 0;
	if ((type & 0x60) != 0) {		/* no class / vendor requests */
		ok = 0;
	} else if (req == 6) {			/* GET_DESCRIPTOR */
		switch (value >> 8) {
		case 1: n = put_desc(data, dev_desc, sizeof dev_desc); break;
		case 2: n = put_desc(data, cfg_desc, sizeof cfg_desc); break;
		case 3: n = ud_string(value & 0xff, data); ok = n != 0; break;
		case 6: n = put_desc(data, dev_qual, sizeof dev_qual); break;
		default: ok = 0; break;
		}
	} else if (req == 5) {			/* SET_ADDRESS: DWC3 applies it after the status stage */
		uint32_t dcfg = rd(DCFG) & ~(0x7fu << 3);
		wr(DCFG, dcfg | ((uint32_t)(value & 0x7f) << 3));
		if (ud.state < USB_ST_ADDRESSED)
			ud.state = USB_ST_ADDRESSED;
		note();
	} else if (req == 9) {			/* SET_CONFIGURATION */
		if (value == 1)
			ud_configure();
		else
			ok = value == 0;
	} else if (req == 8) {			/* GET_CONFIGURATION */
		data[0] = ud.state == USB_ST_CONFIGURED ? 1 : 0;
		n = 1;
	} else if (req == 0) {			/* GET_STATUS */
		data[0] = 0; data[1] = 0;
		n = 2;
	} else if (req == 11) {			/* SET_INTERFACE: alt 0 only */
		ok = value == 0;
	} else if (req == 10) {			/* GET_INTERFACE */
		data[0] = 0;
		n = 1;
	} else if (req == 1 || req == 3) {	/* CLEAR/SET_FEATURE */
		if (type == 0x02 && value == 0) {	/* ENDPOINT_HALT: reset the data toggle */
			unsigned ep = ((index & 0xf) << 1) | ((index >> 7) & 1);
			if (ep == EP_RX || ep == EP_TX)
				ud_epcmd(ep, req == 1 ? DEPCMD_CLEARSTALL : DEPCMD_SETSTALL, 0, 0, 0);
		}
	} else {
		ok = 0;
	}
	if (!ok) {
		ud_stall();
		return;
	}
	if (length == 0) {
		ud.ep0 = EP0_WAIT_STATUS2;	/* status stage on XferNotReady */
		return;
	}
	ud.ep0 = EP0_DATA;
	if (ud.data_in) {
		if (n > length)
			n = length;
		ud_start_trb(1, UD_TRB_IN, ud.dma + UD_DATA, n, TRBCTL_DATA);
	} else {
		ud_start_trb(0, UD_TRB_OUT, ud.dma + UD_DATA, 64, TRBCTL_DATA);	/* OUT data stages are not used */
	}
}

/* Host reset / unplug: drop every transfer, ep0 back to SETUP, tell the waiters. */
static void ud_bus_reset(void)
{
	ud_end_transfer(EP_RX);
	ud_end_transfer(EP_TX);
	if (ud.state == USB_ST_CONFIGURED) {	/* data endpoints exist only after SET_CONFIGURATION */
		ud_epcmd(EP_RX, DEPCMD_CLEARSTALL, 0, 0, 0);
		ud_epcmd(EP_TX, DEPCMD_CLEARSTALL, 0, 0, 0);
		wr(DALEPENA, rd(DALEPENA) & 3u);
	}
	if (ud.active[1])
		ud_end_transfer(1);
	if (ud.ep0 != EP0_SETUP || !ud.active[0]) {
		ud_end_transfer(0);
		ud_start_setup();
	}
	ud.rx_armed = ud.rx_done = ud.tx_done = 0;
	ud.state = USB_ST_RESET;
	ud.link_gen++;
	usb_info.resets++;
	note();
}

static void ud_event(uint32_t ev)
{
	usb_info.events++;
	usb_info.last_event = ev;
	if (ev & 1) {				/* device event */
		uint32_t type = (ev >> 8) & 0xf;
		if (type == 1) {		/* USB reset */
			wr(DCFG, rd(DCFG) & ~(0x7fu << 3));
			ud_bus_reset();
		} else if (type == 2) {		/* connect done */
			usb_info.speed = (int)(rd(DSTS) & 7);
			/* ep0 max packet 64 at high/full speed (modify action) */
			ud_epcmd(0, DEPCMD_SETEPCONFIG, (0u << 1) | (64u << 3) | (2u << 30),
				 (1u << 8) | (1u << 10) | (0u << 25), 0);
			ud_epcmd(1, DEPCMD_SETEPCONFIG, (0u << 1) | (64u << 3) | (2u << 30),
				 (1u << 8) | (1u << 10) | (1u << 25), 0);
			if (ud.state < USB_ST_RESET)
				ud.state = USB_ST_RESET;
			note();
		} else if (type == 0) {		/* disconnect */
			ud_bus_reset();
			ud.state = USB_ST_RUNNING;
			note();
		}
		return;
	}
	unsigned ep = (ev >> 1) & 0x1f;
	unsigned type = (ev >> 6) & 0xf;
	unsigned status = (ev >> 12) & 0xf;

	if (type == 1 && ep < N_EP)
		ud.active[ep] = 0;		/* XferComplete: the single TRB is done */
	if (ep == EP_RX && type == 1) {
		ud.rx_resid = rd_at(ud.dma + UD_TRB_RX + 8) & 0xffffff;
		ud.rx_done = 1;
		return;
	}
	if (ep == EP_TX && type == 1) {
		ud.tx_done = 1;
		return;
	}
	if (ep > 1)
		return;
	/* Control transfers, as Linux dwc3 ep0.c: status stage starts on XferNotReady(status). */
	if (type == 1) {
		switch (ud.ep0) {
		case EP0_SETUP:
			ud_setup();
			break;
		case EP0_DATA:
			ud.ep0 = EP0_WAIT_STATUS3;
			break;
		case EP0_STATUS:
			ud_start_setup();
			break;
		default:
			break;
		}
		return;
	}
	if (type == 3 && status == 2 && (ud.ep0 == EP0_WAIT_STATUS2 || ud.ep0 == EP0_WAIT_STATUS3)) {
		uint32_t ctl = ud.ep0 == EP0_WAIT_STATUS3 ? TRBCTL_STATUS3 : TRBCTL_STATUS2;
		ud.ep0 = EP0_STATUS;
		ud_start_trb(ep, ep ? UD_TRB_IN : UD_TRB_OUT, ud.dma + UD_DATA, 0, ctl);
	}
}

void usb_dwc3_poll(void)
{
	if (ud.state == USB_ST_DOWN)
		return;
	uint32_t count = rd(GEVNTCOUNT) & 0xffff;
	if (!count)
		return;
	for (uint32_t done = 0; done < count; done += 4) {
		uint32_t ev = rd_at(ud.dma + UD_EVT + ud.evt_pos);
		ud.evt_pos = (ud.evt_pos + 4) % UD_EVT_SIZE;
		ud_event(ev);
	}
	wr(GEVNTCOUNT, count);
}

enum usb_state usb_dwc3_state(void)
{
	return ud.state;
}

/* ---- bring-up ---- */

/* no lookup table of string pointers (ABS64 relocations): keep this a real switch */
__attribute__((optimize("no-tree-switch-conversion")))
const char *usb_dwc3_errstr(int err)
{
	switch (err) {
	case USB_E_CLOCKS: return "USB GDSC/clocks off";
	case USB_E_ID: return "no DWC3 at 0xA600000";
	case USB_E_RESET: return "DCTL soft reset stuck";
	case USB_E_EP0: return "ep0 command failed";
	case USB_E_RUN: return "controller will not run";
	default: return "?";
	}
}

static int clocks_ok(void)
{
	uint32_t gdscr = rd_at(GCC_BASE + GCC_USB30_PRIM_GDSCR);
	return (gdscr & (1u << 31)) && !(rd_at(GCC_BASE + usb_cbcr[0]) & CBCR_CLK_OFF) &&
	       !(rd_at(GCC_BASE + usb_cbcr[3]) & CBCR_CLK_OFF);
}

/* The DWC3 block hangs the bus when unpowered: never touch it unless GCC says it is on. */
static int ensure_clocks(void)
{
	if (clocks_ok())
		return 0;
	/* Best effort (not needed after ABL's `fastboot boot` on every boot seen so far): power domain, branches. */
	uint32_t gdscr = rd_at(GCC_BASE + GCC_USB30_PRIM_GDSCR);
	wr_at(GCC_BASE + GCC_USB30_PRIM_GDSCR, gdscr & ~1u);	/* clear SW_COLLAPSE */
	for (int i = 0; i < 1000 && !(rd_at(GCC_BASE + GCC_USB30_PRIM_GDSCR) & (1u << 31)); i++)
		udelay(10);
	for (unsigned i = 0; i < N_CBCR; i++) {
		uint32_t v = rd_at(GCC_BASE + usb_cbcr[i]);
		if (v & CBCR_CLK_OFF) {
			wr_at(GCC_BASE + usb_cbcr[i], v | 1u);
			for (int t = 0; t < 1000 && (rd_at(GCC_BASE + usb_cbcr[i]) & CBCR_CLK_OFF); t++)
				udelay(10);
		}
	}
	return clocks_ok() ? 0 : USB_E_CLOCKS;
}

int usb_dwc3_init(int use_smmu)
{
	int rc = ensure_clocks();
	if (rc)
		return rc;
	if ((rd(GSNPSID) >> 16) != 0x5533)
		return USB_E_ID;
	usb_info.gsnpsid = rd(GSNPSID);
	ud.touched = 1;

	ud.dma = ((uintptr_t)dma_raw + 4095) & ~4095UL;
	zero(ud.dma, UD_SIZE);
	cache_ci(ud.dma, UD_SIZE);
	ud.state = USB_ST_DOWN;
	ud.evt_pos = 0;
	ud.link_gen = 0;
	ud.cmd_gen_seen = 0;
	for (int i = 0; i < N_EP; i++)
		ud.active[i] = 0;
	ud.rx_armed = ud.rx_done = ud.tx_done = 0;
	note();

	/* 1. PIPE side from the UTMI clock (dwc3_qcom_select_utmi_clk) */
	uintptr_t cfg = QSCRATCH_BASE + QS_GENERAL_CFG;
	wr_at(cfg, rd_at(cfg) | (1u << 8));			/* PIPE_UTMI_CLK_DIS */
	udelay(1000);
	wr_at(cfg, rd_at(cfg) | (1u << 0) | (1u << 3));		/* PIPE_UTMI_CLK_SEL | PIPE3_PHYSTATUS_SW */
	udelay(1000);
	wr_at(cfg, rd_at(cfg) & ~(1u << 8));
	udelay(1000);
	usb_info.qscratch_gen_cfg = rd_at(cfg);

	/* 2. QUSB2 PHY power-up: ABL leaves PWR_CTRL1.POWER_DOWN set (the sweetusbfix finding). */
	uint32_t pwr = rd_at(QUSB2_BASE + QUSB2_PWR_CTRL1) & 0xff;
	usb_info.qusb_pwr_before = pwr;
	if (pwr & QUSB2_PWR_DOWN) {
		wr_at(QUSB2_BASE + QUSB2_PWR_CTRL1, (pwr & ~QUSB2_PWR_DOWN) | QUSB2_CLAMP_N_EN);
		udelay(250);
	}
	for (int i = 0; i < 1000 && !(rd_at(QUSB2_BASE + QUSB2_PLL_STATUS) & QUSB2_PLL_LOCKED); i++)
		udelay(1);
	usb_info.qusb_pwr_after = rd_at(QUSB2_BASE + QUSB2_PWR_CTRL1) & 0xff;
	usb_info.qusb_pll_after = rd_at(QUSB2_BASE + QUSB2_PLL_STATUS) & 0xff;

	/* 3. Linux dwc3_core_soft_reset() without the PHY framework, then DCTL.CSFTRST */
	uint32_t gctl_abl = rd(GCTL);
	usb_info.gctl_abl = gctl_abl;
	uint32_t u3 = rd(GUSB3PIPECTL), u2 = rd(GUSB2PHYCFG);
	wr(GCTL, gctl_abl | GCTL_CORESOFTRESET);
	wr(GUSB3PIPECTL, u3 | GUSBPHYCFG_PHYSOFTRST);
	wr(GUSB2PHYCFG, u2 | GUSBPHYCFG_PHYSOFTRST);
	udelay(1000);
	wr(GUSB3PIPECTL, u3 & ~GUSBPHYCFG_PHYSOFTRST);
	wr(GUSB2PHYCFG, u2 & ~GUSBPHYCFG_PHYSOFTRST);
	udelay(100000);
	wr(GCTL, rd(GCTL) & ~GCTL_CORESOFTRESET);
	wr(DCTL, DCTL_CSFTRST);
	int i;
	for (i = 0; i < 500 && (rd(DCTL) & DCTL_CSFTRST); i++)
		udelay(1000);
	if (rd(DCTL) & DCTL_CSFTRST)
		return USB_E_RESET;
	/* ABL's GCTL with the bus clock for the controller RAM (RAMCLKSEL 7:6 = 0) */
	wr(GCTL, gctl_abl & ~(3u << 6));
	usb_info.gctl_now = rd(GCTL);

	/* 4. HS-only quirks (mainline sdm845.dtsi) and GUCTL1.DEV_FORCE_20_CLK_FOR_30_CLK */
	wr(GUCTL1, rd(GUCTL1) | (1u << 17));				/* PARKMODE_DISABLE_SS */
	wr(DCTL, rd(DCTL) & ~((1u << 10) | (1u << 12)));		/* INITU1ENA, INITU2ENA */
	wr(GUSB2PHYCFG, rd(GUSB2PHYCFG) & ~((1u << 6) | (1u << 8)));	/* SUSPHY, ENBLSLPM */
	wr(GUCTL1, rd(GUCTL1) | (1u << 26));

	/* 5. apps_smmu: the first DMA of an unmapped stream resets the SoC */
	if (use_smmu) {
		usb_info.smmu_rc = smmu_map();
	} else {
		usb_info.smmu_rc = 1;
	}

	/* 6. our event buffer (polled: interrupt masked), speed = HS (soft reset applied DEVSPD), address 0 */
	uint64_t evt = ud.dma + UD_EVT;
	wr(GEVNTADRLO, (uint32_t)evt);
	wr(GEVNTADRHI, (uint32_t)(evt >> 32));
	wr(GEVNTSIZ, (1u << 31) | UD_EVT_SIZE);
	wr(GEVNTCOUNT, rd(GEVNTCOUNT) & 0xffff);
	wr(DCFG, rd(DCFG) & ~(7u | (0x7fu << 3)));
	wr(DEVTEN, 0x7);		/* disconnect, USB reset, connect done */

	/* 7. endpoint 0 (max packet 512 until connect done), then SETUP */
	if (ud_epcmd(0, DEPCMD_DEPSTARTCFG, 0, 0, 0) ||
	    ud_epcmd(0, DEPCMD_SETEPCONFIG, (0u << 1) | (512u << 3), (1u << 8) | (1u << 10) | (0u << 25), 0) ||
	    ud_epcmd(0, DEPCMD_SETTRANSFRESOURCE, 1, 0, 0) ||
	    ud_epcmd(1, DEPCMD_SETEPCONFIG, (0u << 1) | (512u << 3), (1u << 8) | (1u << 10) | (1u << 25), 0) ||
	    ud_epcmd(1, DEPCMD_SETTRANSFRESOURCE, 1, 0, 0)) {
		usb_info.dsts = rd(DSTS);
		return USB_E_EP0;
	}
	wr(DALEPENA, 0x3);
	ud_start_setup();

	/* 8. VBUS session override (dwc3_qcom_vbus_override_enable), remember the old values */
	ud.qs_hs_saved = rd_at(QSCRATCH_BASE + QS_HS_PHY_CTRL);
	ud.qs_ss_saved = rd_at(QSCRATCH_BASE + QS_SS_PHY_CTRL);
	ud.qs_saved = 1;
	wr_at(QSCRATCH_BASE + QS_HS_PHY_CTRL, ud.qs_hs_saved | UTMI_OTG_VBUS_VALID | SW_SESSVLD_SEL);
	wr_at(QSCRATCH_BASE + QS_SS_PHY_CTRL, ud.qs_ss_saved | LANE0_PWR_PRESENT);

	ud.state = USB_ST_RUNNING;	/* poll() only runs from here */
	wr(DCTL, rd(DCTL) | DCTL_RUN_STOP);
	for (i = 0; i < 500 && (rd(DSTS) & DSTS_DEVCTRLHLT); i++)
		udelay(1000);
	usb_info.dsts = rd(DSTS);
	usb_info.dcfg = rd(DCFG);
	usb_info.dctl = rd(DCTL);
	if (rd(DSTS) & DSTS_DEVCTRLHLT)
		return USB_E_RUN;	/* usb_dwc3_stop() undoes RUN_STOP and the event buffer */
	note();
	return 0;
}

void usb_dwc3_stop(void)
{
	if (!ud.touched && !sm.cbx && !ud.qs_saved)
		return;
	if (ud.touched) {
		for (unsigned ep = 0; ep < N_EP; ep++)
			ud_end_transfer(ep);
		wr(DEVTEN, 0);
		wr(DCTL, rd(DCTL) & ~DCTL_RUN_STOP);
		for (int i = 0; i < 500 && !(rd(DSTS) & DSTS_DEVCTRLHLT); i++)
			udelay(1000);
		wr(DALEPENA, 0);
		/* no event may be written into our image after this (Linux dwc3_event_buffers_cleanup) */
		wr(GEVNTADRLO, 0);
		wr(GEVNTADRHI, 0);
		wr(GEVNTSIZ, 1u << 31);
		wr(GEVNTCOUNT, 0);
	}
	if (ud.qs_saved) {
		wr_at(QSCRATCH_BASE + QS_HS_PHY_CTRL, ud.qs_hs_saved);
		wr_at(QSCRATCH_BASE + QS_SS_PHY_CTRL, ud.qs_ss_saved);
		ud.qs_saved = 0;
	}
	smmu_unmap();
	ud.touched = 0;
	ud.state = USB_ST_DOWN;
	note();
}

/* ---- fastboot data path ---- */

static int wait_done(volatile int *flag, uint32_t gen, unsigned timeout_ms, void (*idle)(void))
{
	uint64_t end = ticks() + ticks_per_us() * 1000 * timeout_ms;
	for (;;) {
		usb_dwc3_poll();
		if (ud.link_gen != gen)
			return USB_LINK_LOST;
		if (*flag)
			return 0;
		if (idle)
			idle();
		if (ticks() > end)
			return USB_TIMEOUT;
	}
}

int usb_dwc3_cmd_poll(char *buf, unsigned max)
{
	usb_dwc3_poll();
	if (ud.link_gen != ud.cmd_gen_seen) {
		ud.cmd_gen_seen = ud.link_gen;
		return USB_LINK_LOST;
	}
	if (ud.state != USB_ST_CONFIGURED)
		return 0;
	if (!ud.rx_armed) {
		cache_ci(ud.dma + UD_CMD, CMD_MAX);
		ud.rx_done = 0;
		if (ud_start_trb(EP_RX, UD_TRB_RX, ud.dma + UD_CMD, CMD_MAX, TRBCTL_NORMAL) == 0)
			ud.rx_armed = 1;
		return 0;
	}
	if (!ud.rx_done)
		return 0;
	ud.rx_armed = 0;
	ud.rx_done = 0;
	uint32_t n = CMD_MAX - ud.rx_resid;
	if (n > CMD_MAX)
		n = 0;
	if (n > max)
		n = max;
	volatile uint8_t *src = (volatile uint8_t *)(ud.dma + UD_CMD);
	for (uint32_t i = 0; i < n; i++)
		buf[i] = (char)src[i];
	return (int)n;	/* 0: a zero-length packet, ignored by the caller (not armed again until the next call) */
}

int usb_dwc3_bulk_in(const void *buf, unsigned len)
{
	if (ud.state != USB_ST_CONFIGURED)
		return USB_LINK_LOST;
	if (len > TXB_MAX)
		len = TXB_MAX;
	volatile uint8_t *dst = (volatile uint8_t *)(ud.dma + UD_TXB);
	const uint8_t *src = buf;
	for (unsigned i = 0; i < len; i++)
		dst[i] = src[i];
	cache_ci(ud.dma + UD_TXB, TXB_MAX);
	uint32_t gen = ud.link_gen;
	ud.tx_done = 0;
	if (ud_start_trb(EP_TX, UD_TRB_TX, ud.dma + UD_TXB, len, TRBCTL_NORMAL))
		return USB_LINK_LOST;
	int rc = wait_done(&ud.tx_done, gen, 5000, 0);
	if (rc == USB_TIMEOUT)
		ud_end_transfer(EP_TX);
	return rc;
}

int usb_dwc3_bulk_out(void *dst, uint64_t len, void (*idle)(void))
{
	if (ud.state != USB_ST_CONFIGURED)
		return USB_LINK_LOST;
	if (len > DL_TRB_MAX)
		len = DL_TRB_MAX;
	uint32_t trblen = (uint32_t)((len + 511) & ~511UL);
	if (ud.rx_armed)
		ud_rx_disarm();
	/* stale dirty lines from ABL in this range would be evicted over our data */
	cache_ci((uintptr_t)dst, trblen);
	uint32_t gen = ud.link_gen;
	ud.rx_done = 0;
	if (ud_start_trb(EP_RX, UD_TRB_RX, (uintptr_t)dst, trblen, TRBCTL_NORMAL))
		return USB_LINK_LOST;
	int rc = wait_done(&ud.rx_done, gen, 20000, idle);
	if (rc) {
		if (rc == USB_TIMEOUT)
			ud_end_transfer(EP_RX);
		return rc;
	}
	uint32_t got = trblen - ud.rx_resid;
	if (ud.rx_resid > trblen)
		got = 0;
	cache_inv((uintptr_t)dst, got);
	return (int)got;
}

int usb_dwc3_bulk_in_dma(const void *src, uint64_t len, void (*idle)(void))
{
	const uint8_t *p = src;
	uint64_t done = 0;

	if (ud.state != USB_ST_CONFIGURED)
		return USB_LINK_LOST;
	while (done < len) {
		uint32_t n = len - done > DL_TRB_MAX ? DL_TRB_MAX : (uint32_t)(len - done);
		/* the host reads this memory through the SMMU/DMA: no CPU line may stay dirty */
		cache_ci((uintptr_t)p + done, n);
		uint32_t gen = ud.link_gen;
		ud.tx_done = 0;
		if (ud_start_trb(EP_TX, UD_TRB_TX, (uintptr_t)p + done, n, TRBCTL_NORMAL))
			return USB_LINK_LOST;
		int rc = wait_done(&ud.tx_done, gen, 20000, idle);
		if (rc) {
			if (rc == USB_TIMEOUT)
				ud_end_transfer(EP_TX);
			return rc;
		}
		done += n;
	}
	return 0;
}
