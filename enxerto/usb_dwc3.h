#pragma once
/*
 * Polled Synopsys DWC3 device-mode driver for the SDM845 USB controller
 * (0x0a600000), just enough for Android fastboot: ep0 + one bulk OUT and one
 * bulk IN endpoint, high speed, no interrupts, MMU off (Device memory).
 * Port of the sequence that works in xnu (xnu/patches/0072..0109, sweet_usb.c
 * + sweet_smmu.c); see docs/BERGAMOTA_FASTBOOT.md.
 *
 * Every blocking call keeps servicing ep0 / bus resets while it waits.
 * Return values: >= 0 ok / byte count, USB_LINK_LOST when the host reset or
 * unplugged the bus (the caller drops its protocol state and goes on),
 * USB_TIMEOUT when the host stopped talking.
 */
#include <stdint.h>

#define USB_LINK_LOST	(-1)
#define USB_TIMEOUT	(-3)

/* usb_dwc3_init() failures (usb_dwc3_errstr() for the screen) */
#define USB_E_CLOCKS	(-10)	/* GDSC / controller clocks off */
#define USB_E_ID	(-11)	/* GSNPSID is not a DWC3 */
#define USB_E_RESET	(-12)	/* DCTL.CSFTRST stuck */
#define USB_E_EP0	(-13)	/* an endpoint-0 command failed */
#define USB_E_RUN	(-14)	/* controller never left halt */

enum usb_state {
	USB_ST_DOWN,		/* not initialised / stopped */
	USB_ST_RUNNING,	/* RUN_STOP set, no host seen */
	USB_ST_RESET,		/* bus reset / connect done seen */
	USB_ST_ADDRESSED,	/* SET_ADDRESS handled */
	USB_ST_CONFIGURED,	/* SET_CONFIGURATION(1): fastboot usable */
};

/* Hardware facts for the on-screen diagnostics. */
struct usb_dwc3_info {
	uint32_t gsnpsid, gctl_abl, gctl_now, dsts, dcfg, dctl;
	uint32_t qusb_pwr_before, qusb_pwr_after, qusb_pll_after;
	uint32_t qscratch_gen_cfg;
	int smmu_rc;		/* 0 ok, <0 error, 1 skipped */
	uint32_t smmu_info;	/* smr/s2cr index touched, or error detail */
	uint32_t events, last_event, resets, setups;
	uint8_t last_setup[8];
	int speed;		/* DSTS[2:0] at connect done (0 = HS, 4 = what ABL left) */
	uint32_t change;	/* bumped whenever state/counters change: redraw hint */
};

extern struct usb_dwc3_info usb_info;

/* Full bring-up. smmu: map stream 0x740 through an identity bank (xnu does, see doc). 0 or USB_E_*. */
int usb_dwc3_init(int smmu);
const char *usb_dwc3_errstr(int err);
enum usb_state usb_dwc3_state(void);
/* Quiesce the controller and undo SMMU/QSCRATCH changes: call before handing the machine to xnu. */
void usb_dwc3_stop(void);

/* Service events once (no waiting). */
void usb_dwc3_poll(void);

/*
 * One received fastboot command packet (<= max bytes, not terminated).
 * 0 = nothing yet, USB_LINK_LOST = the bus was reset since the last call.
 */
int usb_dwc3_cmd_poll(char *buf, unsigned max);
/* Send len bytes (<= 256) on the bulk IN endpoint; 0, USB_LINK_LOST or USB_TIMEOUT. */
int usb_dwc3_bulk_in(const void *buf, unsigned len);
/*
 * Receive up to len bytes of a download straight into dst (any DRAM address,
 * 512-byte rounded DMA): returns the byte count of one bulk transfer (>0),
 * USB_LINK_LOST or USB_TIMEOUT. idle() is called while waiting.
 */
int usb_dwc3_bulk_out(void *dst, uint64_t len, void (*idle)(void));
/*
 * Send len bytes straight from memory on the bulk IN endpoint (fastboot `upload`: the hash table of
 * `oem hash`), in transfers of up to 8 MiB. 0, USB_LINK_LOST or USB_TIMEOUT. idle() is called while waiting.
 */
int usb_dwc3_bulk_in_dma(const void *src, uint64_t len, void (*idle)(void));
