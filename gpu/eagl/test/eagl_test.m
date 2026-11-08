// SPDX-License-Identifier: MIT
// Standalone test for the Bergamota OpenGLES shim: GLES2/GLES3 rendering into IOSurfaces and read back.
// Links the shim by path (never the system OpenGLES.framework). Exit status = number of failed checks.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/EAGLIOSurface.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <OpenGLES/ES1/gl.h>
#import "eagl_private.h"
#include <stdio.h>
#include <string.h>
#include <sys/time.h>

static int g_fail, g_pass;
static const char *g_dump;     // --dump FILE.ppm: write the ES2 frame
static int g_bench;            // --bench: full-screen (750x1334) textured+shaded frames
#define CHECK(cond, ...) do { if (cond) { g_pass++; printf("PASS  "); } else { g_fail++; printf("FAIL  "); } printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

// A stand-in for CAEAGLLayer: answers the selectors the shim queries and records the presented IOSurface.
@interface FakeDrawable : NSObject <EAGLDrawable>
@property (nonatomic, assign) CGRect bounds;
@property (nonatomic, assign) CGFloat contentsScale;
@property (nonatomic, assign) BOOL opaque;
@property (nonatomic, copy) NSDictionary *drawableProperties;
@property (nonatomic, assign) IOSurfaceRef presented;
@property (nonatomic, assign) int presentCount;
@end
@implementation FakeDrawable
- (BOOL)isOpaque { return _opaque; }
- (void)setContents:(id)c { _presented = (IOSurfaceRef)c; _presentCount++; }
@end

static IOSurfaceRef mk_surface(int w, int h) {
    NSDictionary *d = @{ (id)kIOSurfaceWidth : @(w), (id)kIOSurfaceHeight : @(h), (id)kIOSurfaceBytesPerElement : @4,
                         (id)kIOSurfacePixelFormat : @(0x42475241u), (id)kIOSurfaceBytesPerRow : @(((w * 4) + 63) & ~63) };
    return IOSurfaceCreate((CFDictionaryRef)d);
}
static void surf_pixel(IOSurfaceRef s, int x, int y, uint8_t out[4]) {   // BGRA bytes
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *p = (const uint8_t *)IOSurfaceGetBaseAddress(s) + y * IOSurfaceGetBytesPerRow(s) + x * 4;
    memcpy(out, p, 4);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
}
// The shim exports no table; resolve offsets the way QuartzCore does not: from the known stub offsets (22H352).
static unsigned macro_find(const char *n) {
    static const struct { const char *n; unsigned off; } t[] = { { "glClearColor", 0x68 }, { "glClear", 0x58 }, { "glTexImage2D", 0x970 }, { "glCompressedTexImage2D", 0xbe8 } };
    for (unsigned i = 0; i < sizeof t / sizeof *t; i++) if (!strcmp(t[i].n, n)) return t[i].off;
    return 0;
}
static int near(int a, int b) { return abs(a - b) <= 2; }

static GLuint compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024]; glGetShaderInfoLog(s, sizeof log, NULL, log); printf("shader log: %s\n", log); }
    return ok ? s : 0;
}
static GLuint program(const char *vs, const char *fs) {
    GLuint v = compile(GL_VERTEX_SHADER, vs), f = compile(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) return 0;
    GLuint p = glCreateProgram();
    glAttachShader(p, v); glAttachShader(p, f);
    glBindAttribLocation(p, 0, "pos");
    glLinkProgram(p);
    GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    return ok ? p : 0;
}

static const char *VS100 = "attribute vec2 pos; void main() { gl_Position = vec4(pos, 0.0, 1.0); }";
static const char *FS100 = "precision mediump float; uniform vec4 color; void main() { gl_FragColor = color; }";
static const char *VS300 = "#version 300 es\nlayout(location=0) in vec2 pos; void main() { gl_Position = vec4(pos, 0.0, 1.0); }";
static const char *FS300 = "#version 300 es\nprecision mediump float; uniform vec4 color; out vec4 o; void main() { o = color; }";

static void draw_triangle(GLuint prog, float r, float g, float b) {
    static const GLfloat v[] = { -0.8f, -0.2f, 0.8f, -0.2f, 0.0f, 0.9f };
    glUseProgram(prog);
    glUniform4f(glGetUniformLocation(prog, "color"), r, g, b, 1.0f);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, v);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

