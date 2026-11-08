/*
 * sweetwake: wake, unlock and drive the iOS 26 home screen over SSH, so GPU tests need no hands on the phone.
 *   sweetwake wake                         undim the display (SpringBoardServices SBSUndimScreen; Home press if missing)
 *   sweetwake unlock                       wake, then swipe up from the bottom edge (no passcode on this phone)
 *   sweetwake pages [N]                    swipe to the next home page and back, N times (default 1)
 *   sweetwake awake SECONDS                keep the display on: undim every 10 s for SECONDS, in the background
 *   sweetwake tap X Y | swipe X1 Y1 X2 Y2 [MS] | home | lock
 * Points in the 414x896 space of the iPhone12,1 userland. Events go into the HID event system like a digitizer's
 * (IOHIDEventSystemClientDispatchEvent, entitlement com.apple.private.hid.client.event-dispatch: touch.entitlements),
 * as sweettouch does for the iOS 18 userland. arm64e + pacstrip.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t ts, uint32_t transducer, uint32_t index,
    uint32_t identity, uint32_t eventMask, uint32_t buttonMask, double x, double y, double z, double pressure,
    double twist, bool range, bool touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t ts, uint32_t index, uint32_t identity,
    uint32_t eventMask, double x, double y, double z, double pressure, double twist, bool range, bool touch,
    uint32_t options);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t ts, uint32_t page, uint32_t usage,
    bool down, uint32_t flags);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, int64_t value);
extern void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);

#define W 414.0
#define H 896.0
#define kIOHIDDigitizerTransducerTypeHand 3
#define kIOHIDDigitizerEventRange 0x1
#define kIOHIDDigitizerEventTouch 0x2
#define kIOHIDDigitizerEventPosition 0x4
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0xb0019
#define SENDER 0x8000000817319372ULL            /* any fixed id: events are attributed to this "digitizer" */

static IOHIDEventSystemClientRef cli;

static void
finger(double x, double y, bool touch, uint32_t mask)
{
	uint64_t t = mach_absolute_time();
	IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, t, kIOHIDDigitizerTransducerTypeHand, 0, 0,
	    mask, 0, 0, 0, 0, 0, 0, touch, touch, 0);
	IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
	IOHIDEventRef f = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, t, 1, 2, mask, x / W, y / H, 0,
	    touch ? 1.0 : 0, 0, touch, touch, 0);
	IOHIDEventAppendEvent(hand, f, 0);
	IOHIDEventSetSenderID(hand, SENDER);
	IOHIDEventSystemClientDispatchEvent(cli, hand);
	CFRelease(f);
	CFRelease(hand);
}

static void
swipe(double x1, double y1, double x2, double y2, int ms)
{
	int steps = ms / 8 > 2 ? ms / 8 : 2;
	finger(x1, y1, true, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
	for (int i = 1; i <= steps; i++) {
		usleep(8000);
		finger(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps, true, kIOHIDDigitizerEventPosition);
	}
	finger(x2, y2, false, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
}

static void
button(uint32_t page, uint32_t usage)
{
	for (int down = 1; down >= 0; down--) {
		IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, down, 0);
		IOHIDEventSetSenderID(e, SENDER);
		IOHIDEventSystemClientDispatchEvent(cli, e);
		CFRelease(e);
		usleep(80000);
	}
}

/* SpringBoardServices' SBSUndimScreen: the display comes on as for a touch, without a button's side effects */
static int
undim(void)
{
	static void (*fn)(void);
	if (!fn) {
		void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
		fn = h ? (void (*)(void))dlsym(h, "SBSUndimScreen") : NULL;
	}
	if (!fn)
		return -1;
	fn();
	return 0;
}

static void
wake(void)
{
	if (undim() != 0)
		button(0x0c, 0x40);   /* consumer page, menu */
}

int
main(int argc, char **argv)
{
	cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
	if (!cli) {
		fprintf(stderr, "sweetwake: no HID event system client\n");
		return 1;
	}
	if (argc == 2 && !strcmp(argv[1], "wake")) {
		wake();
	} else if (argc == 2 && !strcmp(argv[1], "unlock")) {
		wake();
		usleep(600000);
		swipe(W / 2, H - 4, W / 2, H * 0.35, 250);   /* up from the bottom edge: lock screen -> home screen */
	} else if ((argc == 2 || argc == 3) && !strcmp(argv[1], "pages")) {
		int n = argc == 3 ? atoi(argv[2]) : 1;
		wake();
		for (int i = 0; i < n; i++) {
			usleep(500000);
			swipe(W * 0.85, H / 2, W * 0.15, H / 2, 250);   /* to the next page */
			usleep(1500000);
			swipe(W * 0.15, H / 2, W * 0.85, H / 2, 250);   /* and back */
		}
	} else if (argc == 3 && !strcmp(argv[1], "awake")) {
		int secs = atoi(argv[2]);
		if (fork() != 0)
			return 0;   /* the parent returns at once; the child keeps the display on */
		setsid();
		for (int t = 0; t <= secs; t += 10) {
			undim();
			sleep(10);
		}
		return 0;
	} else if (argc == 4 && !strcmp(argv[1], "tap")) {
		double x = atof(argv[2]), y = atof(argv[3]);
		finger(x, y, true, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
		usleep(60000);
		finger(x, y, false, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
	} else if ((argc == 6 || argc == 7) && !strcmp(argv[1], "swipe")) {
		swipe(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]), argc == 7 ? atoi(argv[6]) : 300);
	} else if (argc == 2 && !strcmp(argv[1], "home")) {
		button(0x0c, 0x40);
	} else if (argc == 2 && !strcmp(argv[1], "lock")) {
		button(0x0c, 0x30);   /* consumer page, power */
	} else {
		fprintf(stderr, "usage: sweetwake wake | unlock | pages [N] | awake SECONDS | tap X Y | swipe X1 Y1 X2 Y2 [MS] | home | lock\n"
		                "       (points, 414x896)\n");
		return 2;
	}
	usleep(50000);
	return 0;
}
