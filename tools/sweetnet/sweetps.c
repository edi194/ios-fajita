/*
 * sweetps: print the power sources iOS sees (IOPSCopyPowerSourcesInfo, what
 * powerd hands SpringBoard), and the IOPMPowerSource registry entries.
 * The iOS SDK lacks IOPowerSources.h: resolved at run time from IOKit.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

static void
show(const char *what, CFTypeRef v)
{
	if (v == NULL) {
		printf("%s: (null)\n", what);
		return;
	}
	CFStringRef d = CFCopyDescription(v);
	char buf[16384];
	if (CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8)) {
		printf("%s: %s\n", what, buf);
	}
	CFRelease(d);
}

int
main(void)
{
	void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
	if (h == NULL) {
		printf("dlopen IOKit: %s\n", dlerror());
		return 1;
	}
	CFTypeRef (*info)(void) = dlsym(h, "IOPSCopyPowerSourcesInfo");
	CFArrayRef (*list)(CFTypeRef) = dlsym(h, "IOPSCopyPowerSourcesList");
	CFDictionaryRef (*desc)(CFTypeRef, CFTypeRef) = dlsym(h, "IOPSGetPowerSourceDescription");
	CFStringRef (*providing)(CFTypeRef) = dlsym(h, "IOPSGetProvidingPowerSourceType");
	if (!info || !list || !desc) {
		printf("IOPS symbols missing\n");
		return 1;
	}
	CFTypeRef blob = info();
	if (providing != NULL) {
		show("providing", providing(blob));
	}
	CFArrayRef l = list(blob);
	CFIndex n = l ? CFArrayGetCount(l) : 0;
	printf("power sources: %ld\n", (long)n);
	for (CFIndex i = 0; i < n; i++) {
		show("source", desc(blob, CFArrayGetValueAtIndex(l, i)));
	}
	return 0;
}