static void test_present(EAGLRenderingAPI api, const char *vs, const char *fs, const char *tag) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:api];
    CHECK(ctx != nil, "[%s] EAGLContext initWithAPI:%d", tag, (int)api);
    if (!ctx) return;
    CHECK([EAGLContext setCurrentContext:ctx] && [EAGLContext currentContext] == ctx, "[%s] setCurrentContext", tag);
    printf("      GL_VERSION  : %s\n      GL_RENDERER : %s\n      GLSL        : %s\n",
           glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_SHADING_LANGUAGE_VERSION));

    FakeDrawable *dr = [[FakeDrawable alloc] init];
    dr.bounds = CGRectMake(0, 0, 128, 128); dr.contentsScale = 1; dr.opaque = YES;
    dr.drawableProperties = @{ kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8 };
    GLuint fbo, rb;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    BOOL st = [ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:dr];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    CHECK(st && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "[%s] renderbufferStorage:fromDrawable: + FBO complete", tag);
    GLint rw = 0; glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &rw);
    CHECK(rw == 128, "[%s] renderbuffer width %d", tag, rw);

    GLuint prog = program(vs, fs);
    CHECK(prog != 0, "[%s] shader compile+link", tag);
    if (prog) {
        glViewport(0, 0, 128, 128);
        glClearColor(0, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT);
        draw_triangle(prog, 1, 0, 0);
        CHECK([ctx presentRenderbuffer:GL_RENDERBUFFER] && dr.presentCount == 1 && dr.presented != NULL, "[%s] presentRenderbuffer delivers an IOSurface", tag);
        if (dr.presented) {
            uint8_t top[4], bot[4], corner[4];
            surf_pixel(dr.presented, 64, 20, top);
            surf_pixel(dr.presented, 64, 100, bot);
            surf_pixel(dr.presented, 2, 2, corner);
            CHECK(IOSurfaceGetWidth(dr.presented) == 128 && IOSurfaceGetPixelFormat(dr.presented) == 'BGRA', "[%s] surface 128x128 BGRA", tag);
            CHECK(near(top[2], 255) && near(top[1], 0) && near(top[0], 0) && near(top[3], 255), "[%s] triangle apex is red at the TOP (BGRA %d %d %d %d)", tag, top[0], top[1], top[2], top[3]);
            CHECK(near(bot[0], 255) && near(bot[2], 0) && near(bot[3], 255), "[%s] below the triangle is the blue clear colour (BGRA %d %d %d %d)", tag, bot[0], bot[1], bot[2], bot[3]);
            CHECK(near(corner[0], 255) && near(corner[2], 0), "[%s] corner is blue", tag);
        }
        if (g_dump && api == kEAGLRenderingAPIOpenGLES2 && dr.presented) {
            IOSurfaceLock(dr.presented, kIOSurfaceLockReadOnly, NULL);
            FILE *f = fopen(g_dump, "wb");
            if (f) {
                fprintf(f, "P6\n128 128\n255\n");
                for (int y = 0; y < 128; y++) for (int x = 0; x < 128; x++) {
                    const uint8_t *q = (const uint8_t *)IOSurfaceGetBaseAddress(dr.presented) + y * IOSurfaceGetBytesPerRow(dr.presented) + x * 4;
                    fputc(q[2], f); fputc(q[1], f); fputc(q[0], f);
                }
                fclose(f);
            }
            IOSurfaceUnlock(dr.presented, kIOSurfaceLockReadOnly, NULL);
        }
        // timing: 20 frames of clear+triangle+present
        struct timeval a, b; gettimeofday(&a, NULL);
        for (int i = 0; i < 20; i++) { glClear(GL_COLOR_BUFFER_BIT); draw_triangle(prog, 1, 0, 0); [ctx presentRenderbuffer:GL_RENDERBUFFER]; }
        gettimeofday(&b, NULL);
        printf("      20 frames 128x128 (draw+readback+present): %.1f ms/frame\n", ((b.tv_sec - a.tv_sec) * 1e3 + (b.tv_usec - a.tv_usec) / 1e3) / 20);
    }
    [EAGLContext setCurrentContext:nil];
    CHECK([EAGLContext currentContext] == nil, "[%s] setCurrentContext:nil", tag);
    [dr release]; [ctx release];
}

