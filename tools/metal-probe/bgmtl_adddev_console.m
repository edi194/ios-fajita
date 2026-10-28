// SPDX-License-Identifier: MIT
//
// bgmtl_adddev on this port: Chlorophyll's test, unchanged in substance, with two additions that
// matter here:
//
//   1. stdout/stderr are redirected to /dev/console before anything prints. Under launchd fd 1
//      goes nowhere (see NOTES - this cost us several boots), and the console is what the kernel
//      ring captures.
//   2. it runs in this process only: MTLAddDevice registers the device in the local Metal device
//      list, no IOKit service is touched, so a crash here cannot take the UI down.
//
// Original: Chlorophyll/test/bgmtl_adddev.m (MIT).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

extern id bgmtl_create_device(void);

static void
console_redirect(void)
{
	int fd = open("/dev/console", O_WRONLY | O_NOCTTY);

	if (fd >= 0) {
		dup2(fd, 1);
		dup2(fd, 2);
		if (fd > 2) {
			close(fd);
		}
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
}

int
main(int argc, char **argv)
{
	console_redirect();
	printf("SWEET METAL: bgmtl_adddev starting\n");
	@autoreleasepool {
		void (*add)(id) = dlsym(RTLD_DEFAULT, "MTLAddDevice");
		NSArray *(*copy_all)(void) = dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
		id (*create_default)(void) = dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
		printf("symbols: MTLAddDevice %p, MTLCopyAllDevices %p, MTLCreateSystemDefaultDevice %p\n",
		    add, copy_all, create_default);
		NSArray *before = copy_all ? copy_all() : nil;
		printf("devices before: %lu\n", (unsigned long)[before count]);
		/*
		 * Metal builds its device table lazily, on the first MTLCreateSystemDefaultDevice /
		 * MTLCopyAllDevices call. MTLCopyAllDevices does not exist on iOS 16 and we call
		 * MTLAddDevice before anything else, so the table is still NULL and MTLAddDevice asserts
		 * (`_deviceArray != NULL`, MTLDevice.m:833). Asking for the default device first
		 * initialises it (and returns nil - there is no device yet).
		 */
		id def0 = create_default ? create_default() : nil;
		printf("device table initialised via MTLCreateSystemDefaultDevice: %s\n",
		    def0 ? [[def0 name] UTF8String] : "nil (as expected)");
		id dev = bgmtl_create_device();
		printf("created %s\n", dev ? [[dev name] UTF8String] : "nil");
		if (!dev) {
			printf("SWEET METAL: bgmtl_create_device returned nil - the GPU open failed\n");
			return 2;
		}
		if (!add) {
			printf("SWEET METAL: no MTLAddDevice symbol on this iOS - cannot register\n");
			return 2;
		}
		printf("calling MTLAddDevice ...\n");
		add(dev);
		printf("MTLAddDevice returned\n");
		NSArray *after = copy_all ? copy_all() : nil;
		printf("devices after: %lu\n", (unsigned long)[after count]);
		for (id d in after) {
			printf("  %s (%s)\n", [[d name] UTF8String], class_getName([d class]));
		}
		id def = create_default ? create_default() : nil;
		printf("MTLCreateSystemDefaultDevice: %s (%s)\n",
		    def ? [[def name] UTF8String] : "nil", def ? class_getName([def class]) : "-");
		if (def) {
			printf("maxThreads %lu x %lu, maxBufferLength %llu, unified %d, Apple2 %d Apple4 %d Common1 %d\n",
			    (unsigned long)[def maxThreadsPerThreadgroup].width,
			    (unsigned long)[def maxThreadsPerThreadgroup].height,
			    (unsigned long long)[def maxBufferLength], (int)[def hasUnifiedMemory],
			    (int)[def supportsFamily:MTLGPUFamilyApple2],
			    (int)[def supportsFamily:MTLGPUFamilyApple4],
			    (int)[def supportsFamily:MTLGPUFamilyCommon1]);
			id q = [def newCommandQueue];
			printf("queue via default device: %s\n", q ? class_getName([q class]) : "nil");
		}
	}
	printf("SWEET METAL: bgmtl_adddev done\n");
	return 0;
}
