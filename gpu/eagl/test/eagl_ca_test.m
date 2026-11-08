// SPDX-License-Identifier: MIT
// Step 1 of the CoreAnimation bring-up: drive QuartzCore's GLES renderer (CARenderer, i.e. CA::OGL through
// -[EAGLContext getMacroContextPrivate]) with our shim, in this process only, into an IOSurface-backed FBO.
// The system OpenGLES lives in the dyld cache and cannot be replaced by path, so run with an injection build of the shim
// (EAGL_DEFS=-DEAGL_INJECT gpu/eagl/build.sh): EAGL_INJECT_LIB=<path to its OpenGLES> ./eagl_ca_test
// Exit status = failures; prints which image provides EAGLContext so a mix-up with the system library is visible.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
// The tool links the SDK's OpenGLES, so plain gl* calls would bind to the system library (which has no context here).
// Resolve the GL entry points we call from the injected shim instead.
static void *g_shim;
#define GLF(ret, name, args) static ret (*p_##name) args;
GLF(void, glGenFramebuffers, (GLsizei, GLuint *)) GLF(void, glBindFramebuffer, (GLenum, GLuint))
GLF(void, glGenRenderbuffers, (GLsizei, GLuint *)) GLF(void, glBindRenderbuffer, (GLenum, GLuint))
GLF(void, glRenderbufferStorage, (GLenum, GLenum, GLsizei, GLsizei)) GLF(void, glFramebufferRenderbuffer, (GLenum, GLenum, GLenum, GLuint))
GLF(void, glViewport, (GLint, GLint, GLsizei, GLsizei)) GLF(void, glClearColor, (GLfloat, GLfloat, GLfloat, GLfloat))
GLF(void, glClear, (GLbitfield)) GLF(void, glFinish, (void)) GLF(GLenum, glGetError, (void))
GLF(GLenum, glCheckFramebufferStatus, (GLenum))
#define LOADGL(name) p_##name = dlsym(g_shim ? g_shim : RTLD_DEFAULT, #name)
#define glGenFramebuffers p_glGenFramebuffers
#define glBindFramebuffer p_glBindFramebuffer
#define glGenRenderbuffers p_glGenRenderbuffers
#define glBindRenderbuffer p_glBindRenderbuffer
#define glRenderbufferStorage p_glRenderbufferStorage
#define glFramebufferRenderbuffer p_glFramebufferRenderbuffer
#define glViewport p_glViewport
#define glClearColor p_glClearColor
#define glClear p_glClear
#define glFinish p_glFinish
#define glGetError p_glGetError
#define glCheckFramebufferStatus p_glCheckFramebufferStatus
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
#include <sys/time.h>
#include <string.h>

@interface EAGLContext (BergamotaPrivateCA)
- (BOOL)attachImage:(NSUInteger)image toCoreSurface:(IOSurfaceRef)surface invertedRender:(BOOL)inverted;
@end

static int g_fail;
#define CHECK(cond, ...) do { if (cond) printf("PASS  "); else { g_fail++; printf("FAIL  "); } printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static CGColorRef rgb(CGFloat r, CGFloat g, CGFloat b) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat c[4] = { r, g, b, 1 };
    CGColorRef col = CGColorCreate(cs, c);
    CGColorSpaceRelease(cs);
    return col;
}
static void px(IOSurfaceRef s, int x, int y, uint8_t o[4]) {
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    memcpy(o, (uint8_t *)IOSurfaceGetBaseAddress(s) + y * IOSurfaceGetBytesPerRow(s) + x * 4, 4);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
}