static void test_attach_and_texture(void) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:ctx];
    // attachImage:toCoreSurface:invertedRender: -> render, glFinish, surface holds the pixels
    IOSurfaceRef surf = mk_surface(64, 64);
    GLuint fbo, rb;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    BOOL at = [ctx attachImage:rb toCoreSurface:surf invertedRender:NO];
    CHECK(at, "attachImage:toCoreSurface:invertedRender:");
    glClearColor(0, 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    glScissor(0, 0, 64, 16); glEnable(GL_SCISSOR_TEST);        // bottom 16 GL rows magenta
    glClearColor(1, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT); glDisable(GL_SCISSOR_TEST);
    glFinish();
    uint8_t p[4], q[4];
    surf_pixel(surf, 32, 8, p);                                  // top rows of the surface = top of GL image: green
    surf_pixel(surf, 32, 60, q);                                 // bottom rows: magenta
    CHECK(near(p[1], 255) && near(p[0], 0) && near(p[2], 0), "glFinish syncs the attached IOSurface, top row green (BGRA %d %d %d %d)", p[0], p[1], p[2], p[3]);
    CHECK(near(q[2], 255) && near(q[0], 255) && near(q[1], 0), "surface is top-down: bottom row magenta (BGRA %d %d %d %d)", q[0], q[1], q[2], q[3]);

    // texImageIOSurface:...plane:invert:
    IOSurfaceRef src = mk_surface(32, 32);
    IOSurfaceLock(src, 0, NULL);
    for (int y = 0; y < 32; y++) {
        uint8_t *row = (uint8_t *)IOSurfaceGetBaseAddress(src) + y * IOSurfaceGetBytesPerRow(src);
        for (int x = 0; x < 32; x++) { uint8_t *px = row + x * 4; px[0] = 10; px[1] = 20; px[2] = y < 16 ? 30 : 200; px[3] = 255; }
    }
    IOSurfaceUnlock(src, 0, NULL);
    GLuint tex, fbo2;
    glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    BOOL ti = [ctx texImageIOSurface:src target:GL_TEXTURE_2D internalFormat:GL_RGBA width:32 height:32 format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0];
    CHECK(ti, "texImageIOSurface:...plane:");
    glGenFramebuffers(1, &fbo2); glBindFramebuffer(GL_FRAMEBUFFER, fbo2);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    uint8_t px[4];
    glReadPixels(5, 5, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);        // GL row 5 = surface row 5 (not inverted): R=30
    CHECK(px[0] == 30 && px[1] == 20 && px[2] == 10 && px[3] == 255, "texture holds the surface pixels, BGRA swizzled to RGBA (RGBA %d %d %d %d)", px[0], px[1], px[2], px[3]);
    ti = [ctx texImageIOSurface:src target:GL_TEXTURE_2D internalFormat:GL_RGBA width:32 height:32 format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0 invert:NO];
    glReadPixels(5, 5, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    CHECK(ti && px[0] == 200, "invert:NO flips rows (R=%d)", px[0]);

    // CoreAnimation's other uploads: A8 mask, LA8, RGBA16F half float (256x1 gradient table), RGB565
    {
        struct { uint32_t pf; int bpp; GLenum ifmt, fmt, type; const char *name; } cases[] = {
            { 'L008', 1, GL_ALPHA, GL_ALPHA, GL_UNSIGNED_BYTE, "A8" },
            { '2C08', 2, GL_LUMINANCE_ALPHA, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, "LA8" },
            { 'RGhA', 8, GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, "RGBA16F" },
            { 'L565', 2, GL_RGB565, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, "RGB565" } };
        for (int i = 0; i < 4; i++) {
            NSDictionary *d = @{ (id)kIOSurfaceWidth : @(37), (id)kIOSurfaceHeight : @(5), (id)kIOSurfaceBytesPerElement : @(cases[i].bpp),
                                 (id)kIOSurfacePixelFormat : @(cases[i].pf), (id)kIOSurfaceBytesPerRow : @(((37 * cases[i].bpp) + 63) & ~63) };
            IOSurfaceRef sf = IOSurfaceCreate((CFDictionaryRef)d);
            GLuint t2; glGenTextures(1, &t2); glBindTexture(GL_TEXTURE_2D, t2);
            BOOL ok = sf && [ctx texImageIOSurface:sf target:GL_TEXTURE_2D internalFormat:cases[i].ifmt width:37 height:5 format:cases[i].fmt type:cases[i].type plane:0 invert:NO];
            CHECK(ok && glGetError() == GL_NO_ERROR, "texImageIOSurface %s surface (pixel format %08x)", cases[i].name, cases[i].pf);
            if (sf) CFRelease(sf);
        }
    }
    // attachImage with a TARGET (what CoreAnimation's render server passes): the texture bound at GL_TEXTURE_2D gets the surface as storage
    {
        IOSurfaceRef s2 = mk_surface(48, 32);
        GLuint t3, f3; glGenTextures(1, &t3); glBindTexture(GL_TEXTURE_2D, t3);
        BOOL ok = [ctx attachImage:GL_TEXTURE_2D toCoreSurface:s2 invertedRender:NO];
        glGenFramebuffers(1, &f3); glBindFramebuffer(GL_FRAMEBUFFER, f3);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t3, 0);
        CHECK(ok && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "attachImage:GL_TEXTURE_2D gives the bound texture storage (FBO complete)");
        glViewport(0, 0, 48, 32); glClearColor(1, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
        glScissor(0, 0, 48, 8); glEnable(GL_SCISSOR_TEST); glClearColor(0, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT); glDisable(GL_SCISSOR_TEST);   // bottom GL rows blue
        glFinish();
        uint8_t a3[4], b3[4]; surf_pixel(s2, 24, 2, a3); surf_pixel(s2, 24, 29, b3);
        CHECK(near(a3[0], 255) && near(a3[2], 0) && near(b3[2], 255) && near(b3[0], 0), "texture-target attach syncs to the surface, inverted:NO keeps the GL row order (bottom GL rows first) (top BGRA %d %d %d, bottom %d %d %d)", a3[0], a3[1], a3[2], b3[0], b3[1], b3[2]);
        { printf("      surface rows (BGRA at x=24):"); for (int yy = 0; yy < 32; yy += 3) { uint8_t q[4]; surf_pixel(s2, 24, yy, q); printf(" r%d=%d,%d,%d", yy, q[0], q[1], q[2]); } printf("\n"); }
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        CFRelease(s2);
    }
    // sharegroup: a texture created in ctx is visible in a second context of the same group
    EAGLContext *c2 = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3 sharegroup:ctx.sharegroup];
    CHECK(c2 != nil && c2.sharegroup == ctx.sharegroup, "sharegroup shared");
    [EAGLContext setCurrentContext:c2];
    CHECK(glIsTexture(tex) == GL_TRUE, "texture visible through the sharegroup");
    EAGLContext *c3 = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:c3];
    CHECK(glIsTexture(tex) == GL_FALSE, "texture NOT visible in an unrelated context");
    [EAGLContext setCurrentContext:nil];
    [c3 release]; [c2 release]; [ctx release];
    CFRelease(surf); CFRelease(src);
}

