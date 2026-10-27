/*
 * SweetMetalProbe: the C1 stub bundle.
 *
 * Metal's discovery (verified in Bergamota's GPU_PHASE0_DISCOVERY.md):
 *
 *   MTLCreateSystemDefaultDevice -> _MTLRegisterDevices
 *     -> IOServiceMatching("IOAcceleratorES"), per service _getMetalPluginClassForService:
 *        read "MetalPluginName", NSBundle /System/Library/Extensions/<name>.bundle,
 *        principal class (or "MetalPluginClassName") must subclass _MTLDevice,
 *        then [[Class alloc] initWithAcceleratorPort:service] -> MTLAddDevice.
 *
 * So the only thing this bundle has to prove is that it gets loaded and that its class is asked
 * to init. It returns nil from -initWithAcceleratorPort:, which Metal treats as "no device": the
 * renderers stay exactly as they are, nothing switches to Metal, the UI cannot regress.
 *
 * The class is created with the ObjC runtime because _MTLDevice is a private class with no
 * headers in this SDK; subclassing it by name keeps us independent of its ivars.
 *
 * Output goes to /dev/console: fd 1 is not wired to anything under launchd (see NOTES).
 */

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <objc/runtime.h>
#include <string.h>
#include <unistd.h>

static void
say(const char *s)
{
	int fd = open("/dev/console", O_WRONLY | O_NOCTTY);

	if (fd >= 0) {
		(void)write(fd, s, strlen(s));
		(void)close(fd);
	}
}

static id
probe_init(id self, SEL cmd, unsigned int port)
{
	(void)self;
	(void)cmd;
	char buf[96];
	int n = snprintf(buf, sizeof(buf),
	    "SWEET METAL: -initWithAcceleratorPort:%u called, declining (nil)\n", port);
	if (n > 0) {
		say(buf);
	}
	return nil;
}

__attribute__((constructor))
static void
probe_ctor(void)
{
	Class base = objc_getClass("_MTLDevice");

	if (base == Nil) {
		say("SWEET METAL: bundle loaded, but there is no _MTLDevice class\n");
		return;
	}
	Class cls = objc_allocateClassPair(base, "SweetMetalDevice", 0);
	if (cls == Nil) {
		say("SWEET METAL: bundle loaded, but objc_allocateClassPair failed\n");
		return;
	}
	class_addMethod(cls, sel_registerName("initWithAcceleratorPort:"), (IMP)probe_init, "@@:I");
	objc_registerClassPair(cls);
	say("SWEET METAL: bundle loaded, SweetMetalDevice registered (_MTLDevice subclass)\n");
}
