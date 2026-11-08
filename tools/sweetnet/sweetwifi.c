/*
 * sweetwifi: drive the IO80211 framework's Apple80211 API over SSH (iOS 26, docs/WIFI_IOS26.md).
 *
 *   sweetwifi [-i en0] info          power state, country code, current SSID/BSSID
 *   sweetwifi [-i en0] power on|off  APPLE80211_IOC_POWER through the framework
 *   sweetwifi [-i en0] scan          Apple80211Scan: SCAN_REQ, wait for SCAN_DONE, read results
 *
 * The same calls wifid makes, without wifid or the UI (useful while touch does not work):
 * they reach the kernel stand-in (bsd/dev/sweet_80211.c) as SIOCGA80211/SIOCSA80211 ioctls,
 * so its "SWEET 80211:" log lines appear as for wifid. IO80211.framework is private: loaded
 * with dlopen, calls by name (classic signatures, checked against IO80211 1565.3).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct __Apple80211 *Apple80211Ref;

static int (*a_open)(Apple80211Ref *);
static int (*a_bind)(Apple80211Ref, CFStringRef);
static int (*a_close)(Apple80211Ref);
static int (*a_scan)(Apple80211Ref, CFArrayRef *, CFDictionaryRef);
static int (*a_get_power)(Apple80211Ref, uint32_t *);
static int (*a_set_power)(Apple80211Ref, uint32_t);
static int (*a_copy_value)(Apple80211Ref, uint32_t, CFDictionaryRef, void *);

static void *
sym(void *h, const char *name)
{
	void *p = dlsym(h, name);
	if (p == NULL) {
		fprintf(stderr, "sweetwifi: %s missing in IO80211\n", name);
		exit(1);
	}
	return p;
}

static void
print_cf(const char *label, CFTypeRef v)
{
	char buf[256] = "";
	if (v == NULL) {
		printf("%s: -\n", label);
		return;
	}
	if (CFGetTypeID(v) == CFStringGetTypeID()) {
		CFStringGetCString(v, buf, sizeof(buf), kCFStringEncodingUTF8);
	} else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		long long n = 0;
		CFNumberGetValue(v, kCFNumberLongLongType, &n);
		snprintf(buf, sizeof(buf), "%lld", n);
	} else if (CFGetTypeID(v) == CFDataGetTypeID()) {
		CFIndex len = CFDataGetLength(v);
		const UInt8 *d = CFDataGetBytePtr(v);
		for (CFIndex i = 0; i < len && i < 32; i++) {
			snprintf(buf + strlen(buf), sizeof(buf) - strlen(buf), "%02x%s", d[i], i + 1 < len ? ":" : "");
		}
	} else {
		CFStringRef s = CFCopyDescription(v);
		CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
		CFRelease(s);
	}
	printf("%s: %s\n", label, buf);
}

static CFTypeRef
get(CFDictionaryRef d, const char *key)
{
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFTypeRef v = CFDictionaryGetValue(d, k);
	CFRelease(k);
	return v;
}

static int
do_scan(Apple80211Ref ref)
{
	CFArrayRef list = NULL;
	CFDictionaryRef params = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	int err = a_scan(ref, &list, params);
	CFRelease(params);
	printf("Apple80211Scan -> %d, %ld result(s)\n", err, list ? (long)CFArrayGetCount(list) : 0L);
	for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
		CFDictionaryRef r = CFArrayGetValueAtIndex(list, i);
		printf("[%ld]\n", (long)i);
		print_cf("  SSID_STR", get(r, "SSID_STR"));
		print_cf("  BSSID", get(r, "BSSID"));
		print_cf("  CHANNEL", get(r, "CHANNEL"));
		print_cf("  RSSI", get(r, "RSSI"));
		print_cf("  NOISE", get(r, "NOISE"));
		print_cf("  CAPABILITIES", get(r, "CAPABILITIES"));
		if (getenv("SWEETWIFI_DUMP")) {
			CFShow(r);
		}
	}
	if (list) {
		CFRelease(list);
	}
	return err;
}

int
main(int argc, char **argv)
{
	const char *ifname = "en0";
	int i = 1;

	if (argc > 2 && strcmp(argv[1], "-i") == 0) {
		ifname = argv[2];
		i = 3;
	}
	if (i >= argc) {
		fprintf(stderr, "usage: sweetwifi [-i IF] info | power on|off | scan\n");
		return 2;
	}
	void *h = dlopen("/System/Library/PrivateFrameworks/IO80211.framework/IO80211", RTLD_NOW);
	if (h == NULL) {
		fprintf(stderr, "sweetwifi: dlopen IO80211: %s\n", dlerror());
		return 1;
	}
	a_open = sym(h, "Apple80211Open");
	a_bind = sym(h, "Apple80211BindToInterface");
	a_close = sym(h, "Apple80211Close");
	a_scan = sym(h, "Apple80211Scan");
	a_get_power = sym(h, "Apple80211GetPower");
	a_set_power = sym(h, "Apple80211SetPower");
	a_copy_value = sym(h, "Apple80211CopyValue");

	Apple80211Ref ref = NULL;
	int err = a_open(&ref);
	if (err != 0 || ref == NULL) {
		fprintf(stderr, "sweetwifi: Apple80211Open -> %d\n", err);
		return 1;
	}
	CFStringRef ifs = CFStringCreateWithCString(NULL, ifname, kCFStringEncodingUTF8);
	err = a_bind(ref, ifs);
	CFRelease(ifs);
	printf("Apple80211BindToInterface(%s) -> %d\n", ifname, err);
	if (err != 0) {
		a_close(ref);
		return 1;
	}

	const char *cmd = argv[i];
	if (strcmp(cmd, "info") == 0) {
		uint32_t power = 0;
		err = a_get_power(ref, &power);
		printf("power -> %d: %u\n", err, power);
		const struct { uint32_t type; const char *name; } q[] = {
			{ 1, "SSID" }, { 9, "BSSID" }, { 51, "COUNTRY_CODE" }, { 13, "STATE" }, { 15, "OP_MODE" },
		};
		for (unsigned k = 0; k < sizeof(q) / sizeof(q[0]); k++) {
			CFTypeRef v = NULL;
			int e = a_copy_value(ref, q[k].type, NULL, &v);
			char label[64];
			snprintf(label, sizeof(label), "%s (%u) -> %d", q[k].name, q[k].type, e);
			print_cf(label, e == 0 ? v : NULL);
			if (v) {
				CFRelease(v);
			}
		}
	} else if (strcmp(cmd, "power") == 0 && i + 1 < argc) {
		uint32_t on = strcmp(argv[i + 1], "on") == 0;
		err = a_set_power(ref, on);
		printf("Apple80211SetPower(%u) -> %d\n", on, err);
	} else if (strcmp(cmd, "scan") == 0) {
		err = do_scan(ref);
	} else {
		fprintf(stderr, "sweetwifi: unknown command %s\n", cmd);
		err = 2;
	}
	a_close(ref);
	return err != 0;
}