// QuartzCore's way into GL: EAGLMacroContext slots called as fn(rend, args...). Offsets are from the real stubs (22H352).
static void test_macro_context(void) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:ctx];
    void **m = (void **)[ctx getMacroContextPrivate];
    CHECK(m != NULL && m[0] != NULL, "getMacroContextPrivate returns a populated block");
    if (!m) return;
    #define SLOT(off) (*(void **)((char *)m + (off)))
    const unsigned char *(*get_string)(void *, unsigned) = SLOT(0x3b0);        // glGetString (CA calls this first)
    const char *rn = (const char *)get_string(m[0], GL_RENDERER);
    CHECK(rn && !strcmp(rn, (const char *)glGetString(GL_RENDERER)), "macro slot 0x3b0 = glGetString (%s)", rn ? rn : "null");
    GLuint fbo, rb;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 16, 16);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    void (*clear_color)(void *, float, float, float, float) = SLOT(macro_find("glClearColor"));
    void (*clear)(void *, unsigned) = SLOT(macro_find("glClear"));
    clear_color(m[0], 0.0f, 1.0f, 0.0f, 1.0f); clear(m[0], GL_COLOR_BUFFER_BIT);
    uint8_t px[4] = {0};
    glReadPixels(3, 3, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    CHECK(px[1] == 255 && px[0] == 0, "glClearColor/glClear through macro slots (float args after rend) (RGBA %d %d %d %d)", px[0], px[1], px[2], px[3]);
    // 9-argument call (stack arguments): glTexImage2D through the wide wrapper
    void (*tex_image_2d)(void *, unsigned, int, int, int, int, int, unsigned, unsigned, const void *) = SLOT(macro_find("glTexImage2D"));
    // 8-argument call (the 8th, the data pointer, is on the stack): glCompressedTexImage2D with one ETC2 block through the macro context
    {
        void (*cti)(void *, unsigned, int, unsigned, int, int, int, int, const void *) = SLOT(macro_find("glCompressedTexImage2D"));
        GLuint ct; glGenTextures(1, &ct); glBindTexture(GL_TEXTURE_2D, ct);
        static const uint8_t blk[8] = { 0xff, 0x80, 0x40, 0, 0, 0, 0, 0 };
        glGetError();
        cti(m[0], GL_TEXTURE_2D, 0, 0x9274 /* COMPRESSED_RGB8_ETC2 */, 4, 4, 0, 8, blk);
        CHECK(glGetError() == GL_NO_ERROR, "glCompressedTexImage2D (8 args) through the macro context");
    }
    GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    uint32_t texel[4] = { 0xff0000ffu, 0xff0000ffu, 0xff0000ffu, 0xff0000ffu };   // RGBA bytes ff 00 00 ff = red
    tex_image_2d(m[0], GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, texel);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    CHECK(px[0] == 255 && px[1] == 0 && px[2] == 0, "glTexImage2D (9 args, stack) through the macro context (RGBA %d %d %d %d)", px[0], px[1], px[2], px[3]);
    [EAGLContext setCurrentContext:nil]; [ctx release];
}

