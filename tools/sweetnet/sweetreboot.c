/*
 * sweetreboot fastboot|recovery|bergamota|normal: reboot the Poco F1 into that mode.
 *
 * Sets the root-only sysctl kern.sweet_reboot_mode (kernel patch 0137), syncs
 * and calls the reboot(2) syscall (RB_AUTOBOOT), which reaches the kernel's
 * PE_halt_restart -> SweetPlatformExpert::haltRestart -> PS_HOLD reset after
 * writing the reason to the PM8998 PON block (and IMEM). A plain root reboot()
 * is what launchd/shutdown use underneath; no entitlement is needed beyond
 * root (the tool is also ad-hoc signed like the others, see build.sh).
 *
 * Needs a kernel with 0137: without the sysctl it refuses to reboot
 * (a reboot would otherwise just land in Android, or hang on older kernels).
 * Options: -n  set the mode only, do not reboot.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define RB_AUTOBOOT_VALUE 0

int
main(int argc, char **argv)
{
	int noreboot = 0;
	const char *want = NULL;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-n")) {
			noreboot = 1;
		} else {
			want = argv[i];
		}
	}
	const char *mode = NULL;
	if (want && (!strcmp(want, "fastboot") || !strcmp(want, "bootloader"))) {
		mode = "bootloader";
	} else if (want && !strcmp(want, "recovery")) {
		mode = "recovery";
	} else if (want && !strcmp(want, "bergamota")) {
		mode = "bergamota";	/* kernel patch 0140: IMEM 'BERG', shim enters Bergamota fastboot */
	} else if (want && !strcmp(want, "normal")) {
		mode = "normal";
	}
	if (!mode) {
		fprintf(stderr, "usage: sweetreboot [-n] fastboot|recovery|bergamota|normal\n");
		return 2;
	}
	if (geteuid() != 0) {
		fprintf(stderr, "sweetreboot: must run as root\n");
		return 1;
	}
	if (sysctlbyname("kern.sweet_reboot_mode", NULL, NULL, (void *)mode, strlen(mode) + 1) != 0) {
		perror("sweetreboot: sysctl kern.sweet_reboot_mode (kernel without patch 0137, or 0140 for bergamota?)");
		return 1;
	}
	char got[32] = "";
	size_t len = sizeof(got);
	if (sysctlbyname("kern.sweet_reboot_mode", got, &len, NULL, 0) != 0 || strcmp(got, mode) != 0) {
		fprintf(stderr, "sweetreboot: mode readback '%s', expected '%s'\n", got, mode);
		return 1;
	}
	printf("sweetreboot: next reboot mode %s\n", got);
	if (noreboot) {
		return 0;
	}
	fflush(stdout);
	sync();
	sleep(1);
	sync();
	int (*reboot_fn)(int, ...) = (int (*)(int, ...))dlsym(RTLD_DEFAULT, "reboot");
	if (!reboot_fn) {
		fprintf(stderr, "sweetreboot: reboot not found\n");
		return 1;
	}
	reboot_fn(RB_AUTOBOOT_VALUE);
	perror("sweetreboot: reboot");
	return 1;
}
