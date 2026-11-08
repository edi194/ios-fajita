/*
 * Render the console and the branded boot screen on the host:
 *   ./out/host_test   ->  out/host.ppm (text console), out/preview/ (boot screen stages)
 */
#include <stdio.h>
#include "bootui.h"
#include "console.h"
#include "fbui.h"
#include "charge.h"
#include "artdraw.h"

static uint32_t host_fb[FB_H * FB_STRIDE / 4];

static void dump(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f)
		return;
	fprintf(f, "P6 %d %d 255\n", FB_W, FB_H);
	for (int i = 0; i < FB_W * FB_H; i++) {
		unsigned char px[3] = { host_fb[i] >> 16, host_fb[i] >> 8, host_fb[i] };
		fwrite(px, 1, 3, f);
	}
	fclose(f);
}

int main(void)
{
	con_fb = host_fb;
	con_clear(BG_BOOT);
	con_str("ENXERTO", "sweet milestone 2");
	con_hex("MMFR0", 0x0000000000101122ULL);
	con_hex2("PSCI", "ver=", 0x10001, "smccc=", 0x10002);
	con_hex2("CPU7", "ret=", 0, "mpidr=", 0x81000700);
	dump("out/host.ppm");

	/* Boot screen as loader.c drives it (same strings, stages and log lines). */
	bootui_init();
	bootui_progress(40, "INITRD FOUND");
	con_hex2("INITRD", "lo=", 0x85400000, "hi=", 0x86100000);
	dump("out/preview/boot-0-initrd.ppm");
	con_hex2("PHYS", "base=", 0x80000000, "size=", 0x80000000);
	con_hex("VIRT", 0xfffffff007004000ULL);
	con_hex("ENTRY", 0xfffffff007b14c28ULL);
	bootui_progress(70, "PAYLOAD OK");
	con_hex2("MMU", "rc=", 0, "l3=", 3);
	bootui_progress(100, "MMU ON");
	con_hex2("INFLATE", "in=", 0x2400000, "out=", 0x5a00000);
	bootui_mib("INFLATE", 0, 311, 100, 900);
	bootui_mib("INFLATE", 140, 311, 100, 900);
	dump("out/preview/boot-1-inflate-45pct.ppm");
	bootui_mib("INFLATE", 311, 311, 100, 900);
	bootui_progress(920, "SEGMENTS READY");
	con_hex2("SEGS", "n=", 4, "end=", 0x8a000000);
	bootui_progress(960, "BOOT ARGS");
	con_hex2("BOOTARG", "pa=", 0x8a400000, "top=", 0x8a404000);
	bootui_progress(1000, "STARTING IOS");
	con_hex("JUMP", 0x80f14c28ULL);
	con_str("XNU", "jumping (fbcon clears screen)");
	dump("out/preview/boot-2-jump.ppm");
	bootui_handoff();
	dump("out/preview/boot-2b-handoff.ppm");

	/* Failure on the boot screen, then the text fallback / panic screens. */
	bootui_init();
	bootui_progress(100, "MMU ON");
	con_hex2("INFLATE", "rc=", (uint32_t)-3, "got=", 0x1234);
	bootui_fail("inflate failed");
	dump("out/preview/boot-3-fail.ppm");

	con_clear(BG_PANIC);
	con_str("PANIC", "sync exception");
	con_hex("ESR", 0x96000010);
	dump("out/preview/panic.ppm");

	/* Bergamota fastboot screen states (bergamota.c derives the same strings from USB/protocol state). */
	fbui_init("no payload");
	fbui_status("CONNECT TO YOUR MAC", "plug in the USB cable", FBUI_NOBAR, FBUI_OK_COLOR);
	dump("out/preview/fastboot-0-connect.ppm");
	fbui_diag("usb no host  ev 00000012 rst 00000001 setup 00000000 last 00000000",
		  "dwc3 id 5533330a dsts 00000000 gctl 00000000/00004000 qusb 00000000 pll 00000000 smmu 00000000/00000000",
		  "buf b8000000+1024MiB  cmd getvar:max-download-size  reply OKAY");
	dump("out/preview/fastboot-1-connect-diag.ppm");
	fbui_diag(0, 0, 0);
	fbui_status("CONNECTED", "waiting for fastboot commands", FBUI_NOBAR, TEXT);
	dump("out/preview/fastboot-2-connected.ppm");
	fbui_status("RECEIVING 0%", "(0.0 / 17.0 MiB)", 0, TEXT);
	fbui_status("RECEIVING 34%", "(5.8 / 17.0 MiB)", 340, TEXT);
	dump("out/preview/fastboot-3-receiving.ppm");
	fbui_status("READY", "image in memory: 17.0 MiB", 1000, TEXT);
	dump("out/preview/fastboot-4-ready.ppm");
	fbui_status("BOOTING PAYLOAD", "stopping USB, handing over", 1000, TEXT);
	dump("out/preview/fastboot-5-booting.ppm");
	fbui_init("restart reason");
	fbui_status("REBOOTING", "to the bootloader", FBUI_NOBAR, FBUI_OK_COLOR);
	dump("out/preview/fastboot-6-rebooting.ppm");

	/* error: the loader's recorded log replayed small under the red status */
	fbui_init("cmdline");
	fbui_error("inflate failed", "back to ABL fastboot in 20 s");
	fbui_diag("usb configured  ev 00000412 rst 00000002 setup 00000031 last 00000680",
		  "dwc3 id 5533330a dsts 00000800 gctl 00000000/00004000 qusb 00000000 pll 00000000 smmu 00000000/00000000",
		  "buf b8000000+1024MiB  cmd boot  reply FAIL inflate failed");
	dump("out/preview/fastboot-7-error.ppm");

	/* Off-mode charging screen with fake PMIC readings (same mapping as charge_mode.c). */
	static const struct {
		const char *name;
		struct pmic_batt b;
	} cs[] = {
		{ "15-charging", { 1, 15, 3612, 1480, 1, 1, PMIC_CHG_CHARGING, 3, 0x04, 0x25 } },
		{ "62-charging", { 1, 62, 4120, 1100, 1, 1, PMIC_CHG_CHARGING, 3, 0x04, 0x9e } },
		{ "100-charged", { 1, 100, 4352, 0, 1, 1, PMIC_CHG_FULL, 5, 0x04, 0xff } },
		{ "8-not-charging", { 1, 8, 3480, -310, 1, 0, PMIC_CHG_NONE, 0, 0, 0x14 } },
		{ "unavailable", { 0, 0, 0, 0, 0, 1, PMIC_CHG_NONE, 0, 0x04, 0 } },
	};
	for (unsigned i = 0; i < sizeof cs / sizeof cs[0]; i++) {
		struct charge_view v;
		char path[96];
		snprintf(path, sizeof path, "out/preview/charge-%s.ppm", cs[i].name);
		charge_ui_init();
		charge_view_from(&v, &cs[i].b);
		charge_ui_update(&v);
		charge_ui_diag("pmic ok  msoc b8  chg 3  usbin 1  apsd 04  pon 10",
			       "wled 07ff/07ff  entered via mode=charger");
		dump(path);
	}
	/* incremental update (62 -> 63 %) and the "fastboot could not start" notice */
	{
		struct charge_view v = { CHARGE_CHARGING, 62, 4120, 1100, 1 };
		charge_ui_init();
		charge_ui_update(&v);
		v.soc = 63;
		v.mv = 4131;
		charge_ui_update(&v);
		charge_ui_notice("fastboot stopped: USB clocks off", 0xffff6a5aU);
		dump("out/preview/charge-63-notice.ppm");
	}

	/* The logo partition's ABL screens (tools/mksplash.py packs these): power-on, the boot scene without text; ABL's
	 * own fastboot, the stage of the Bergamota fastboot screen with an ink BOOTLOADER pill (Enxerto's has the leaf
	 * green FASTBOOT one) and fixed text on the panel, since ABL draws no state of its own. */
	{
		enum art_image num = art_ios_numerals();
		bootui_scene((FB_W - 1000) / 2, 1000, (FB_W - art_image_w(num)) / 2, 150, num);
		dump("out/preview/splash-poweron.ppm");
		art_ground(0, 0, FB_W, FB_H);
		art_image(num, (FB_W - art_image_w(num)) / 2, STAGE_NUM_Y, ID_WHITE);
		art_stage_front(STAGE_PORTRAIT_W, 0, FB_H);
		art_pill(FB_W / 2, STAGE_PILL_Y, ID_INK, ID_PAPER, "BOOTLOADER");
		art_text(ART_MONO30, 96, STAGE_PANEL_Y + 40, ID_PAPER, "QUALCOMM ABL FASTBOOT");
		art_text(ART_MONO22, 96, STAGE_PANEL_Y + 94, ID_LIME, "stock bootloader: Bergamota boots Enxerto from here");
		art_text(ART_MONO22, 96, STAGE_PANEL_Y + 130, STAGE_MUTED, "fastboot boot bergamota-fastboot.img");
		art_text_centered(ART_MONO22, FB_H - 118, ID_PAPER, "Hold Power 10 s to restart");
		dump("out/preview/splash-fastboot.ppm");
		charge_ui_splash();
		dump("out/preview/splash-charging.ppm");
	}
	return 0;
}