// Sampling a texture with NEAREST and LINEAR filters (CoreAnimation draws 1:1 and magnified layers with NEAREST).
static void test_sampling(void) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:ctx];
    GLuint fbo, rb, tex;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    uint32_t texels[4] = { 0xff00ff00u, 0xff0000ffu, 0xffff0000u, 0xff00ffffu };   // RGBA bytes: green, red, blue, yellow
    glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
    const char *vs = "attribute vec2 pos; varying vec2 uv; void main(){ uv = pos*0.5+0.5; gl_Position = vec4(pos,0.0,1.0); }";
    const char *fs = "precision mediump float; uniform sampler2D t; varying vec2 uv; void main(){ gl_FragColor = texture2D(t, uv); }";
    GLuint prog = program(vs, fs);
    static const GLfloat quad[] = { -1,-1, 1,-1, -1,1, 1,1 };
    glViewport(0, 0, 64, 64);
    glUseProgram(prog); glUniform1i(glGetUniformLocation(prog, "t"), 0);
    glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
    static const struct { GLint minf, magf; const char *name; } modes[] = {
        { GL_NEAREST, GL_NEAREST, "NEAREST/NEAREST" }, { GL_LINEAR, GL_NEAREST, "LINEAR/NEAREST" }, { GL_LINEAR, GL_LINEAR, "LINEAR/LINEAR" } };
    for (int i = 0; i < 3; i++) {
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, modes[i].minf);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, modes[i].magf);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        uint8_t px[4]; glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);     // bottom-left quarter = first texel (green)
        CHECK(px[1] > 200 && px[0] < 60 && px[2] < 60, "sampling %s: texel (0,0) is green (RGBA %d %d %d %d)", modes[i].name, px[0], px[1], px[2], px[3]);
    }
    [EAGLContext setCurrentContext:nil]; [ctx release];
}

