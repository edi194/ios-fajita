/*
 * Cold-boot USB power-up (see usb_power.h). Addresses checked against Linux v6.12 gcc-sdm845.c
 * (boot 0140dbg: the old offsets were one register off, so the master clock never ran, GSNPSID 0).
 * Addresses: gcc-sdm845.c (GCC at 0x100000,
 * resets 15 = USB30_PRIM_BCR 0xf000, 8 = QUSB2PHY_PRIM_BCR 0x12000 match the live DT
 * ssusb@a600000 / qusb@88e2000 reset indices), QUSB2 init sequence from live.dts
 * qcom,qusb-phy-init-seq (value, offset pairs; the last write, 0x22 to PWR_CTRL1, powers up).
 */
#include <stdint.h>
#include "console.h"
#include "usb_power.h"

#define GCC		0x00100000UL
#define USB30_PRIM_BCR	0x0f000
#define USB30_GDSCR	0x0f004
#define MASTER_CBCR	0x0f00c
#define SLEEP_CBCR	0x0f010
#define MOCK_UTMI_CBCR	0x0f014
#define MASTER_RCG	0x0f018	/* CMD; CFG at +4 */
#define MOCK_UTMI_RCG	0x0f030
#define PHY_AUX_CBCR	0x0f04c
#define PHY_AUX_RCG	0x0f05c
#define CFG_NOC_CBCR	0x0502c
#define AGGRE_CBCR	0x8201c
#define AHB2PHY_BCR	0x6a000
#define AHB2PHY_CBCR	0x6a004
#define CLKREF_EN	0x8c008
#define QUSB2PHY_BCR	0x12000

#define QUSB2		0x088e2000UL
#define DWC3_GSNPSID	0x0a60c120UL

static inline uint32_t rd(uintptr_t a)
{
	uint32_t v = *(volatile uint32_t *)a;
	__asm__ volatile("dmb sy" ::: "memory");
	return v;
}

static inline void wr(uintptr_t a, uint32_t v)
{
	*(volatile uint32_t *)a = v;
	__asm__ volatile("dsb sy" ::: "memory");
}

static void udelay(unsigned us)
{
	uint64_t f, t;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	uint64_t end = t + f / 1000000 * us;
	do
		__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	while (t < end);
}

static int clk_on(uint32_t off)
{
	uint32_t v = rd(GCC + off);
	if (v & 1u) {
		if (!(v & (1u << 31)))
			return 1;
	} else {
		wr(GCC + off, v | 1u);
	}
	for (int i = 0; i < 2000; i++) {
		if (!(rd(GCC + off) & (1u << 31)))
			return 1;
		udelay(5);
	}
	return 0;
}

/* RCG: source select (bits 10:8), hid_div field (bits 4:0 = 2*div-1), then update + root enable. */
static int rcg_set(uint32_t cmd, unsigned src, unsigned hid_div)
{
	wr(GCC + cmd + 4, (src << 8) | hid_div);
	wr(GCC + cmd, rd(GCC + cmd) | 1u | 2u);
	for (int i = 0; i < 2000; i++) {
		if (!(rd(GCC + cmd) & 1u))
			return 1;
		udelay(5);
	}
	return 0;
}

static void bcr_pulse(uint32_t off)
{
	wr(GCC + off, rd(GCC + off) | 1u);
	udelay(10);
	wr(GCC + off, rd(GCC + off) & ~1u);
	udelay(10);
}

static int alive(void)
{
	return (rd(GCC + USB30_GDSCR) & (1u << 31)) && !(rd(GCC + MASTER_CBCR) & (1u << 31)) &&
	       !(rd(GCC + CFG_NOC_CBCR) & (1u << 31));
}

/* qcom,qusb-phy-init-seq of live.dts, as (value, offset) pairs */
static const uint16_t phy_seq[][2] = {
	{ 0x23, 0x210 }, { 0x03, 0x04 }, { 0x7c, 0x18c }, { 0x80, 0x2c }, { 0x0a, 0x184 }, { 0x19, 0xb4 },
	{ 0x40, 0x194 }, { 0x18, 0x198 }, { 0x21, 0x214 }, { 0x08, 0x220 }, { 0x58, 0x224 }, { 0x07, 0x240 },
	{ 0x29, 0x244 }, { 0xca, 0x248 }, { 0x04, 0x24c }, { 0x03, 0x250 }, { 0x00, 0x23c }, { 0x22, 0x210 },
};