// EAGL_DUMP=/dir writes every scene as /dir/<name>.ppm (viewing aid).
static void dump(IOSurfaceRef s, const char *name) {
    const char *dir = getenv("EAGL_DUMP");
    if (!dir) return;
    char path[512]; snprintf(path, sizeof path, "%s/%s.ppm", dir, name);
    FILE *f = fopen(path, "wb"); if (!f) return;
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s);
    fprintf(f, "P6\n%zu %zu\n255\n", w, h);
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
        const uint8_t *q = (const uint8_t *)IOSurfaceGetBaseAddress(s) + y * IOSurfaceGetBytesPerRow(s) + x * 4;
        fputc(q[2], f); fputc(q[1], f); fputc(q[0], f);
    }
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    fclose(f);
}
static CALayer *new_root(int W, int H, CGFloat r, CGFloat g, CGFloat b) {
    CALayer *root = [CALayer layer];
    root.bounds = CGRectMake(0, 0, W, H); root.position = CGPointMake(W / 2, H / 2);
    root.backgroundColor = rgb(r, g, b);
    return root;
}
static CGImageRef make_image(int n) {            // top half green, bottom half blue (row 0 = top of the image)
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, n, n, 8, n * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetRGBFillColor(c, 0, 0, 1, 1); CGContextFillRect(c, CGRectMake(0, 0, n, n / 2));     // CG origin bottom-left: this is the bottom half
    CGContextSetRGBFillColor(c, 0, 1, 0, 1); CGContextFillRect(c, CGRectMake(0, n / 2, n, n / 2)); // top half
    CGImageRef im = CGBitmapContextCreateImage(c);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    return im;
}
static CGImageRef make_checker(int cell) {
    int n = 256;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, n, n, 8, n * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    for (int y = 0; y < n / cell; y++) for (int x = 0; x < n / cell; x++) {
        CGFloat v = ((x + y) & 1) ? 1 : 0;
        CGContextSetRGBFillColor(c, v, v, v, 1); CGContextFillRect(c, CGRectMake(x * cell, y * cell, cell, cell));
    }
    CGImageRef im = CGBitmapContextCreateImage(c);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    return im;
}
// Render `frames` frames of `root` (mutating it with `change` between frames), return the average ms per frame.
static double render(CARenderer *r, CALayer *root, int W, int H, int frames, void (^change)(void)) {
    r.layer = root;
    struct timeval t0, t1;
    double total = 0;
    for (int i = 0; i < frames; i++) {
        if (i) change();
        [CATransaction flush];
        gettimeofday(&t0, NULL);
        [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
        [r addUpdateRect:CGRectMake(0, 0, W, H)];
        [r render];
        [r endFrame];
        glFinish();
        gettimeofday(&t1, NULL);
        total += (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_usec - t0.tv_usec) / 1e3;
    }
    return total / frames;
}

int main(void) {
    @autoreleasepool {
        const char *inj = getenv("EAGL_INJECT_LIB");       // injection build of the shim: patches the real EAGL classes at load
        if (inj && !(g_shim = dlopen(inj, RTLD_NOW))) { printf("FAIL  dlopen %s: %s\n", inj, dlerror()); return 1; }
        LOADGL(glGenFramebuffers); LOADGL(glBindFramebuffer); LOADGL(glGenRenderbuffers); LOADGL(glBindRenderbuffer);
        LOADGL(glRenderbufferStorage); LOADGL(glFramebufferRenderbuffer); LOADGL(glViewport); LOADGL(glClearColor);
        LOADGL(glClear); LOADGL(glFinish); LOADGL(glGetError); LOADGL(glCheckFramebufferStatus);
        printf("EAGLContext image: %s\n", class_getImageName(NSClassFromString(@"EAGLContext")));
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        CHECK(ctx && [EAGLContext setCurrentContext:ctx], "EAGLContext ES3 current");
        if (!ctx) return 1;
        const int W = 256, H = 256;
        NSDictionary *d = @{ (id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @4,
                             (id)kIOSurfacePixelFormat : @(0x42475241u), (id)kIOSurfaceBytesPerRow : @(W * 4) };
        IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)d);
        GLuint fbo, rb;
        glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, W, H);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
        CHECK([ctx attachImage:rb toCoreSurface:surf invertedRender:YES], "attachImage:toCoreSurface:");
        glViewport(0, 0, W, H);
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "FBO complete (rb %u)", rb);
        glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);

        CARenderer *r = [CARenderer rendererWithEAGLContext:ctx options:nil];
        CHECK(r != nil, "CARenderer rendererWithEAGLContext:options:");
        if (!r) return 1;
        r.bounds = CGRectMake(0, 0, W, H);
        glViewport(0, 0, W, H);

        // ---- 1. solid layers
        CALayer *root = new_root(W, H, 1, 0, 0);
        CALayer *box = [CALayer layer];
        box.frame = CGRectMake(64, 64, 128, 128);
        box.backgroundColor = rgb(0, 1, 0);
        [root addSublayer:box];
        double ms = render(r, root, W, H, 5, ^{ box.position = CGPointMake(128, 128); });
        uint8_t a[4], b[4];
        px(surf, 10, 10, a); px(surf, 128, 128, b);
        printf("pixel(10,10) BGRA=%d %d %d %d   pixel(128,128) BGRA=%d %d %d %d   GL error 0x%x\n", a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3], glGetError());
        CHECK(a[2] > 200 && a[1] < 50 && a[0] < 50, "root layer red reaches the IOSurface");
        CHECK(b[1] > 200 && b[2] < 50 && b[0] < 50, "sublayer green reaches the IOSurface");
        printf("TIME  solid layers (2): %.1f ms/frame\n", ms);
        dump(surf, "solid");

        // ---- 2. image layer from a CGImage: top half green, bottom half blue
        root = new_root(W, H, 0, 0, 0);
        CALayer *img = [CALayer layer];
        img.frame = CGRectMake(0, 0, 128, 128);
        CGImageRef cg = make_image(64);
        img.contents = (__bridge id)cg;
        img.magnificationFilter = kCAFilterNearest;
        [root addSublayer:img];
        CALayer *img1 = [CALayer layer];                     // same picture drawn 1:1 (128 px image into 128 pt layer) and shrunk
        img1.frame = CGRectMake(128, 0, 128, 128);
        CGImageRef cg128 = make_image(128);
        img1.contents = (__bridge id)cg128;
        [root addSublayer:img1];
        CALayer *img2 = [CALayer layer];
        img2.frame = CGRectMake(128, 128, 64, 64);
        img2.contents = (__bridge id)cg128;
        [root addSublayer:img2];
        void (*settrace)(int) = dlsym(g_shim ? g_shim : RTLD_DEFAULT, "EAGLShimSetTrace");
        if (settrace && getenv("EAGL_TRACE_IMAGE")) settrace(1);
        ms = render(r, root, W, H, 1, ^{});
        if (settrace) settrace(0);
        { uint8_t u[4], v[4], w[4]; px(surf, 192, 20, u); px(surf, 192, 110, v); px(surf, 160, 150, w);
          printf("1:1 image: top BGRA=%d %d %d  bottom BGRA=%d %d %d   shrunk(64pt of 128px): BGRA=%d %d %d\n", u[0], u[1], u[2], v[0], v[1], v[2], w[0], w[1], w[2]); }
        px(surf, 64, 20, a); px(surf, 64, 110, b);
        printf("image layer: top BGRA=%d %d %d %d  bottom BGRA=%d %d %d %d\n", a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3]);
        CHECK(a[1] > 200 && a[0] < 50 && b[0] > 200 && b[1] < 50, "CGImage layer: top green, bottom blue (orientation + upload)");
        px(surf, 200, 200, a);
        CHECK(a[0] < 5 && a[1] < 5 && a[2] < 5, "outside the image layer stays black");
        printf("TIME  image layer 128x128 (CGImage): %.1f ms/frame\n", ms);
        dump(surf, "image");

        // ---- 3. IOSurface as layer contents (texImageIOSurface:...:invert:)
        IOSurfaceRef src = IOSurfaceCreate((CFDictionaryRef)@{ (id)kIOSurfaceWidth : @(32), (id)kIOSurfaceHeight : @(32),
            (id)kIOSurfaceBytesPerElement : @4, (id)kIOSurfacePixelFormat : @(0x42475241u), (id)kIOSurfaceBytesPerRow : @(128) });
        IOSurfaceLock(src, 0, NULL);
        for (int y = 0; y < 32; y++) { uint8_t *row = (uint8_t *)IOSurfaceGetBaseAddress(src) + y * 128;
            for (int x = 0; x < 32; x++) { uint8_t *q = row + x * 4; q[0] = 0; q[1] = y < 16 ? 0 : 255; q[2] = y < 16 ? 255 : 0; q[3] = 255; } }  // top red, bottom green
        IOSurfaceUnlock(src, 0, NULL);
        root = new_root(W, H, 0, 0, 0);
        CALayer *isl = [CALayer layer];
        isl.frame = CGRectMake(0, 0, 128, 128);
        isl.contents = (__bridge id)src;
        [root addSublayer:isl];
        ms = render(r, root, W, H, 3, ^{});
        px(surf, 64, 20, a); px(surf, 64, 110, b);
        printf("IOSurface layer: top BGRA=%d %d %d %d  bottom BGRA=%d %d %d %d\n", a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3]);
        CHECK(a[2] > 200 && a[1] < 50 && b[1] > 200 && b[2] < 50, "IOSurface-contents layer: top red, bottom green");
        printf("TIME  IOSurface-contents layer: %.1f ms/frame\n", ms);
        dump(surf, "iosurface");

        // ---- 4. shadow
        root = new_root(W, H, 1, 1, 1);
        CALayer *sh = [CALayer layer];
        sh.frame = CGRectMake(88, 88, 80, 80);
        sh.backgroundColor = rgb(1, 0, 0);
        sh.shadowOpacity = 1; sh.shadowRadius = 12; sh.shadowOffset = CGSizeMake(0, 0); sh.shadowColor = rgb(0, 0, 0);
        [root addSublayer:sh];
        ms = render(r, root, W, H, 3, ^{});
        px(surf, 84, 128, a); px(surf, 4, 128, b);
        printf("shadow: near edge BGRA=%d %d %d  far BGRA=%d %d %d  GL error 0x%x\n", a[0], a[1], a[2], b[0], b[1], b[2], glGetError());
        CHECK(a[1] < 235 && b[1] > 250, "shadow darkens the area next to the layer, far background stays white");
        printf("TIME  shadow layer (radius 12): %.1f ms/frame\n", ms);
        dump(surf, "shadow");

        // ---- 5. blur / vibrancy through CAFilter (private class used by UIKit/SpringBoard)
        Class CAFilterClass = NSClassFromString(@"CAFilter");
        CHECK(CAFilterClass != Nil, "CAFilter class available");
        if (CAFilterClass) {
            root = new_root(W, H, 0, 0, 0);
            CALayer *stripes = [CALayer layer];                 // hard-edged white/black checker underneath
            stripes.frame = CGRectMake(0, 0, W, H);
            CGImageRef chk = make_checker(64);
            stripes.contents = (__bridge id)chk; stripes.magnificationFilter = kCAFilterNearest;
            [root addSublayer:stripes];
            CALayer *glass = [CALayer layer];
            glass.frame = CGRectMake(32, 32, 192, 192);
            id blur = [CAFilterClass performSelector:@selector(filterWithType:) withObject:@"gaussianBlur"];
            [blur setValue:@(8.0) forKey:@"inputRadius"];
            glass.backgroundFilters = @[ blur ];
            [root addSublayer:glass];
            ms = render(r, root, W, H, 3, ^{});
            uint8_t in1[4], out1[4];
            px(surf, 128, 128, in1);        // inside the glass, away from checker edges? (checker cell edge at 128)
            px(surf, 12, 12, out1);         // outside the glass: sharp black or white
            int outSharp = (out1[1] < 10 || out1[1] > 245);
            printf("backdrop blur: inside BGRA=%d %d %d  outside BGRA=%d %d %d\n", in1[0], in1[1], in1[2], out1[0], out1[1], out1[2]);
            CHECK(outSharp && in1[1] > 30 && in1[1] < 225, "gaussianBlur backgroundFilter blurs the checker edge under the glass layer");
            printf("TIME  backdrop gaussianBlur(8) 192x192: %.1f ms/frame\n", ms);
        dump(surf, "blur");
            // vibrancy-like: colour matrix + luminance on a layer
            id lum = [CAFilterClass performSelector:@selector(filterWithType:) withObject:@"colorSaturate"];
            [lum setValue:@(0.0) forKey:@"inputAmount"];
            CALayer *grey = [CALayer layer];
            grey.frame = CGRectMake(96, 96, 64, 64);
            grey.backgroundColor = rgb(1, 0, 0);
            grey.filters = @[ lum ];
            [root addSublayer:grey];
            ms = render(r, root, W, H, 3, ^{});
            px(surf, 128, 128, a);
            printf("colorSaturate(0) on a red layer: BGRA=%d %d %d\n", a[0], a[1], a[2]);
            CHECK(abs(a[0] - a[2]) < 40 && abs(a[1] - a[2]) < 40, "colorSaturate 0 desaturates the red layer");
            printf("TIME  colorSaturate filter: %.1f ms/frame\n", ms);
        dump(surf, "saturate");
        }

        // ---- 6. many layers
        root = new_root(W, H, 0, 0, 0);
        NSMutableArray *ls = [NSMutableArray array];
        for (int i = 0; i < 300; i++) {
            CALayer *l = [CALayer layer];
            l.frame = CGRectMake((i * 37) % 220, (i * 53) % 220, 32, 32);
            l.backgroundColor = rgb((i % 3) == 0, (i % 3) == 1, (i % 3) == 2);
            l.cornerRadius = (i % 2) ? 8 : 0;
            l.opacity = 0.8;
            [root addSublayer:l]; [ls addObject:l];
        }
        ms = render(r, root, W, H, 3, ^{ for (CALayer *l in ls) l.position = CGPointMake(l.position.x + 1, l.position.y); });
        px(surf, 100, 100, a);
        CHECK(a[0] + a[1] + a[2] > 100, "300 translucent rounded layers drew something (BGRA %d %d %d)", a[0], a[1], a[2]);
        printf("TIME  300 layers (alpha, half with corner radius): %.1f ms/frame\n", ms);
        dump(surf, "many");
        printf("GL error at the end: 0x%x\n", glGetError());
    }
    printf("RESULT: %d failed\n", g_fail);
    return g_fail;
}