// Alpha masks as CoreAnimation uses them (tab-bar / SF Symbol glyphs, text): an 'A008' IOSurface uploaded with GL_ALPHA, sampled as .a (what iOS GLES gives
// for ALPHA textures); the mask must reach the framebuffer. Control: the same pixels uploaded with glTexImage2D. Also the LA08 pair.
static void test_alpha_mask(void) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:ctx];
    GLuint fbo, rb;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    const char *vs = "attribute vec2 pos; varying vec2 uv; void main(){ uv = pos*0.5+0.5; gl_Position = vec4(pos,0.0,1.0); }";
    const char *fs = "precision mediump float; uniform sampler2D t; varying vec2 uv; void main(){ vec4 c = texture2D(t, uv); gl_FragColor = vec4(c.a, c.r, c.g, 1.0); }";
    GLuint prog = program(vs, fs);
    static const GLfloat quad[] = { -1,-1, 1,-1, -1,1, 1,1 };
    glViewport(0, 0, 64, 64);
    glUseProgram(prog); glUniform1i(glGetUniformLocation(prog, "t"), 0);
    glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
    for (int variant = 0; variant < 3; variant++) {     // 0: A008 surface, 1: glTexImage2D ALPHA control, 2: LA08 surface (luminance 200, alpha = mask)
        const int W = 41, H = 41, bpp = variant == 2 ? 2 : 1;
        uint8_t *pix = calloc(1, (size_t)W * H * bpp);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            uint8_t m = x < W / 2 ? 255 : 0;
            if (bpp == 1) pix[y * W + x] = m; else { pix[(y * W + x) * 2] = 200; pix[(y * W + x) * 2 + 1] = m; }
        }
        GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        BOOL ok = YES;
        if (variant == 1) { glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, W, H, 0, GL_ALPHA, GL_UNSIGNED_BYTE, pix); }
        else {
            size_t bpr = 64 * bpp;      // padded rows like CoreAnimation's (41x41 'A008' has bpr 64)
            NSDictionary *d = @{ (id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @(bpp),
                                 (id)kIOSurfacePixelFormat : @(variant == 2 ? 0x4c413038u : 0x41303038u), (id)kIOSurfaceBytesPerRow : @(bpr) };
            IOSurfaceRef sf = IOSurfaceCreate((CFDictionaryRef)d);
            ok = sf != NULL;
            if (sf) {
                IOSurfaceLock(sf, 0, NULL); uint8_t *b = IOSurfaceGetBaseAddress(sf); size_t rb2 = IOSurfaceGetBytesPerRow(sf);
                for (int y = 0; y < H; y++) memcpy(b + y * rb2, pix + (size_t)y * W * bpp, (size_t)W * bpp);
                IOSurfaceUnlock(sf, 0, NULL);
                ok = [ctx texImageIOSurface:sf target:GL_TEXTURE_2D internalFormat:variant == 2 ? GL_LUMINANCE_ALPHA : GL_ALPHA width:W height:H
                                    format:variant == 2 ? GL_LUMINANCE_ALPHA : GL_ALPHA type:GL_UNSIGNED_BYTE plane:0 invert:YES];
                CFRelease(sf);
            }
        }
        glClearColor(0, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        uint8_t l[4], r[4]; glReadPixels(8, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, l); glReadPixels(56, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, r);
        // output = (a, r, g, 1): left half has alpha 255, right half 0; the ALPHA texture's .r/.g must be 0
        printf("      alpha variant %d: left RGBA %d %d %d %d, right RGBA %d %d %d %d, upload %d\n", variant, l[0], l[1], l[2], l[3], r[0], r[1], r[2], r[3], ok);
        CHECK(ok && l[0] > 240 && r[0] < 10, "alpha mask %s reaches the shader as .a (left %d right %d)", variant == 0 ? "A008 surface" : variant == 1 ? "glTexImage2D ALPHA" : "LA08 surface", l[0], r[0]);
        free(pix);
    }
    // live surface: a producer writes the IOSurface AFTER the upload (zeros first); binding the texture again must show the new pixels
    {
        const int W = 41, H = 41;
        NSDictionary *d = @{ (id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @(1), (id)kIOSurfacePixelFormat : @(0x41303038u), (id)kIOSurfaceBytesPerRow : @(64) };
        IOSurfaceRef sf = IOSurfaceCreate((CFDictionaryRef)d);
        GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
        BOOL ok = sf && [ctx texImageIOSurface:sf target:GL_TEXTURE_2D internalFormat:GL_ALPHA width:W height:H format:GL_ALPHA type:GL_UNSIGNED_BYTE plane:0 invert:YES];
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glClearColor(0, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        uint8_t before[4]; glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, before);
        if (sf) { IOSurfaceLock(sf, 0, NULL); memset(IOSurfaceGetBaseAddress(sf), 255, 64 * H); IOSurfaceUnlock(sf, 0, NULL); }
        glBindTexture(GL_TEXTURE_2D, 0); glBindTexture(GL_TEXTURE_2D, t);       // CoreAnimation binds before it draws with a texture
        glClear(GL_COLOR_BUFFER_BIT); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        uint8_t after[4]; glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, after);
        printf("      live surface: before write alpha-as-red %d, after write + rebind %d (upload %d)\n", before[0], after[0], ok);
        CHECK(ok && before[0] < 10 && after[0] > 240, "live IOSurface texture follows a write after the upload (%d -> %d)", before[0], after[0]);
        if (sf) CFRelease(sf);
    }
    // biplanar 4:2:0 (video-like snapshots): plane 0 = Y (R8), plane 1 = CbCr (RG8 at half size). A refused plane 1 left the chroma texture empty: solid green.
    {
        const int W = 64, H = 48;
        NSArray *planes = @[ @{ (id)kIOSurfacePlaneWidth : @(W), (id)kIOSurfacePlaneHeight : @(H), (id)kIOSurfacePlaneBytesPerRow : @(W), (id)kIOSurfacePlaneOffset : @(0), (id)kIOSurfacePlaneSize : @(W * H) },
                             @{ (id)kIOSurfacePlaneWidth : @(W / 2), (id)kIOSurfacePlaneHeight : @(H / 2), (id)kIOSurfacePlaneBytesPerRow : @(W), (id)kIOSurfacePlaneOffset : @(W * H), (id)kIOSurfacePlaneSize : @(W * H / 2) } ];
        NSDictionary *d = @{ (id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfacePixelFormat : @(0x34323076u), (id)kIOSurfacePlaneInfo : planes };
        IOSurfaceRef sf = IOSurfaceCreate((CFDictionaryRef)d);
        BOOL ok0 = NO, ok1 = NO;
        if (sf && IOSurfaceGetPlaneCount(sf) == 2) {
            IOSurfaceLock(sf, 0, NULL);
            memset(IOSurfaceGetBaseAddressOfPlane(sf, 0), 90, (size_t)W * H); memset(IOSurfaceGetBaseAddressOfPlane(sf, 1), 128, (size_t)W * H / 2);
            IOSurfaceUnlock(sf, 0, NULL);
            GLuint ty, tc; glGenTextures(1, &ty); glBindTexture(GL_TEXTURE_2D, ty);
            ok0 = [ctx texImageIOSurface:sf target:GL_TEXTURE_2D internalFormat:GL_LUMINANCE width:W height:H format:GL_LUMINANCE type:GL_UNSIGNED_BYTE plane:0 invert:YES];
            glGenTextures(1, &tc); glBindTexture(GL_TEXTURE_2D, tc);
            ok1 = [ctx texImageIOSurface:sf target:GL_TEXTURE_2D internalFormat:GL_LUMINANCE_ALPHA width:W / 2 height:H / 2 format:GL_LUMINANCE_ALPHA type:GL_UNSIGNED_BYTE plane:1 invert:YES];
        }
        printf("      biplanar 420 surface %s, plane 0 %d plane 1 %d\n", sf ? "created" : "not created", ok0, ok1);
        CHECK(!sf || (ok0 && ok1), "biplanar surface: Y and CbCr planes upload");
        if (sf) CFRelease(sf);
    }
    [EAGLContext setCurrentContext:nil]; [ctx release];
}

// Which compressed texture formats does the GL under the shim accept? (the render server uploads the wallpaper as ASTC 4x4)
static void test_compressed_formats(void) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:ctx];
    const char *ext = (const char *)glGetString(GL_EXTENSIONS);
    printf("      ASTC ldr advertised: %s, PVRTC: %s, ETC2 (core ES3): yes\n", ext && strstr(ext, "astc_ldr") ? "yes" : "NO", ext && strstr(ext, "pvrtc") ? "yes" : "NO");
    static const struct { GLenum fmt; const char *name; int bw, bh, bytes; } f[] = {
        { 0x93B0, "ASTC 4x4", 4, 4, 16 }, { 0x93B4, "ASTC 6x6", 6, 6, 16 }, { 0x93B7, "ASTC 8x8", 8, 8, 16 }, { 0x9274, "ETC2 RGB8", 4, 4, 8 },
        { 0x8C01, "PVRTC 4bpp RGB", 8, 8, 32 }, { 0x8C02, "PVRTC 2bpp RGBA", 8, 8, 32 } };
    uint8_t zero[256]; memset(zero, 0, sizeof zero);
    GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
    for (unsigned i = 0; i < sizeof f / sizeof *f; i++) {
        glGetError();
        glCompressedTexImage2D(GL_TEXTURE_2D, 0, f[i].fmt, f[i].bw, f[i].bh, 0, f[i].bytes, zero);
        GLenum e = glGetError();
        printf("      glCompressedTexImage2D %-16s -> GL error 0x%x%s\n", f[i].name, e, e ? "  (REJECTED)" : "");
    }
    [EAGLContext setCurrentContext:nil]; [ctx release];
}

