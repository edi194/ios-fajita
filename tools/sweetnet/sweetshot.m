/*
 * sweetshot [OUT.png] [scale] [display]: screenshot of the panel over SSH, for testing without a camera.
 * First choice is the kernel's copy of the scanned frame (sysctl kern.sweet_fb_shot, xnu 0224: exactly what the
 * panel shows, whatever composed it); without it, the render server renders the display (CARenderServerRenderDisplay,
 * as UIGetScreenImage does; black under the ES compositor). Writes a PNG (default /private/var/tmp/shot.png).
 * scale 2..8 divides the size (default 3: 375x812). iOS 18, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdlib.h>
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);    /* not in the iOS SDK */

extern mach_port_t CARenderServerGetServerPort(void);
extern void CARenderServerRenderDisplay(mach_port_t port, CFStringRef display, IOSurfaceRef surface, int x, int y);

/* BGRA rows -> opaque RGBA PNG, every step-th pixel; 0 = written */
static int write_png(const char *out, const uint8_t *bgra, size_t bpr, size_t w, size_t h, size_t step)
{
	size_t ow = w / step, oh = h / step, nz = 0;
	uint8_t *px = malloc(ow * oh * 4);
	for (size_t y = 0; y < oh; y++) {
		for (size_t x = 0; x < ow; x++) {
			const uint8_t *p = bgra + (y * step) * bpr + (x * step) * 4;
			uint8_t *q = px + (y * ow + x) * 4;
			q[0] = p[2]; q[1] = p[1]; q[2] = p[0]; q[3] = 255;
			nz += (p[0] | p[1] | p[2]) != 0;
		}
	}
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef cg = CGBitmapContextCreate(px, ow, oh, 8, ow * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
	CGImageRef img = CGBitmapContextCreateImage(cg);
	unlink(out);    /* a damaged old file can refuse an overwrite */
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)out, strlen(out), false);
	CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
	if (!d || !img) {
		fprintf(stderr, "sweetshot: cannot write %s\n", out);
		return -1;
	}
	CGImageDestinationAddImage(d, img, NULL);
	bool ok = CGImageDestinationFinalize(d);
	printf("sweetshot: %s %zux%zu, %zu%% non-black %s\n", out, ow, oh, nz * 100 / (ow * oh), ok ? "ok" : "FAILED");
	return ok ? 0 : -1;
}

/* 0 = written, 1 = no kernel screenshot (older kernel), -1 = failed */
static int from_kernel(const char *out, int scale)
{
	unsigned int sc = (unsigned)scale;
	sysctlbyname("kern.sweet_fb_shot_scale", NULL, NULL, &sc, sizeof sc);
	size_t len = 0;
	if (sysctlbyname("kern.sweet_fb_shot", NULL, &len, NULL, 0) != 0 || len < 16)
		return 1;
	uint8_t *buf = malloc(len);
	if (sysctlbyname("kern.sweet_fb_shot", buf, &len, NULL, 0) != 0 || len < 16) {
		perror("sweetshot: kern.sweet_fb_shot");
		return -1;
	}
	uint32_t hdr[4];
	memcpy(hdr, buf, sizeof hdr);
	if (hdr[0] != 0x544f4853u || (size_t)hdr[3] * hdr[2] + 16 > len) {
		fprintf(stderr, "sweetshot: bad kern.sweet_fb_shot header %08x %ux%u\n", hdr[0], hdr[1], hdr[2]);
		return -1;
	}
	return write_png(out, buf + 16, hdr[3], hdr[1], hdr[2], 1);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *out = argc > 1 ? argv[1] : "/private/var/tmp/shot.png";
		int scale = argc > 2 ? atoi(argv[2]) : 3;
		if (scale < 2 || scale > 8)
			scale = 3;
		int r = from_kernel(out, scale);
		if (r <= 0)
			return r == 0 ? 0 : 1;

		/* no kernel screenshot: the panel as CoreAnimation renders it (1125x2436: iPhone11,8 userland at 3x) */
		int w = 1125, h = 2436;
		NSDictionary *props = @{
			(id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
			(id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'), (id)kIOSurfaceBytesPerRow: @(w * 4),
			(id)kIOSurfaceAllocSize: @(w * h * 4),
		};
		IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		if (!s) {
			fprintf(stderr, "sweetshot: IOSurfaceCreate failed\n");
			return 1;
		}
		mach_port_t port = CARenderServerGetServerPort();
		if (port == MACH_PORT_NULL) {      /* an SSH shell may not see it through QuartzCore's cache: ask launchd */
			kern_return_t kr = bootstrap_look_up(bootstrap_port, "com.apple.CARenderServer", &port);
			if (kr != KERN_SUCCESS || port == MACH_PORT_NULL) {
				fprintf(stderr, "sweetshot: no render server port (bootstrap_look_up %#x)\n", kr);
				return 1;
			}
		}
		CFStringRef disp = argc > 3 ? CFStringCreateWithCString(NULL, argv[3], kCFStringEncodingUTF8) : CFSTR("LCD");
		CARenderServerRenderDisplay(port, disp, s, 0, 0);
		IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
		r = write_png(out, IOSurfaceGetBaseAddress(s), IOSurfaceGetBytesPerRow(s), w, h, (size_t)scale);
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		return r == 0 ? 0 : 1;
	}
}
