/*
 * sweettouch: synthetic touch and buttons over SSH, for testing without hands on the phone.
 *   sweettouch tap X Y                     one finger, points (375x812 space of the iPhone11,8 userland)
 *   sweettouch swipe X1 Y1 X2 Y2 [MS]      drag, default 300 ms
 *   sweettouch home | lock                 Home (menu) / Power (lock) button press
 * Events go into the HID event system (IOHIDEventSystemClientDispatchEvent) like a digitizer's, with the
 * entitlement com.apple.private.hid.client.event-dispatch (touch.entitlements). iOS 18, arm64e + pacstrip.
 */
#include <CoreFoundation/CoreFoundation.h>
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

#define W 375.0
#define H 812.0
#define kIOHIDDigitizerTransducerTypeHand 3
#define kIOHIDDigitizerEventRange 0x1
#define kIOHIDDigitizerEventTouch 0x2
#define kIOHIDDigitizerEventPosition 0x4
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0xb0019
#define SENDER 0x8000000817319372ULL            /* any fixed id: events are attributed to this "digitizer" */

static IOHIDEventSystemClientRef cli;

static void finger(double x, double y, bool touch, uint32_t mask)
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

static void button(uint32_t page, uint32_t usage)
{
	for (int down = 1; down >= 0; down--) {
		IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, down, 0);
		IOHIDEventSetSenderID(e, SENDER);
		IOHIDEventSystemClientDispatchEvent(cli, e);
		CFRelease(e);
		usleep(80000);
	}
}

int main(int argc, char **argv)
{
	cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
	if (!cli) {
		fprintf(stderr, "sweettouch: no HID event system client\n");
		return 1;
	}
	if (argc == 4 && !strcmp(argv[1], "tap")) {
		double x = atof(argv[2]), y = atof(argv[3]);
		finger(x, y, true, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
		usleep(60000);
		finger(x, y, false, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
	} else if ((argc == 6 || argc == 7) && !strcmp(argv[1], "swipe")) {
		double x1 = atof(argv[2]), y1 = atof(argv[3]), x2 = atof(argv[4]), y2 = atof(argv[5]);
		int ms = argc == 7 ? atoi(argv[6]) : 300, steps = ms / 8 > 2 ? ms / 8 : 2;
		finger(x1, y1, true, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
		for (int i = 1; i <= steps; i++) {
			usleep(8000);
			finger(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps, true, kIOHIDDigitizerEventPosition);
		}
		finger(x2, y2, false, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
	} else if (argc == 2 && !strcmp(argv[1], "home")) {
		button(0x0c, 0x40);     /* consumer page, menu */
	} else if (argc == 2 && !strcmp(argv[1], "lock")) {
		button(0x0c, 0x30);     /* consumer page, power */
	} else {
		fprintf(stderr, "usage: sweettouch tap X Y | swipe X1 Y1 X2 Y2 [MS] | home | lock   (points, 375x812)\n");
		return 2;
	}
	usleep(50000);
	return 0;
}