static void bench(void) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:ctx];
    FakeDrawable *dr = [[FakeDrawable alloc] init];
    dr.bounds = CGRectMake(0, 0, 375, 667); dr.contentsScale = 2; dr.opaque = YES;
    GLuint fbo, rb, tex;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    [ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:dr];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    static uint32_t texels[256 * 256];
    for (int i = 0; i < 256 * 256; i++) texels[i] = 0xff000000u | ((i & 255) << 8) | (i >> 8);
    glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    const char *vs = "#version 300 es\nlayout(location=0) in vec2 pos; out vec2 uv; void main(){ uv = pos*0.5+0.5; gl_Position = vec4(pos,0.0,1.0); }";
    const char *fs = "#version 300 es\nprecision mediump float; uniform sampler2D t; in vec2 uv; out vec4 o; void main(){ o = texture(t, uv) * vec4(0.9,0.9,1.0,1.0); }";
    GLuint prog = program(vs, fs);
    static const GLfloat quad[] = { -1,-1, 1,-1, -1,1, 1,1 };
    glViewport(0, 0, 750, 1334);
    struct timeval a, b; gettimeofday(&a, NULL);
    int n = 10;
    for (int i = 0; i < n; i++) {
        glUseProgram(prog); glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        [ctx presentRenderbuffer:GL_RENDERBUFFER];
    }
    gettimeofday(&b, NULL);
    printf("BENCH 750x1334 textured full-screen quad + present: %.1f ms/frame\n", ((b.tv_sec - a.tv_sec) * 1e3 + (b.tv_usec - a.tv_usec) / 1e3) / n);
    [EAGLContext setCurrentContext:nil]; [dr release]; [ctx release];
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dump") && i + 1 < argc) g_dump = argv[++i];
        else if (!strcmp(argv[i], "--bench")) g_bench = 1;
    }
    @autoreleasepool {
        printf("%s\n", EAGLShimVersionString());
        unsigned maj = 0, min = 0; EAGLGetVersion(&maj, &min);
        CHECK(maj == 1, "EAGLGetVersion %u.%u", maj, min);
        test_present(kEAGLRenderingAPIOpenGLES2, VS100, FS100, "ES2");
        test_present(kEAGLRenderingAPIOpenGLES3, VS300, FS300, "ES3");
        test_attach_and_texture();
        test_macro_context();
        test_sampling();
        test_alpha_mask();
        test_compressed_formats();
        {   // OpenGL ES 1.1 context (fixed function): creation and one fixed-function call
            EAGLContext *c1 = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
            CHECK(c1 != nil && [EAGLContext setCurrentContext:c1], "[ES1] context");
            if (c1) {
                printf("      GL_VERSION  : %s\n", glGetString(GL_VERSION));
                glMatrixMode(GL_PROJECTION); glLoadIdentity();
                CHECK(glGetError() == GL_NO_ERROR, "[ES1] glMatrixMode/glLoadIdentity");
                [EAGLContext setCurrentContext:nil]; [c1 release];
            }
        }
        if (g_bench) bench();
    }
    printf("RESULT: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