int usb_power_up(void)
{
	uint32_t gd = rd(GCC + USB30_GDSCR), m = rd(GCC + MASTER_CBCR), n = rd(GCC + CFG_NOC_CBCR);

	if (alive()) {
		con_hex2("USBPWR", "gdsc=", gd, "master=", m);
		con_str("USBPWR", "already powered (no-op)");
		return 0;
	}
	con_hex2("USBPWR", "cold gdsc=", gd, "master=", m);
	con_hex2("USBPWR", "cfgnoc=", n, "aggre=", rd(GCC + AGGRE_CBCR));

	/* config-NoC / aggregate NoC paths and the AHB to the PHY block first. A clock that does not report
	 * ON in time is logged by name and we go on: boot 0140dbg stopped at 'clk fail' with master and NoC
	 * already ON, leaving the controller and the QUSB2 PHY unreset/unpowered (no USB on cold boot). */
	unsigned bad = 0;
	bad |= !clk_on(CFG_NOC_CBCR) << 0;
	bad |= !clk_on(AGGRE_CBCR) << 1;
	bad |= !clk_on(AHB2PHY_CBCR) << 2;
	wr(GCC + CLKREF_EN, rd(GCC + CLKREF_EN) | 1u);

	/* USB30_PRIM power domain: clear SW_COLLAPSE, wait PWR_ON */
	wr(GCC + USB30_GDSCR, rd(GCC + USB30_GDSCR) & ~1u);
	int i;
	for (i = 0; i < 2000 && !(rd(GCC + USB30_GDSCR) & (1u << 31)); i++)
		udelay(5);
	if (i == 2000) {
		con_hex("USBPWR gdsc stuck", rd(GCC + USB30_GDSCR));
		return -1;
	}
	udelay(100);

	/* master 66.67 MHz (GPLL0 600 MHz / 9, enough for high speed: DT core-clk-rate-hs), mock UTMI / aux 19.2 MHz (XO) */
	bad |= !rcg_set(MASTER_RCG, 1, 17) << 3;
	bad |= !rcg_set(MOCK_UTMI_RCG, 0, 0) << 4;
	bad |= !rcg_set(PHY_AUX_RCG, 0, 0) << 5;
	bad |= !clk_on(MASTER_CBCR) << 6;
	bad |= !clk_on(SLEEP_CBCR) << 7;
	bad |= !clk_on(MOCK_UTMI_CBCR) << 8;
	bad |= !clk_on(PHY_AUX_CBCR) << 9;	/* USB3 PHY aux: may never report ON on this USB2-only port */
	if (bad) {
		/* bits: 0 cfgnoc 1 aggre 2 ahb2phy 3 master-rcg 4 utmi-rcg 5 aux-rcg 6 master 7 sleep 8 utmi 9 aux */
		con_hex2("USBPWR", "slow clks=", bad, "aux=", rd(GCC + PHY_AUX_CBCR));
		con_hex2("USBPWR", "utmi=", rd(GCC + MOCK_UTMI_CBCR), "sleep=", rd(GCC + SLEEP_CBCR));
	}

	/* controller and PHY resets, then the PHY init sequence ending in power-up (PWR_CTRL1 0x22) */
	bcr_pulse(USB30_PRIM_BCR);
	bcr_pulse(AHB2PHY_BCR);
	wr(GCC + QUSB2PHY_BCR, 1);
	udelay(100);
	wr(GCC + QUSB2PHY_BCR, 0);
	udelay(100);
	for (unsigned k = 0; k < sizeof phy_seq / sizeof phy_seq[0]; k++)
		wr(QUSB2 + phy_seq[k][1], phy_seq[k][0]);
	udelay(250);
	con_hex2("USBPWR", "phy pwr=", rd(QUSB2 + 0x210) & 0xff, "pll=", rd(QUSB2 + 0x1a0) & 0xff);

	uint32_t id = rd(DWC3_GSNPSID);
	con_hex2("USBPWR", "powered, gsnpsid=", id, "gdsc=", rd(GCC + USB30_GDSCR));
	return (id >> 16) == 0x5533 ? 1 : -3;
}
