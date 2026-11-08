/*
 * sweetnetcfg: publish the USB Ethernet (ue0) IPv4 + DNS state into
 * configd's dynamic store so IPMonitor makes it the primary service:
 * default route via the Mac and the DNS resolver configuration.
 *
 * configd sees ue0 (patch 0110) but its IPConfiguration agent never
 * configures it, so no State:/Network/Service/<id>/IPv4 exists and
 * IPMonitor deletes the default route and publishes no DNS. This writes
 * the keys IPConfiguration would have written. Run as root:
 *   sweetnetcfg            publish (and keep the session open with -w)
 *   sweetnetcfg -d         remove the keys
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SERVICE "5EE7C0DE-0000-4000-8000-0000000000E0"

/*
 * The iOS SDK marks the SCDynamicStore API unavailable, but iOS's
 * SystemConfiguration.framework exports it (configd's own clients use it):
 * resolve it at run time. Keys are the plain schema strings.
 */
typedef const struct __SCDynamicStore *SCDynamicStoreRef;
static SCDynamicStoreRef (*SCDynamicStoreCreate)(CFAllocatorRef, CFStringRef, void *, void *);
static Boolean (*SCDynamicStoreSetValue)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef);
static Boolean (*SCDynamicStoreRemoveValue)(SCDynamicStoreRef, CFStringRef);
static int (*SCError)(void);
static const char *(*SCErrorString)(int);
#define kSCPropNetIPv4Addresses         CFSTR("Addresses")
#define kSCPropNetIPv4SubnetMasks       CFSTR("SubnetMasks")
#define kSCPropNetIPv4Router            CFSTR("Router")
#define kSCPropInterfaceName            CFSTR("InterfaceName")
#define kSCPropNetDNSServerAddresses    CFSTR("ServerAddresses")

static int
sc_load(void)
{
	void *h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
	if (h == NULL) {
		fprintf(stderr, "sweetnetcfg: dlopen: %s\n", dlerror());
		return -1;
	}
	SCDynamicStoreCreate = dlsym(h, "SCDynamicStoreCreate");
	SCDynamicStoreSetValue = dlsym(h, "SCDynamicStoreSetValue");
	SCDynamicStoreRemoveValue = dlsym(h, "SCDynamicStoreRemoveValue");
	SCError = dlsym(h, "SCError");
	SCErrorString = dlsym(h, "SCErrorString");
	if (!SCDynamicStoreCreate || !SCDynamicStoreSetValue || !SCDynamicStoreRemoveValue ||
	    !SCError || !SCErrorString) {
		fprintf(stderr, "sweetnetcfg: SCDynamicStore symbols missing\n");
		return -1;
	}
	return 0;
}

static CFArrayRef
arr1(const char *s)
{
	CFStringRef v = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
	CFArrayRef a = CFArrayCreate(NULL, (const void **)&v, 1, &kCFTypeArrayCallBacks);
	CFRelease(v);
	return a;
}

static void
set(CFMutableDictionaryRef d, CFStringRef k, CFTypeRef v)
{
	CFDictionarySetValue(d, k, v);
	CFRelease(v);
}

int
main(int argc, char **argv)
{
	int del = argc > 1 && strcmp(argv[1], "-d") == 0;
	int wait = argc > 1 && strcmp(argv[1], "-w") == 0;
	if (sc_load() != 0) {
		return 1;
	}
	SCDynamicStoreRef st = SCDynamicStoreCreate(NULL, CFSTR("sweetnetcfg"), NULL, NULL);
	if (st == NULL) {
		fprintf(stderr, "sweetnetcfg: SCDynamicStoreCreate: %s\n", SCErrorString(SCError()));
		return 1;
	}
	CFStringRef kv4 = CFSTR("State:/Network/Service/" SERVICE "/IPv4");
	CFStringRef kdns = CFSTR("State:/Network/Service/" SERVICE "/DNS");
	CFStringRef ksvc = CFSTR("State:/Network/Service/" SERVICE);
	if (del) {
		SCDynamicStoreRemoveValue(st, kv4);
		SCDynamicStoreRemoveValue(st, kdns);
		SCDynamicStoreRemoveValue(st, ksvc);
		printf("sweetnetcfg: removed\n");
		return 0;
	}

	CFMutableDictionaryRef v4 = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	set(v4, kSCPropNetIPv4Addresses, arr1("192.168.7.2"));
	set(v4, kSCPropNetIPv4SubnetMasks, arr1("255.255.255.0"));
	CFDictionarySetValue(v4, kSCPropNetIPv4Router, CFSTR("192.168.7.1"));
	CFDictionarySetValue(v4, kSCPropInterfaceName, CFSTR("ue0"));

	CFMutableDictionaryRef dns = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef servers[] = { CFSTR("1.1.1.1"), CFSTR("8.8.8.8") };
	set(dns, kSCPropNetDNSServerAddresses,
	    CFArrayCreate(NULL, (const void **)servers, 2, &kCFTypeArrayCallBacks));

	CFMutableDictionaryRef svc = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(svc, kSCPropInterfaceName, CFSTR("ue0"));

	Boolean ok = SCDynamicStoreSetValue(st, ksvc, svc) &&
	    SCDynamicStoreSetValue(st, kv4, v4) &&
	    SCDynamicStoreSetValue(st, kdns, dns);
	printf("sweetnetcfg: %s (%s)\n", ok ? "published ue0 IPv4 192.168.7.2 via 192.168.7.1, DNS 1.1.1.1 8.8.8.8" :
	    "FAILED", ok ? "ok" : SCErrorString(SCError()));
	CFRelease(v4);
	CFRelease(dns);
	CFRelease(svc);
	if (ok && wait) {
		/* Session keys live as long as the session: keep it open. */
		for (;;) {
			pause();
		}
	}
	return ok ? 0 : 1;
}
