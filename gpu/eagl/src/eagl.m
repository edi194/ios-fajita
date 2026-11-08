// SPDX-License-Identifier: MIT
// Replacement OpenGLES.framework for the Bergamota Project (iOS 18.7.8 on the Poco F1).
//
// EAGLContext / EAGLSharegroup are implemented on top of Mesa's OSMesa frontend (gallium softpipe today,
// freedreno later: only libOSMesa changes). Every context is an OpenGL ES context (OSMesa profile 0x36, our
// Mesa patch) with a tiny dummy default framebuffer; real output goes through renderbuffers:
//   renderbufferStorage:fromDrawable:  -> glRenderbufferStorage at the drawable's pixel size
//   presentRenderbuffer:               -> read the renderbuffer back into an IOSurface (BGRA, rotating pool) and
//                                         hand it to the drawable (layer.contents = IOSurface)
//   attachImage:toCoreSurface:...      -> renderbuffer/texture <-> IOSurface association, flushed to the surface
//                                         on glFlush/glFinish/present (CoreAnimation's GLES renderer path)
//   texImageIOSurface:...              -> IOSurface pixels uploaded into the bound texture (copy)
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
#ifdef EAGL_INJECT
// Injection build (-DEAGL_INJECT): the system OpenGLES.framework lives in the dyld shared cache and cannot be replaced by path
// (dyld ignores DYLD_FRAMEWORK_PATH for cache dylibs). Our classes get other names here and, at load time, their methods are
// installed into the REAL EAGLContext / EAGLSharegroup classes (same single `_private` ivar), so every caller (QuartzCore
// included) reaches this implementation. See eagl_inject_patch() at the end of the file.
#define EAGLContext BGEAGLContext
#define EAGLSharegroup BGEAGLSharegroup
#endif
#import "eagl_private.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <sys/time.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdatomic.h>
#import <objc/message.h>
#import <math.h>
#include "osm.h"
#include "macro_ctx.h"
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <CoreGraphics/CoreGraphics.h>
#include "gl_tab.h"


#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif

#define EAGL_DEBUG(...) do { if (g_debug) fprintf(stderr, "EAGL(shim): " __VA_ARGS__); } while (0)
// Live IOSurface textures: iOS binds an IOSurface as texture storage, so a producer that writes the surface after the bind (glyph renderers, snapshot
// decoders, Control Center material) is seen at once. The shim copies at bind time; to keep the same behaviour every uploaded surface is remembered with its
// IOSurface seed and the texture is re-uploaded when it is bound again (glBindTexture) after the seed changed.
typedef struct { void *ctx; GLuint name; IOSurfaceRef surf; uint32_t seed, w, h, plane; GLenum ifmt, fmt, type; BOOL invert; BOOL wrapped; } LiveSrc;
#define MAX_LIVE 768
static LiveSrc g_live[MAX_LIVE]; static int g_nlive; static pthread_mutex_t g_live_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_wrapsample;              // BGL_WRAPSAMPLE=1 (marker word "wrapsample"): sample client-memory IOSurfaces with the GPU instead of copying them (experimental)
static int g_nowrap;                  // set while a wrapped texture is being converted back to a private copy
static int g_reupload;                // inside a re-upload: use glTexSubImage2D, keep the client's sampler state, do not register again
static unsigned g_live_reuploads;
extern void gl_unimpl(void);
static int g_direct = 1;            // display textures ARE the surface memory (default). BGL_NODIRECT=1 (boot-arg bgldirect=0, marker word "nodirect") falls back to texture + blit
static int g_dirty_track = 1;       // copy display-size attachments only when drawn into (default; BGL_SYNC_ALL=1 copies every attachment at every flush). Copying both double-buffered display textures every flush overwrote the idle surface with stale pixels: flicker and a missing wallpaper
static int g_debug, g_debug_frames;   // EAGL_SHIM_DEBUG=1: log + PIPE statistics; =2 also per-frame luminance and thumbnails
static volatile int g_target_attach;      // set once attachImage:<target> was used: the render server's convention (see texImageIOSurface)

#pragma GCC visibility push(default)
// --- constants -------------------------------------------------------------------------------------------
NSString *const kEAGLDrawablePropertyRetainedBacking = @"EAGLDrawablePropertyRetainedBacking";
NSString *const kEAGLDrawablePropertyColorFormat = @"EAGLDrawablePropertyColorFormat";
NSString *const kEAGLColorFormatRGBA8 = @"EAGLColorFormatRGBA8";
NSString *const kEAGLColorFormatRGB565 = @"EAGLColorFormatRGB565";
NSString *const kEAGLColorFormatSRGBA8 = @"EAGLColorFormatSRGBA8";
NSString *const kEAGLColorFormatRGBA_XR10_64BPP = @"EAGLColorFormatRGBA_XR10_64BPP";
NSString *const kEAGLColorFormatSRGBA_XR10_64BPP = @"EAGLColorFormatSRGBA_XR10_64BPP";
NSString *const kEAGLColorFormatSRGB_XR10 = @"EAGLColorFormatSRGB_XR10";
NSString *const kEAGLColorFormatSRGB_XR10_A8_2P = @"EAGLColorFormatSRGB_XR10_A8_2P";
NSString *const kEAGLContextPropertyAccelerated = @"EAGLContextPropertyAccelerated";
NSString *const kEAGLContextPropertyClientLabel = @"EAGLContextPropertyClientLabel";
NSString *const kEAGLContextPropertyClientRetainRelease = @"EAGLContextPropertyClientRetainRelease";
NSString *const kEAGLContextPropertySharedWithCompute = @"EAGLContextPropertySharedWithCompute";
NSString *const kEAGLContextPropertySharegroup = @"EAGLContextPropertySharegroup";
NSString *const kEAGLContextPropertyVisibleInDebugTools = @"EAGLContextPropertyVisibleInDebugTools";

__attribute__((visibility("default"))) void EAGLGetVersion(unsigned int *major, unsigned int *minor) {
    if (major) *major = EAGL_MAJOR_VERSION;
    if (minor) *minor = EAGL_MINOR_VERSION;
}
__attribute__((visibility("default"))) const char *EAGLShimVersionString(void) { return "Bergamota OpenGLES shim 0.1 (Mesa OSMesa/softpipe)"; }

#pragma GCC visibility pop

// --- private state ---------------------------------------------------------------------------------------
#define DUMMY_W 16
#define DUMMY_H 16
#define POOL_N 3
#define MAX_BIND 16

typedef struct {                    // renderbuffer bound to a drawable (renderbufferStorage:fromDrawable:)
    GLuint rb;
    id drawable;                    // retained
    uint32_t w, h;
    GLenum fmt;
    IOSurfaceRef pool[POOL_N];
    int next;
} DrawBind;

typedef struct {                    // attachImage:toCoreSurface:invertedRender:
    GLuint name;
    int kind;                       // 0 = a GL object name was given, 1 = texture bound at the given target, 2 = renderbuffer
    IOSurfaceRef surf;              // retained
    BOOL inverted;
    int direct;                     // the texture IS the surface memory (BGL_DIRECT): no blit, only finish + BO_SYNC
    int dirty;                      // drawn into (or newly attached) since the last sync: display-size attachments are copied only when dirty
} Attach;

struct _EAGLSharegroupPrivate {
    EAGLRenderingAPI api;
    pthread_mutex_t lock;
    void *live[64];                 // OSMesaContexts alive in this group (first one is the share root)
    int nlive;
};

struct _EAGLContextPrivate {
    osm_ctx osm;
    EAGLRenderingAPI api;
    EAGLSharegroup *sg;
    unsigned char *dummy;
    NSString *label;
    BOOL multithreaded;
    int params[64];
    DrawBind binds[MAX_BIND]; int nbinds;
    Attach att[MAX_BIND]; int natt;
    int cur_att;                    // index of the attachment the bound draw framebuffer renders into (colour 0), -1 = none
    GLuint tmpfbo;
    EAGLMacroContext *macro;
};

static pthread_key_t g_tls;
static pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;
static void tls_init(void) { pthread_key_create(&g_tls, NULL); }

// --- helpers ---------------------------------------------------------------------------------------------
static IOSurfaceRef make_surface(uint32_t w, uint32_t h) {
    int32_t bpe = 4, fmt = 'BGRA';
    uint32_t bpr = (w * 4 + 63) & ~63u;
    CFNumberRef nw = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)w});
    CFNumberRef nh = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)h});
    CFNumberRef nb = CFNumberCreate(NULL, kCFNumberSInt32Type, &bpe);
    CFNumberRef nf = CFNumberCreate(NULL, kCFNumberSInt32Type, &fmt);
    CFNumberRef nr = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)bpr});
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat, kIOSurfaceBytesPerRow };
    const void *vals[] = { nw, nh, nb, nf, nr };
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d); CFRelease(nw); CFRelease(nh); CFRelease(nb); CFRelease(nf); CFRelease(nr);
    return s;
}

static EAGLContext *cur_ctx(void) {
    pthread_once(&g_tls_once, tls_init);
    return (EAGLContext *)pthread_getspecific(g_tls);
}

// Copy an RGBA w*h bottom-up GL readback into a BGRA IOSurface, top-down (or bottom-up when `keep` is set).
// A display/swap-chain IOSurface can be mapped read-only in this process (a write then dies with SIGBUS / KERN_PROTECTION_FAILURE, seen in
// backboardd): check the mapping before the CPU fallback writes into it.
static BOOL mapping_writable(const void *p, size_t len) {
    // Walk the VM regions covering [p, p+len): every one must exist and be writable (a surface mapping may consist of several regions; the first
    // version required ONE region for the whole range and so skipped legitimate writes: the text/icons of the UI went missing).
    vm_address_t cur = (vm_address_t)p, end = cur + len;
    while (cur < end) {
        vm_address_t addr = cur;
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return NO;
        if (addr > cur) return NO;
        if (!(info.protection & VM_PROT_WRITE)) {
            // read-only now, but the mapping may allow write (max protection): raise it. Client-memory surfaces of other processes (the Control
            // Center modules' render targets) arrive this way; skipping their sync left them black.
            static int logged; if (g_debug && logged++ < 8) fprintf(stderr, "EAGL(shim): read-only mapping %p+%zx prot %d max %d\n", (void *)cur, (size_t)size, info.protection, info.max_protection);
            if (!(info.max_protection & VM_PROT_WRITE) || vm_protect(mach_task_self(), addr > cur ? addr : cur, size - (cur - addr), FALSE, info.protection | VM_PROT_WRITE) != KERN_SUCCESS) return NO;
        }
        cur = addr + size;
    }
    return YES;
}

static void rgba_to_surface(const uint8_t *src, uint32_t w, uint32_t h, IOSurfaceRef s, BOOL flip, BOOL opaque) {
    kern_return_t lk = IOSurfaceLock(s, 0, NULL);
    uint8_t *dst = lk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(s) : NULL;
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    BOOL via_alias = NO;
    if (!dst || !mapping_writable(dst, bpr * IOSurfaceGetHeight(s))) {
        // read-only client memory (Control Center platters, live icons): the kernel gives a writable CPU alias of it (abi_minor 2)
        void *ab = NULL; unsigned abpr = 0, aw = 0, ah = 0;
        // opt-in (BGL_ALIAS=1): read-only surfaces here are mostly the clients' own backing stores (text, labels);
        // writing the render server's result into them doubled and smeared every label on the phone
        static int alias_on = -1;
        if (alias_on < 0) { const char *e = getenv("BGL_ALIAS"); alias_on = e && e[0] == '1'; }
        if (alias_on && osm_sweet_surface_alias(IOSurfaceGetID(s), &ab, &abpr, &aw, &ah)) { dst = ab; bpr = abpr; via_alias = YES; }
        else {
            if (lk == KERN_SUCCESS) IOSurfaceUnlock(s, 0, NULL);
            EAGL_DEBUG("CPU sync skipped: surface %u is not mapped writable here (no kernel alias)\n", IOSurfaceGetID(s));
            return;
        }
    }
    size_t sw = IOSurfaceGetWidth(s), sh = IOSurfaceGetHeight(s);
    uint32_t cw = w < sw ? w : (uint32_t)sw, ch = h < sh ? h : (uint32_t)sh;
    for (uint32_t y = 0; y < ch; y++) {
        const uint32_t *sp = (const uint32_t *)(src + (size_t)(flip ? (h - 1 - y) : y) * w * 4);
        uint32_t *dp = (uint32_t *)(dst + y * bpr);
        for (uint32_t x = 0; x < cw; x++) {
            uint32_t p = sp[x];                         // memory R G B A (little endian: 0xAABBGGRR)
            uint32_t r = p & 0xff, b = (p >> 16) & 0xff;
            dp[x] = (p & 0xff00ff00u) | (r << 16) | b | (opaque ? 0xff000000u : 0);
        }
    }
    if (via_alias) osm_sweet_alias_sync(IOSurfaceGetID(s));
    if (lk == KERN_SUCCESS) IOSurfaceUnlock(s, 0, NULL);
}

// Read back the renderbuffer (or texture level 0) `name` of the current context into a malloc'ed RGBA buffer.
static uint8_t *read_image(EAGLContext *c, GLuint name, BOOL isTexture, uint32_t hintw, uint32_t hinth, uint32_t *ow, uint32_t *oh) {
    struct _EAGLContextPrivate *p = c->_private;
    GLint oldRead = 0, oldPackAlign = 4, oldRb = 0, oldTex = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &oldRead);
    glGetIntegerv(GL_PACK_ALIGNMENT, &oldPackAlign);
    if (!p->tmpfbo) glGenFramebuffers(1, &p->tmpfbo);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, p->tmpfbo);
    GLint w = 0, h = 0;
    if (isTexture) {
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, name, 0);
        w = (GLint)hintw; h = (GLint)hinth;     // ES has no level-size query; the IOSurface gives the size
        (void)oldTex;
    } else {
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &oldRb);
        glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, name);
        glBindRenderbuffer(GL_RENDERBUFFER, name);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h);
        glBindRenderbuffer(GL_RENDERBUFFER, oldRb);
    }
    uint8_t *buf = NULL;
    if (w > 0 && h > 0 && glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
        buf = malloc((size_t)w * h * 4);
        if (buf) {
            glPixelStorei(GL_PACK_ALIGNMENT, 4);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, buf);
        }
    }
    if (isTexture) glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    else glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, 0);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, oldRead);
    glPixelStorei(GL_PACK_ALIGNMENT, oldPackAlign);
    *ow = (uint32_t)w; *oh = (uint32_t)h;
    return buf;
}

// Debug dump (EAGL_SHIM_DEBUG=1): frames 1, 10 and 60 of the attached-image sync, and any time /private/var/tmp/bgl-dump-now exists, are
// written as PPM files to /private/var/tmp/bgl-dump/: "-gl" = what the GL side holds (renderbuffer/texture read back), "-surf" = what the
// CPU sees in the IOSurface right after our sync. The first pixels and the surface geometry go to the log.
static void dump_ppm(const char *path, const uint8_t *rgba_or_bgra, uint32_t w, uint32_t h, size_t stride, int bgra, BOOL flip) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *row = rgba_or_bgra + (size_t)(flip ? h - 1 - y : y) * stride;
        for (uint32_t x = 0; x < w; x++) {
            const uint8_t *q = row + x * 4;
            fputc(bgra ? q[2] : q[0], f); fputc(q[1], f); fputc(bgra ? q[0] : q[2], f);
        }
    }
    fclose(f);
}
static void maybe_dump(EAGLContext *c, int idx, BOOL isTex, uint32_t gw, uint32_t gh, BOOL gpu_path) {
    static int frame;
    struct _EAGLContextPrivate *p = c->_private;
    Attach *a = &p->att[idx];
    if (idx == 0) frame++;
    int now = access("/private/var/tmp/bgl-dump-now", F_OK) == 0;
    if (now && idx == 0) unlink("/private/var/tmp/bgl-dump-now");     // one-shot: a left-over trigger must not dump every frame (it did, after a reboot)
    if (!(frame == 1 || frame == 10 || frame == 60 || now)) return;
    mkdir("/private/var/tmp/bgl-dump", 0777);
    uint32_t w, h;
    uint8_t *buf = read_image(c, a->name, isTex, gw, gh, &w, &h);
    char path[256];
    if (buf) { snprintf(path, sizeof path, "/private/var/tmp/bgl-dump/f%d-a%d-gl.ppm", frame, idx); dump_ppm(path, buf, w, h, (size_t)w * 4, 0, YES); }
    kern_return_t dlk = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *sp = dlk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
    if (!sp) { fprintf(stderr, "EAGL(shim): dump frame %d: surface %u has no CPU mapping (lock %x)\n", frame, IOSurfaceGetID(a->surf), dlk); if (dlk == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL); free(buf); return; }
    size_t bpr = IOSurfaceGetBytesPerRow(a->surf);
    uint32_t sw = (uint32_t)IOSurfaceGetWidth(a->surf), sh = (uint32_t)IOSurfaceGetHeight(a->surf);
    OSType pf = IOSurfaceGetPixelFormat(a->surf);
    fprintf(stderr, "EAGL(shim): dump frame %d attach %d name %u %s: surface %u %ux%u fmt %08x stride %zu inverted %d gpu_blit %d, GL image %ux%u; first pixels (bytes) %02x%02x%02x%02x %02x%02x%02x%02x, centre %02x%02x%02x%02x\n",
            frame, idx, a->name, isTex ? "texture" : "renderbuffer", IOSurfaceGetID(a->surf), sw, sh, (unsigned)pf, bpr, a->inverted, gpu_path, w, h,
            sp[0], sp[1], sp[2], sp[3], sp[4], sp[5], sp[6], sp[7],
            sp[(sh / 2) * bpr + (sw / 2) * 4], sp[(sh / 2) * bpr + (sw / 2) * 4 + 1], sp[(sh / 2) * bpr + (sw / 2) * 4 + 2], sp[(sh / 2) * bpr + (sw / 2) * 4 + 3]);
    if (pf == 'BGRA') { snprintf(path, sizeof path, "/private/var/tmp/bgl-dump/f%d-a%d-surf.ppm", frame, idx); dump_ppm(path, sp, sw, sh, bpr, 1, NO); }
    IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
    free(buf);
}

// Per-frame statistics for display-size surfaces (EAGL_SHIM_DEBUG): time since the previous sync, duration of the blit, and a sampled average
// luminance / fraction of black samples of what the CPU sees in the surface afterwards. A flashing display shows up as black or stale frames.
static double now_ms(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec * 1e3 + tv.tv_usec / 1e3; }
static void frame_stats(Attach *a, double t_start, double t_end, int gpu) {
    static double last_t, t0; static int n;
    size_t w = IOSurfaceGetWidth(a->surf), h = IOSurfaceGetHeight(a->surf);
    if (w < 1000 || h < 2000 || n > 3000 || !g_debug_frames) return;
    if (!t0) t0 = t_start;
    double lum = -1, black = -1;
    kern_return_t lk = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *sp = lk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
    if (sp && IOSurfaceGetPixelFormat(a->surf) == 'BGRA') {
        size_t bpr = IOSurfaceGetBytesPerRow(a->surf), cnt = 0, blk = 0; double sum = 0;
        for (size_t y = 3; y < h; y += 61) for (size_t x = 5; x < w; x += 53) { const uint8_t *q = sp + y * bpr + x * 4; sum += (q[0] + q[1] + q[2]) / 3.0; if (q[0] + q[1] + q[2] < 6) blk++; cnt++; }
        lum = sum / cnt; black = (double)blk / cnt;
    }
    if (lk == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
    // thumbnails (1/16 scale) of the first 80 syncs: /private/var/tmp/bgl-thumbs.bin = repeated { u32 index, u32 surface, u32 w, u32 h, w*h*3 RGB } (contact sheet on the Mac)
    {
        static uint8_t *tb; static size_t tlen; enum { TW = 71, TH = 153, MAXF = 80 };
        if (n < MAXF && sp == NULL) { /* surface unreadable: nothing */ }
        if (n < MAXF) {
            if (!tb) tb = malloc((size_t)MAXF * (16 + TW * TH * 3));
            kern_return_t lk2 = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
            const uint8_t *sp2 = lk2 == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
            if (tb && sp2 && IOSurfaceGetPixelFormat(a->surf) == 'BGRA') {
                size_t bpr = IOSurfaceGetBytesPerRow(a->surf);
                uint32_t *hd = (uint32_t *)(tb + tlen); hd[0] = n + 1; hd[1] = IOSurfaceGetID(a->surf); hd[2] = TW; hd[3] = TH;
                uint8_t *o = tb + tlen + 16;
                for (int y = 0; y < TH; y++) for (int x = 0; x < TW; x++) { const uint8_t *q = sp2 + (size_t)(y * 16) * bpr + (size_t)(x * 16) * 4; *o++ = q[2]; *o++ = q[1]; *o++ = q[0]; }
                tlen += 16 + TW * TH * 3;
                if (n + 1 == MAXF) { FILE *f = fopen("/private/var/tmp/bgl-thumbs.bin", "wb"); if (f) { fwrite(tb, 1, tlen, f); fclose(f); } fprintf(stderr, "EAGL(shim): thumbnails written (%zu bytes)\n", tlen); }
            }
            if (lk2 == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
        }
    }
    fprintf(stderr, "EAGL(shim): FS #%d t=%.0f dt=%.1f blit=%.1fms surf=%u gpu=%d lum=%.1f black=%.2f\n", ++n, t_end - t0, last_t ? t_start - last_t : 0.0, t_end - t_start, IOSurfaceGetID(a->surf), gpu, lum, black);
    last_t = t_start;
}

// Pipeline statistics (EAGL_SHIM_DEBUG): per interval of 60 display-size syncs, where the time goes. glflush = time inside Mesa's glFlush (batch
// submit), blit = enqueue / render-wait (GPU time of the client's drawing, forced by a finish) / copy-wait (GPU time of the blit) / BO_SYNC,
// cpu = surfaces copied through the CPU (read_image + rgba_to_surface). In this mode the extra finish makes frames slower than they are normally.
static unsigned g_mark_hit, g_mark_miss, g_draw_seen;
static double g_ps_direct_ms; static int g_ps_direct_n;
static double g_ps_flush_ms, g_ps_cpu_ms; static int g_ps_cpu_n, g_ps_syncs, g_ps_skipped;
static void pipe_stats_report(void) {
    static double last[8], last_flush, last_cpu, last_t; static int last_cpu_n, last_syncs;
    double st[8]; osm_sweet_stats(st, 8);
    double now = now_ms(), dn = g_ps_syncs - last_syncs; if (dn < 1) return;
    fprintf(stderr, "EAGL(shim): PIPE %d syncs in %.0f ms (%.1f ms/sync): glFlush %.2f | gpu blits %.0f refused %.0f | render-wait %.2f enqueue %.2f copy-wait %.2f bo_sync %.2f lookup %.2f | cpu copies %d %.2f ms (per sync) | direct display syncs %d %.2f ms each | display copies skipped (clean) %d | draws marking an attachment %u, other draws %u\n",
            (int)dn, now - last_t, (now - last_t) / dn, (g_ps_flush_ms - last_flush) / dn, st[0] - last[0], st[6] - last[6],
            (st[1] - last[1]) / dn, (st[2] - last[2]) / dn, (st[3] - last[3]) / dn, (st[4] - last[4]) / dn, (st[5] - last[5]) / dn,
            g_ps_cpu_n - last_cpu_n, (g_ps_cpu_ms - last_cpu) / dn, g_ps_direct_n, g_ps_direct_n ? g_ps_direct_ms / g_ps_direct_n : 0.0, g_ps_skipped, g_mark_hit, g_mark_miss);
    memcpy(last, st, sizeof st); last_flush = g_ps_flush_ms; last_cpu = g_ps_cpu_ms; last_t = now; last_cpu_n = g_ps_cpu_n; last_syncs = g_ps_syncs;
}

// Flush every attachImage: association of this context into its IOSurface.
// frames mode: compare what the GPU rendered (glReadPixels of the texture = the surface memory seen by the GPU) with what the CPU reads from the surface
// right after the sync. Mismatches mean stale cache lines / missing sync on this side; none means the surface is coherent for the CPU and any artefact
// on screen comes from later (the kernel's copy to the panel, or a surface that is being rendered into while it is copied).
static void verify_direct(EAGLContext *c, Attach *a) {
    static int n; if (n++ >= 300) return;
    uint32_t w = 0, h = 0, sw = (uint32_t)IOSurfaceGetWidth(a->surf), sh = (uint32_t)IOSurfaceGetHeight(a->surf);
    uint8_t *buf = read_image(c, a->name, YES, sw, sh, &w, &h);
    if (!buf) return;
    if (IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) { free(buf); return; }
    const uint8_t *sp = IOSurfaceGetBaseAddress(a->surf); size_t bpr = IOSurfaceGetBytesPerRow(a->surf);
    size_t bad = 0, badrows = 0, first_x = 0, first_y = 0; BOOL found = NO;
    for (uint32_t y = 0; y < h && y < sh; y++) {
        size_t rowbad = 0;
        for (uint32_t x = 0; x < w && x < sw; x++) {
            const uint8_t *g = buf + ((size_t)y * w + x) * 4, *q = sp + y * bpr + (size_t)x * 4;     // g = RGBA, q = BGRA, same row order (no flip for target-form attaches)
            if (g[0] != q[2] || g[1] != q[1] || g[2] != q[0] || g[3] != q[3]) { rowbad++; if (!found) { found = YES; first_x = x; first_y = y; } }
        }
        bad += rowbad; if (rowbad) badrows++;
    }
    fprintf(stderr, "EAGL(shim): VERIFY surface %u: %zu mismatching pixels in %zu rows of %ux%u%s", IOSurfaceGetID(a->surf), bad, badrows, w, h, bad ? "" : "\n");
    if (bad) fprintf(stderr, ", first at (%zu,%zu): gpu %02x%02x%02x%02x cpu(bgra) %02x%02x%02x%02x\n", first_x, first_y,
                     buf[(first_y * w + first_x) * 4], buf[(first_y * w + first_x) * 4 + 1], buf[(first_y * w + first_x) * 4 + 2], buf[(first_y * w + first_x) * 4 + 3],
                     sp[first_y * bpr + first_x * 4], sp[first_y * bpr + first_x * 4 + 1], sp[first_y * bpr + first_x * 4 + 2], sp[first_y * bpr + first_x * 4 + 3]);
    IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL); free(buf);
}

static void sync_att(EAGLContext *c, int i) {
    struct _EAGLContextPrivate *p = c->_private;
    Attach *a = &p->att[i];
        a->dirty = 0;
        if (a->direct) {
            double td = g_debug ? now_ms() : 0; osm_sweet_direct_sync(IOSurfaceGetID(a->surf)); if (g_debug) { g_ps_direct_ms += now_ms() - td; g_ps_direct_n++; }
            if (g_debug_frames) verify_direct(c, a);
            return;
        }
        BOOL isTex = a->kind ? (a->kind == 1) : (glIsTexture(a->name) && !glIsRenderbuffer(a->name));
        // Hardware path: the GPU copies the image into the surface (no readback); GL rows are bottom-up, `inverted` means the surface wants them as they are.
        double t_start = g_debug ? now_ms() : 0;
        BOOL flip = a->kind ? a->inverted : !a->inverted;      // target-form attach (the render server): YES = rows flipped, NO = as GL has them (seen on the phone: NO + flip drew the UI upside down)
        if (osm_sweet_active() && osm_sweet_blit(a->name, isTex, IOSurfaceGetID(a->surf), flip, NO)) {
            if (g_debug) { frame_stats(a, t_start, now_ms(), 1); maybe_dump(c, i, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), YES); }
            return;
        }
        uint32_t w, h;
        double t_cpu0 = g_debug ? now_ms() : 0;
        uint8_t *buf = read_image(c, a->name, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), &w, &h);
        if (buf) {
            // GL rows are bottom-up; a "normal" surface is top-down. invertedRender means CA already drew it flipped.
            rgba_to_surface(buf, w, h, a->surf, flip, NO);
            free(buf);
        }
        if (g_debug) { g_ps_cpu_ms += now_ms() - t_cpu0; g_ps_cpu_n++; }
        if (g_debug) { frame_stats(a, t_start, now_ms(), 0); maybe_dump(c, i, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), NO); }
}

static void sync_attached(EAGLContext *c) {
    struct _EAGLContextPrivate *p = c->_private;
    // Safety net: GL work happened but nothing was attributed to an attachment (a render path the tracking does not see): copy everything this flush.
    BOOL force_all = NO;
    if (g_dirty_track) {
        BOOL any = NO; for (int i = 0; i < p->natt; i++) if (p->att[i].dirty) any = YES;
        force_all = !any && g_draw_seen > 0 && p->cur_att < 0;
        g_draw_seen = 0;
    }
    for (int i = 0; i < p->natt; i++) {
        Attach *a = &p->att[i];
        if (g_dirty_track && !force_all && !a->dirty && IOSurfaceGetWidth(a->surf) * IOSurfaceGetHeight(a->surf) >= 1000000) { g_ps_skipped++; continue; }   // display buffer nobody drew into
        sync_att(c, i);
    }
}

// glFlush / glFinish wrappers installed over the Mesa entry points (see eagl_install_hooks).
static void (*mesa_glFlush)(void), (*mesa_glFinish)(void);
static void pipe_count_sync(EAGLContext *c) {
    if (!g_debug || !c->_private->natt) return;
    size_t w = 0, h = 0; for (int i = 0; i < c->_private->natt; i++) { size_t aw = IOSurfaceGetWidth(c->_private->att[i].surf); if (aw > w) { w = aw; h = IOSurfaceGetHeight(c->_private->att[i].surf); } }
    if (w >= 1000 && h >= 2000 && ++g_ps_syncs % 60 == 0) pipe_stats_report();
}
static void shim_glFlush(void) { double t = g_debug ? now_ms() : 0; mesa_glFlush(); if (g_debug) g_ps_flush_ms += now_ms() - t; EAGLContext *c = cur_ctx(); if (c && c->_private->natt) { sync_attached(c); pipe_count_sync(c); } }
static void shim_glFinish(void) { double t = g_debug ? now_ms() : 0; mesa_glFinish(); if (g_debug) g_ps_flush_ms += now_ms() - t; EAGLContext *c = cur_ctx(); if (c && c->_private->natt) { sync_attached(c); pipe_count_sync(c); } }

// Dirty tracking of the display-size attachments: the render server draws into one texture per frame (through an FBO) and flushes; copying both of its
// double-buffered display textures at every flush doubled the cost of a frame. Draw/clear entry points mark the attachment the bound FBO renders into,
// FBO binding changes recompute which attachment that is, and sync_attached copies display-size attachments only when marked.
static BOOL att_is_tex(Attach *a) { return a->kind ? a->kind == 1 : (glIsTexture(a->name) && !glIsRenderbuffer(a->name)); }
static void update_cur_target(EAGLContext *c) {
    struct _EAGLContextPrivate *p = c->_private;
    p->cur_att = -1;
    if (!p->natt) return;
    GLint fb = 0, type = 0, name = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    if (!fb) { if (g_debug) { static int n; if (n++ < 20) fprintf(stderr, "EAGL(shim): FBO tracking: no framebuffer bound (%d attachments)\n", p->natt); } return; }
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name);
    if (type != GL_TEXTURE && type != GL_RENDERBUFFER) return;
    for (int i = 0; i < p->natt; i++) if ((GLint)p->att[i].name == name && att_is_tex(&p->att[i]) == (type == GL_TEXTURE)) { p->cur_att = i; break; }
    if (g_debug) { static int n; if (n++ < 60) fprintf(stderr, "EAGL(shim): [ctx %p] FBO %d colour0 type 0x%x name %d -> attachment %d (of %d)\n", c, fb, type, name, p->cur_att, p->natt); }
}
static inline void mark_cur_dirty(void) { EAGLContext *c = cur_ctx(); if (c && c->_private->cur_att >= 0 && c->_private->cur_att < c->_private->natt) { c->_private->att[c->_private->cur_att].dirty = 1; g_mark_hit++; } else g_mark_miss++; g_draw_seen++; }
static void (*o_DrawArrays)(GLenum, GLint, GLsizei);
static void h_DrawArrays(GLenum a, GLint b, GLsizei c) { mark_cur_dirty(); o_DrawArrays(a, b, c); }
static void (*o_DrawElements)(GLenum, GLsizei, GLenum, const void *);
static void h_DrawElements(GLenum a, GLsizei b, GLenum c, const void *d) { mark_cur_dirty(); o_DrawElements(a, b, c, d); }
static void (*o_DrawArraysInstanced)(GLenum, GLint, GLsizei, GLsizei);
static void h_DrawArraysInstanced(GLenum a, GLint b, GLsizei c, GLsizei d) { mark_cur_dirty(); o_DrawArraysInstanced(a, b, c, d); }
static void (*o_DrawElementsInstanced)(GLenum, GLsizei, GLenum, const void *, GLsizei);
static void h_DrawElementsInstanced(GLenum a, GLsizei b, GLenum c, const void *d, GLsizei e) { mark_cur_dirty(); o_DrawElementsInstanced(a, b, c, d, e); }
static void (*o_DrawRangeElements)(GLenum, GLuint, GLuint, GLsizei, GLenum, const void *);
static void h_DrawRangeElements(GLenum a, GLuint b, GLuint c, GLsizei d, GLenum e, const void *f) { mark_cur_dirty(); o_DrawRangeElements(a, b, c, d, e, f); }
static void (*o_Clear)(GLbitfield);
static void diag_fbo(void) {      // debug: say why a framebuffer the render server draws into is incomplete
    static int n; if (!g_debug || n >= 40) return;
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (st == GL_FRAMEBUFFER_COMPLETE) return;
    n++;
    GLint fb = 0, t0 = 0, n0 = 0, r = 0, g = 0, b = 0, a = 0, td = 0, nd = 0, ts = 0, ns = 0, w = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &t0);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &n0);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0x8212, &r);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0x8213, &g);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0x8214, &b);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0x8215, &a);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &td);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &nd);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &ts);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &ns);
    (void)w;
    fprintf(stderr, "EAGL(shim): INCOMPLETE FBO %d status 0x%x: colour0 type 0x%x name %d bits %d/%d/%d/%d, depth type 0x%x name %d, stencil type 0x%x name %d\n", fb, st, t0, n0, r, g, b, a, td, nd, ts, ns);
}
static void h_Clear(GLbitfield m) { mark_cur_dirty(); diag_fbo(); o_Clear(m); }
static void (*o_ClearBufferfv)(GLenum, GLint, const GLfloat *);
static void h_ClearBufferfv(GLenum a, GLint b, const GLfloat *c) { mark_cur_dirty(); o_ClearBufferfv(a, b, c); }
static void mark_bound_texture_dirty(void) {     // texture writes (upload / copy) land in the texture bound to GL_TEXTURE_2D
    EAGLContext *c = cur_ctx(); if (!c || !c->_private->natt) return;
    GLint t = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
    for (int i = 0; i < c->_private->natt; i++) if ((GLint)c->_private->att[i].name == t && att_is_tex(&c->_private->att[i])) c->_private->att[i].dirty = 1;
    g_draw_seen++;
}
static void (*o_ClearBufferiv)(GLenum, GLint, const GLint *);
static void h_ClearBufferiv(GLenum a, GLint b, const GLint *c) { mark_cur_dirty(); o_ClearBufferiv(a, b, c); }
static void (*o_ClearBufferuiv)(GLenum, GLint, const GLuint *);
static void h_ClearBufferuiv(GLenum a, GLint b, const GLuint *c) { mark_cur_dirty(); o_ClearBufferuiv(a, b, c); }
static void (*o_ClearBufferfi)(GLenum, GLint, GLfloat, GLint);
static void h_ClearBufferfi(GLenum a, GLint b, GLfloat c, GLint d) { mark_cur_dirty(); o_ClearBufferfi(a, b, c, d); }
static void (*o_BlitFramebuffer)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
static void h_BlitFramebuffer(GLint a, GLint b, GLint c, GLint d, GLint e, GLint f, GLint g, GLint h, GLbitfield i, GLenum j) { mark_cur_dirty(); o_BlitFramebuffer(a, b, c, d, e, f, g, h, i, j); }
static void (*o_CopyTexImage2D)(GLenum, GLint, GLenum, GLint, GLint, GLsizei, GLsizei, GLint);
static void h_CopyTexImage2D(GLenum a, GLint b, GLenum c, GLint d, GLint e, GLsizei f, GLsizei g, GLint h) { o_CopyTexImage2D(a, b, c, d, e, f, g, h); mark_bound_texture_dirty(); }
static void (*o_CopyTexSubImage2D)(GLenum, GLint, GLint, GLint, GLint, GLint, GLsizei, GLsizei);
static void h_CopyTexSubImage2D(GLenum a, GLint b, GLint c, GLint d, GLint e, GLint f, GLsizei g, GLsizei h) { o_CopyTexSubImage2D(a, b, c, d, e, f, g, h); mark_bound_texture_dirty(); }
static void (*o_TexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *);
static void unwrap_bound_texture(void) {      // a write into a texture that samples client memory in place must not reach that (read-only) memory: give it private storage first
    EAGLContext *c = cur_ctx(); if (!c || !g_nlive) return;
    GLint t = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
    LiveSrc e; BOOL hit = NO;
    pthread_mutex_lock(&g_live_lock);
    for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == (void *)c && g_live[i].name == (GLuint)t && g_live[i].wrapped) { e = g_live[i]; CFRetain(e.surf); CFRelease(g_live[i].surf); g_live[i] = g_live[--g_nlive]; hit = YES; break; }
    pthread_mutex_unlock(&g_live_lock);
    if (!hit) return;
    g_nowrap = 1; [c texImageIOSurface:e.surf target:GL_TEXTURE_2D internalFormat:e.ifmt width:e.w height:e.h format:e.fmt type:e.type plane:e.plane invert:e.invert]; g_nowrap = 0;
    CFRelease(e.surf);
}
static void h_TexSubImage2D(GLenum a, GLint b, GLint c, GLint d, GLsizei e, GLsizei f, GLenum g, GLenum h, const void *i) { if (a == GL_TEXTURE_2D) unwrap_bound_texture(); o_TexSubImage2D(a, b, c, d, e, f, g, h, i); mark_bound_texture_dirty(); }
static void (*o_BindTexture)(GLenum, GLuint);
static void h_BindTexture(GLenum target, GLuint name) {
    o_BindTexture(target, name);
    if (target != GL_TEXTURE_2D || !name || !g_nlive) return;
    EAGLContext *c = cur_ctx(); if (!c) return;
    LiveSrc e; BOOL hit = NO;
    pthread_mutex_lock(&g_live_lock);
    for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == c && g_live[i].name == name) {
        uint32_t now = IOSurfaceGetSeed(g_live[i].surf);
        if (now != g_live[i].seed) { g_live[i].seed = now; e = g_live[i]; hit = YES; }
        break;
    }
    pthread_mutex_unlock(&g_live_lock);
    if (!hit) return;
    if (e.wrapped) { osm_sweet_wrap_sync(IOSurfaceGetID(e.surf)); return; }     // GPU samples the memory itself: only clean the producer's cache lines
    g_reupload = 1;
    [c texImageIOSurface:e.surf target:GL_TEXTURE_2D internalFormat:e.ifmt width:e.w height:e.h format:e.fmt type:e.type plane:e.plane invert:e.invert];
    g_reupload = 0; g_live_reuploads++;
    if (g_debug) { static int n; if (n++ < 100) fprintf(stderr, "EAGL(shim): live surface %u re-uploaded into texture %u (seed changed)\n", IOSurfaceGetID(e.surf), name); }
}
static void (*o_DeleteTextures)(GLsizei, const GLuint *);
static void h_DeleteTextures(GLsizei n, const GLuint *t) {
    // A display texture that was drawn into but not yet copied (CoreAnimation recreates them) would lose its pixels: copy it out before it goes.
    EAGLContext *c = cur_ctx();
    if (c) for (GLsizei i = 0; i < n; i++) for (int k = 0; k < c->_private->natt; k++) {
        Attach *a = &c->_private->att[k];
        if (a->name != t[i] || a->kind == 2 || !att_is_tex(a)) continue;
        BOOL big = IOSurfaceGetWidth(a->surf) * IOSurfaceGetHeight(a->surf) >= 1000000;
        if (g_debug) fprintf(stderr, "EAGL(shim): [ctx %p] glDeleteTextures(%u) deletes an attached texture (surface %u, dirty %d)\n", c, t[i], IOSurfaceGetID(a->surf), a->dirty);
        if (g_dirty_track && a->dirty && big) sync_att(c, k);
        // The texture is going away: its attachment must too. A stale entry kept copying a deleted (empty) texture over a live display surface
        // every flush (surface black after CoreAnimation tore down its buffers: display sleep/wake, app switches).
        osm_sweet_forget(IOSurfaceGetID(a->surf)); CFRelease(a->surf);
        c->_private->att[k] = c->_private->att[--c->_private->natt];
        k--;
    }
    if (c) { c->_private->cur_att = -1; }
    pthread_mutex_lock(&g_live_lock);
    for (GLsizei i = 0; i < n; i++) for (int k = 0; k < g_nlive; k++) if (g_live[k].ctx == (void *)c && g_live[k].name == t[i]) {
        CFRelease(g_live[k].surf); g_live[k] = g_live[--g_nlive]; k--;
    }
    pthread_mutex_unlock(&g_live_lock);
    o_DeleteTextures(n, t);
    if (c) update_cur_target(c);
}
static void (*o_BindFramebuffer)(GLenum, GLuint);
static void h_BindFramebuffer(GLenum t, GLuint f) { o_BindFramebuffer(t, f); EAGLContext *c = cur_ctx(); if (c) update_cur_target(c); }
static void (*o_FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
static void h_FramebufferTexture2D(GLenum a, GLenum b, GLenum c, GLuint d, GLint e) { o_FramebufferTexture2D(a, b, c, d, e); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static void (*o_FramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
static void h_FramebufferRenderbuffer(GLenum a, GLenum b, GLenum c, GLuint d) { o_FramebufferRenderbuffer(a, b, c, d); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static void (*o_DeleteFramebuffers)(GLsizei, const GLuint *);
static void h_DeleteFramebuffers(GLsizei n, const GLuint *f) { o_DeleteFramebuffers(n, f); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static const struct { const char *name; void **orig; void *hook; } g_dirty_hooks[] = {
    { "glDrawArrays", (void **)&o_DrawArrays, h_DrawArrays }, { "glDrawElements", (void **)&o_DrawElements, h_DrawElements },
    { "glDrawArraysInstanced", (void **)&o_DrawArraysInstanced, h_DrawArraysInstanced }, { "glDrawElementsInstanced", (void **)&o_DrawElementsInstanced, h_DrawElementsInstanced },
    { "glDrawRangeElements", (void **)&o_DrawRangeElements, h_DrawRangeElements }, { "glClear", (void **)&o_Clear, h_Clear }, { "glClearBufferfv", (void **)&o_ClearBufferfv, h_ClearBufferfv },
    { "glClearBufferiv", (void **)&o_ClearBufferiv, h_ClearBufferiv }, { "glClearBufferuiv", (void **)&o_ClearBufferuiv, h_ClearBufferuiv }, { "glClearBufferfi", (void **)&o_ClearBufferfi, h_ClearBufferfi },
    { "glBlitFramebuffer", (void **)&o_BlitFramebuffer, h_BlitFramebuffer }, { "glCopyTexImage2D", (void **)&o_CopyTexImage2D, h_CopyTexImage2D },
    { "glCopyTexSubImage2D", (void **)&o_CopyTexSubImage2D, h_CopyTexSubImage2D }, { "glTexSubImage2D", (void **)&o_TexSubImage2D, h_TexSubImage2D },
    { "glDeleteTextures", (void **)&o_DeleteTextures, h_DeleteTextures }, { "glBindTexture", (void **)&o_BindTexture, h_BindTexture },
    { "glBindFramebuffer", (void **)&o_BindFramebuffer, h_BindFramebuffer }, { "glFramebufferTexture2D", (void **)&o_FramebufferTexture2D, h_FramebufferTexture2D },
    { "glFramebufferRenderbuffer", (void **)&o_FramebufferRenderbuffer, h_FramebufferRenderbuffer }, { "glDeleteFramebuffers", (void **)&o_DeleteFramebuffers, h_DeleteFramebuffers },
};

static void eagl_install_hooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gl_resolve_all();
        for (int i = 0; i < gl_nfuncs; i++) {
            if (!strcmp(gl_names[i], "glFlush")) { mesa_glFlush = gl_tab[i]; gl_tab[i] = (void *)shim_glFlush; }
            if (!strcmp(gl_names[i], "glFinish")) { mesa_glFinish = gl_tab[i]; gl_tab[i] = (void *)shim_glFinish; }
        }
        g_debug = getenv("EAGL_SHIM_DEBUG") != NULL; g_debug_frames = g_debug && !strcmp(getenv("EAGL_SHIM_DEBUG"), "2");
        g_dirty_track = !getenv("BGL_SYNC_ALL");
        g_direct = !getenv("BGL_NODIRECT"); g_wrapsample = getenv("BGL_WRAPSAMPLE") != NULL;
        if (g_dirty_track) {
            // every alias of an entry point is hooked (glBindFramebuffer / glBindFramebufferOES / ...: the render server's slots may use either spelling)
            static const char *const sfx[] = { "", "OES", "EXT", "ARB", "APPLE", "ANGLE" };
            for (int i = 0; i < gl_nfuncs; i++)
                for (unsigned k = 0; k < sizeof g_dirty_hooks / sizeof g_dirty_hooks[0]; k++) {
                    size_t n = strlen(g_dirty_hooks[k].name);
                    if (strncmp(gl_names[i], g_dirty_hooks[k].name, n) || gl_tab[i] == (void *)gl_unimpl) continue;
                    BOOL ok = NO; for (unsigned q = 0; q < 6; q++) if (!strcmp(gl_names[i] + n, sfx[q])) ok = YES;
                    if (!ok) continue;
                    if (!*g_dirty_hooks[k].orig) *g_dirty_hooks[k].orig = gl_tab[i];
                    if (g_debug) fprintf(stderr, "EAGL(shim): dirty-tracking hook on %s\n", gl_names[i]);
                    gl_tab[i] = g_dirty_hooks[k].hook;
                }
            for (unsigned k = 0; k < sizeof g_dirty_hooks / sizeof g_dirty_hooks[0]; k++) if (!*g_dirty_hooks[k].orig) g_dirty_track = 0;   // an entry point missing: cannot track reliably
        }
        if (g_debug) {                  // list the exported entry points Mesa could not provide
            int n = 0;
            for (int i = 0; i < gl_nfuncs; i++) if (gl_tab[i] == (void *)gl_unimpl) { fprintf(stderr, "EAGL(shim): unresolved %s\n", gl_names[i]); n++; }
            fprintf(stderr, "EAGL(shim): %d/%d entry points forwarded to Mesa, %d unresolved\n", gl_nfuncs - n, gl_nfuncs, n);
        }
    });
}

// --- EAGLSharegroup --------------------------------------------------------------------------------------
@implementation EAGLSharegroup
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharedWithCompute:(BOOL)compute {
    if ((self = [super init])) {
        _private = calloc(1, sizeof *_private);
        _private->api = api;
        pthread_mutex_init(&_private->lock, NULL);
    }
    return self;
}
- (instancetype)initWithAPI:(EAGLRenderingAPI)api { return [self initWithAPI:api sharedWithCompute:NO]; }
- (instancetype)init { return [self initWithAPI:kEAGLRenderingAPIOpenGLES2]; }
- (NSUInteger)APIs { return 1u << (_private->api); }
- (void *)getGLIShared { return _private; }
- (NSString *)debugLabel { return objc_getAssociatedObject(self, @selector(debugLabel)); }
- (void)setDebugLabel:(NSString *)l { objc_setAssociatedObject(self, @selector(debugLabel), l, OBJC_ASSOCIATION_COPY_NONATOMIC); }
- (void)dealloc { if (_private) { pthread_mutex_destroy(&_private->lock); free(_private); } [super dealloc]; }
@end

// --- EAGLContext -----------------------------------------------------------------------------------------
@implementation EAGLContext

- (instancetype)initWithAPI:(EAGLRenderingAPI)api { return [self initWithAPI:api properties:nil]; }
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharegroup:(EAGLSharegroup *)sg {
    return [self initWithAPI:api properties:sg ? @{ kEAGLContextPropertySharegroup : sg } : nil];
}
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharedWithCompute:(BOOL)compute {
    return [self initWithAPI:api properties:@{ kEAGLContextPropertySharedWithCompute : @(compute) }];
}
- (instancetype)init { return nil; }

- (instancetype)initWithAPI:(EAGLRenderingAPI)api properties:(NSDictionary *)props {
    eagl_install_hooks();
    if (api < kEAGLRenderingAPIOpenGLES1 || api > kEAGLRenderingAPIOpenGLES3) { [self release]; return nil; }
    if ((self = [super init])) {
        struct _EAGLContextPrivate *p = calloc(1, sizeof *p);
        _private = p;
        p->api = api;
        p->dummy = calloc(DUMMY_W * DUMMY_H, 4);
        EAGLSharegroup *sg = props[kEAGLContextPropertySharegroup];
        p->sg = sg ? [sg retain] : [[EAGLSharegroup alloc] initWithAPI:api];
        NSString *lbl = props[kEAGLContextPropertyClientLabel];
        if ([lbl isKindOfClass:[NSString class]]) p->label = [lbl copy];
        struct _EAGLSharegroupPrivate *g = p->sg->_private;
        pthread_mutex_lock(&g->lock);
        osm_ctx share = g->nlive ? g->live[0] : NULL;
        p->osm = osm_create(api == kEAGLRenderingAPIOpenGLES1 ? 1 : (int)api, share);
        if (p->osm && g->nlive < 64) g->live[g->nlive++] = p->osm;
        pthread_mutex_unlock(&g->lock);
        if (!p->osm) { EAGL_DEBUG("OSMesaCreateContextAttribs failed (api %d)\n", (int)api); [self release]; return nil; }
        EAGL_DEBUG("context %p created api %d sharegroup %p osm %p shared-with %p\n", self, (int)api, p->sg, p->osm, share);
        p->macro = macro_ctx_new(p);   // rend = our private block; the slots ignore it (Mesa uses the thread's current context)
    }
    return self;
}

- (void)dealloc {
    struct _EAGLContextPrivate *p = _private;
    pthread_mutex_lock(&g_live_lock);
    for (int k = 0; k < g_nlive; k++) if (g_live[k].ctx == (void *)self) { CFRelease(g_live[k].surf); g_live[k] = g_live[--g_nlive]; k--; }
    pthread_mutex_unlock(&g_live_lock);
    EAGL_DEBUG("context %p dealloc (%d attachments, osm %p)\n", self, p ? p->natt : -1, p ? p->osm : NULL);
    if (p) {
        if (cur_ctx() == self) [EAGLContext setCurrentContext:nil];
        for (int i = 0; i < p->nbinds; i++) {
            [p->binds[i].drawable release];
            for (int k = 0; k < POOL_N; k++) if (p->binds[i].pool[k]) { osm_sweet_forget(IOSurfaceGetID(p->binds[i].pool[k])); CFRelease(p->binds[i].pool[k]); }
        }
        for (int i = 0; i < p->natt; i++) if (p->att[i].surf) { osm_sweet_forget(IOSurfaceGetID(p->att[i].surf)); CFRelease(p->att[i].surf); }
        if (p->sg) {
            struct _EAGLSharegroupPrivate *g = p->sg->_private;
            pthread_mutex_lock(&g->lock);
            for (int i = 0; i < g->nlive; i++) if (g->live[i] == p->osm) { g->live[i] = g->live[--g->nlive]; break; }
            pthread_mutex_unlock(&g->lock);
        }
        if (p->osm) osm_destroy(p->osm);
        [p->sg release]; [p->label release];
        free(p->dummy); macro_ctx_free(p->macro); free(p);
        _private = NULL;
    }
    [super dealloc];
}

+ (BOOL)setCurrentContext:(EAGLContext *)ctx {
    pthread_once(&g_tls_once, tls_init);
    EAGLContext *old = pthread_getspecific(g_tls);
    if (ctx) {
        struct _EAGLContextPrivate *p = ctx->_private;
        if (!osm_make_current(p->osm, p->dummy, DUMMY_W, DUMMY_H)) return NO;
        [ctx retain];
    } else {
        osm_make_current(NULL, NULL, 0, 0);
    }
    pthread_setspecific(g_tls, ctx);
    [old release];
    return YES;
}
+ (EAGLContext *)currentContext { return [[cur_ctx() retain] autorelease]; }

- (EAGLRenderingAPI)API { return _private->api; }
- (EAGLSharegroup *)sharegroup { return _private->sg; }
- (NSString *)debugLabel { return _private->label; }
- (void)setDebugLabel:(NSString *)l { [_private->label release]; _private->label = [l copy]; }
- (BOOL)isMultiThreaded { return _private->multithreaded; }
- (void)setMultiThreaded:(BOOL)m { _private->multithreaded = m; }

// Private parameter store: CoreAnimation reads/writes a few integer parameters; unknown ones just round-trip.
- (NSUInteger)setParameter:(uint32_t)param to:(int *)value { if (param < 64 && value) _private->params[param] = *value; return 0; }
- (NSUInteger)getParameter:(uint32_t)param to:(int *)value { if (value) *value = param < 64 ? _private->params[param] : 0; return 0; }

- (EAGLMacroContext *)getMacroContextPrivate { return _private->macro; }
- (EAGLMacroContext *)GetMacroContextPrivate { return _private->macro; }
+ (EAGLMacroContext *)GetMacroContextPrivate { EAGLContext *c = cur_ctx(); return c ? c->_private->macro : NULL; }

- (BOOL)setBlockFence:(void (^)(void))block onQueue:(dispatch_queue_t)queue {
    EAGLContext *c = cur_ctx();
    if (c == self) shim_glFinish();
    if (block && queue) dispatch_async(queue, block);
    return YES;
}

// --- drawables ---
static DrawBind *find_bind(struct _EAGLContextPrivate *p, GLuint rb) {
    for (int i = 0; i < p->nbinds; i++) if (p->binds[i].rb == rb) return &p->binds[i];
    return NULL;
}

- (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id<EAGLDrawable>)drawable {
    struct _EAGLContextPrivate *p = _private;
    if (cur_ctx() != self || target != GL_RENDERBUFFER) return NO;
    GLint rb = 0;
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    if (!rb) return NO;
    DrawBind *b = find_bind(p, rb);
    if (!drawable) {                                    // drop the storage
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 0, 0);
        if (b) {
            [b->drawable release]; b->drawable = nil;
            for (int k = 0; k < POOL_N; k++) if (b->pool[k]) { osm_sweet_forget(IOSurfaceGetID(b->pool[k])); CFRelease(b->pool[k]); b->pool[k] = NULL; }
            *b = p->binds[--p->nbinds];
        }
        return YES;
    }
    CGRect r = CGRectZero; CGFloat scale = 1;
    id d = (id)drawable;
    if ([d respondsToSelector:@selector(bounds)]) r = ((CGRect (*)(id, SEL))objc_msgSend)(d, @selector(bounds));
    if ([d respondsToSelector:@selector(contentsScale)]) scale = ((CGFloat (*)(id, SEL))objc_msgSend)(d, @selector(contentsScale));
    if (scale <= 0) scale = 1;
    uint32_t w = (uint32_t)ceil(r.size.width * scale), h = (uint32_t)ceil(r.size.height * scale);
    if (!w || !h) return NO;
    GLenum fmt = GL_RGBA8;
    NSDictionary *props = [d respondsToSelector:@selector(drawableProperties)] ? [d drawableProperties] : nil;
    NSString *cf = props[kEAGLDrawablePropertyColorFormat];
    if ([cf isEqual:kEAGLColorFormatRGB565]) fmt = GL_RGB565;
    else if ([cf isEqual:kEAGLColorFormatSRGBA8]) fmt = GL_SRGB8_ALPHA8;
    glRenderbufferStorage(GL_RENDERBUFFER, fmt, w, h);
    if (glGetError() != GL_NO_ERROR) return NO;
    if (!b) {
        if (p->nbinds >= MAX_BIND) return NO;
        b = &p->binds[p->nbinds++];
        memset(b, 0, sizeof *b);
        b->rb = rb;
    }
    if (b->drawable != d) { [b->drawable release]; b->drawable = [d retain]; }
    if (b->w != w || b->h != h) {
        for (int k = 0; k < POOL_N; k++) if (b->pool[k]) { osm_sweet_forget(IOSurfaceGetID(b->pool[k])); CFRelease(b->pool[k]); b->pool[k] = NULL; }
    }
    b->w = w; b->h = h; b->fmt = fmt;
    EAGL_DEBUG("renderbuffer %d <- drawable %ux%u\n", rb, w, h);
    return YES;
}

- (BOOL)presentRenderbuffer:(NSUInteger)target {
    struct _EAGLContextPrivate *p = _private;
    if (cur_ctx() != self || target != GL_RENDERBUFFER) return NO;
    GLint rb = 0;
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    DrawBind *b = rb ? find_bind(p, rb) : NULL;
    if (!b) return NO;
    BOOL opaque = YES;
    if ([b->drawable respondsToSelector:@selector(isOpaque)]) opaque = ((BOOL (*)(id, SEL))objc_msgSend)(b->drawable, @selector(isOpaque));
    IOSurfaceRef s = b->pool[b->next];
    if (!s) s = b->pool[b->next] = make_surface(b->w, b->h);
    b->next = (b->next + 1) % POOL_N;
    if (!s) return NO;
    if (!(osm_sweet_active() && osm_sweet_blit((unsigned)rb, 0, IOSurfaceGetID(s), 1, opaque))) {     // CPU fallback (softpipe, or a surface the GPU cannot use)
        uint32_t w, h;
        uint8_t *buf = read_image(self, rb, NO, 0, 0, &w, &h);
        if (!buf) return NO;
        rgba_to_surface(buf, w, h, s, YES, opaque);
        free(buf);
    }
    if ([b->drawable respondsToSelector:@selector(setContents:)])
        ((void (*)(id, SEL, id))objc_msgSend)(b->drawable, @selector(setContents:), (id)s);
    return YES;
}
- (BOOL)presentRenderbuffer:(NSUInteger)target atTime:(CFTimeInterval)t { return [self presentRenderbuffer:target]; }
- (BOOL)presentRenderbuffer:(NSUInteger)target afterMinimumDuration:(CFTimeInterval)d { return [self presentRenderbuffer:target]; }

// --- IOSurface ---
- (BOOL)attachImage:(NSUInteger)image toCoreSurface:(IOSurfaceRef)surface invertedRender:(BOOL)inverted {
    // `image` is a GL TARGET (CoreAnimation passes GL_TEXTURE_2D = 3553, found by dumping the server's calls on the phone): the image
    // currently bound at that target gets the IOSurface as its storage. A plain object name (our own tests) is still accepted.
    struct _EAGLContextPrivate *p = _private;
    int kind = 0;
    BOOL direct = NO;
    GLuint name = (GLuint)image;
    if (surface && (image == GL_TEXTURE_2D || image == GL_RENDERBUFFER || image == 0x84f5)) g_target_attach = 1;
    if (surface && (image == GL_TEXTURE_2D || image == GL_RENDERBUFFER || image == 0x84f5 /* TEXTURE_RECTANGLE */)) {
        GLint bound = 0;
        if (image == GL_RENDERBUFFER) { glGetIntegerv(GL_RENDERBUFFER_BINDING, &bound); kind = 2; }
        else { glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound); kind = 1; }
        if (!bound) return NO;
        name = (GLuint)bound;
        uint32_t w = (uint32_t)IOSurfaceGetWidth(surface), h = (uint32_t)IOSurfaceGetHeight(surface);
        if (kind == 2) glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
        else {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            if (g_direct && !inverted && osm_sweet_active() && IOSurfaceGetPixelFormat(surface) == 'BGRA' && osm_sweet_attach_direct(name, IOSurfaceGetID(surface))) direct = YES;
            // keep what the surface already shows: CoreAnimation redraws only the damaged part of a swap-chain buffer
            else if (IOSurfaceGetPixelFormat(surface) == 'BGRA')
                [self texImageIOSurface:surface target:GL_TEXTURE_2D internalFormat:GL_RGBA width:w height:h format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0 invert:!inverted];   // same row order as the sync
        }
        if (glGetError() != GL_NO_ERROR) EAGL_DEBUG("attachImage: storage for %ux%u failed\n", w, h);
    }
    int idx = -1;
    for (int i = 0; i < p->natt; i++) if (p->att[i].name == name && p->att[i].kind == kind) idx = i;
    if (!surface) {                                     // detach
        if (idx >= 0) { osm_sweet_forget(IOSurfaceGetID(p->att[idx].surf)); CFRelease(p->att[idx].surf); p->att[idx] = p->att[--p->natt]; update_cur_target(self); }
        return YES;
    }
    if (idx < 0) {
        if (p->natt >= MAX_BIND) return NO;
        idx = p->natt++;
    } else { osm_sweet_forget(IOSurfaceGetID(p->att[idx].surf)); CFRelease(p->att[idx].surf); }
    p->att[idx].name = name; p->att[idx].kind = kind; p->att[idx].surf = (IOSurfaceRef)CFRetain(surface); p->att[idx].inverted = inverted; p->att[idx].dirty = 1; p->att[idx].direct = direct;
    // CoreAnimation attaches a NEW texture to the same display surface every frame; the earlier textures keep older pixels. Syncing them all wrote
    // those stale images over the surface in array order (the flicker, the black wallpaper): only the latest attachment of a surface is valid.
    for (int j = p->natt - 1; j >= 0; j--) {
        if (j == idx || IOSurfaceGetID(p->att[j].surf) != IOSurfaceGetID(surface)) continue;
        CFRelease(p->att[j].surf);
        if (idx == p->natt - 1) idx = j;      // the last entry moves into slot j
        p->att[j] = p->att[--p->natt];
    }
    update_cur_target(self);
    if (g_debug && IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface) >= 1000000 && IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) == KERN_SUCCESS) {
        const uint8_t *sp = IOSurfaceGetBaseAddress(surface); size_t bpr = IOSurfaceGetBytesPerRow(surface), sh2 = IOSurfaceGetHeight(surface), sw2 = IOSurfaceGetWidth(surface);
        if (sp) fprintf(stderr, "EAGL(shim): attach: surface %u holds first %02x%02x%02x%02x centre %02x%02x%02x%02x (direct %d)\n", IOSurfaceGetID(surface), sp[0], sp[1], sp[2], sp[3],
                        sp[(sh2 / 2) * bpr + (sw2 / 2) * 4], sp[(sh2 / 2) * bpr + (sw2 / 2) * 4 + 1], sp[(sh2 / 2) * bpr + (sw2 / 2) * 4 + 2], sp[(sh2 / 2) * bpr + (sw2 / 2) * 4 + 3], direct);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
    EAGL_DEBUG("[ctx %p] attachImage %lu -> %s %u, IOSurface %u (%zux%zu) inverted=%d\n", self, (unsigned long)image, kind == 2 ? "renderbuffer" : kind == 1 ? "texture" : "object", name,
               IOSurfaceGetID(surface), IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), inverted);
    return YES;
}

- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane {
    return [self texImageIOSurface:ioSurface target:target internalFormat:internalFormat width:width height:height
                            format:format type:type plane:plane invert:YES];   // public form: rows as stored
}

- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane invert:(BOOL)invert {
    if (ioSurface) EAGL_DEBUG("texImageIOSurface source: surface %u fourcc %08x planes %zu %zux%zu bpr %zu\n", IOSurfaceGetID(ioSurface), (unsigned)IOSurfaceGetPixelFormat(ioSurface), IOSurfaceGetPlaneCount(ioSurface), IOSurfaceGetWidth(ioSurface), IOSurfaceGetHeight(ioSurface), IOSurfaceGetBytesPerRow(ioSurface));
    if (g_debug && ioSurface && IOSurfaceGetWidth(ioSurface) * IOSurfaceGetHeight(ioSurface) >= 400000 && IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL) == KERN_SUCCESS) {
        const uint8_t *q = IOSurfaceGetBaseAddress(ioSurface); size_t qb = IOSurfaceGetBytesPerRow(ioSurface), qh = IOSurfaceGetHeight(ioSurface), qw = IOSurfaceGetWidth(ioSurface), nz = 0, tot = 0;
        if (q) { for (size_t y = 3; y < qh; y += 37) for (size_t x = 5; x < qw * 4 && x < qb; x += 41) { tot++; if (q[y * qb + x]) nz++; } }
        fprintf(stderr, "EAGL(shim): source content: surface %u non-zero samples %zu of %zu (mapped %d) alloc-size %zu\n", IOSurfaceGetID(ioSurface), nz, tot, q != NULL, IOSurfaceGetAllocSize(ioSurface));
        IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    }
    EAGL_DEBUG("texImageIOSurface %p target 0x%lx ifmt 0x%lx %ux%u fmt 0x%lx type 0x%lx invert %d\n", ioSurface, (unsigned long)target, (unsigned long)internalFormat, width, height, (unsigned long)format, (unsigned long)type, invert);
    const uint32_t seed_at_copy = ioSurface ? IOSurfaceGetSeed(ioSurface) : 0;     // taken before the copy: a write during it is picked up at the next bind
    if (cur_ctx() != self || !ioSurface || (plane != 0 && plane >= IOSurfaceGetPlaneCount(ioSurface))) do { EAGL_DEBUG("texImageIOSurface: refused (reason 1) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    OSType pf = IOSurfaceGetPixelFormat(ioSurface);
    // multi-plane surfaces (420 video-like snapshots: Y and CbCr planes uploaded as separate textures): geometry and memory of the requested plane
    const BOOL planar = IOSurfaceGetPlaneCount(ioSurface) > 0;
    if (plane) EAGL_DEBUG("texImageIOSurface: plane %u of surface %u (%zu planes) %zux%zu bpr %zu\n", plane, IOSurfaceGetID(ioSurface), IOSurfaceGetPlaneCount(ioSurface), IOSurfaceGetWidthOfPlane(ioSurface, plane), IOSurfaceGetHeightOfPlane(ioSurface, plane), IOSurfaceGetBytesPerRowOfPlane(ioSurface, plane));
    size_t sw = planar ? IOSurfaceGetWidthOfPlane(ioSurface, plane) : IOSurfaceGetWidth(ioSurface), sh = planar ? IOSurfaceGetHeightOfPlane(ioSurface, plane) : IOSurfaceGetHeight(ioSurface);
    uint32_t w = width < sw ? width : (uint32_t)sw, h = height < sh ? height : (uint32_t)sh;
    if (!w || !h) do { EAGL_DEBUG("texImageIOSurface: refused (reason 2) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    // Bytes per texel from the GL format/type CoreAnimation asks for (it uploads A8 masks, LA8, RGBA half float gradients, BGRA ...).
    size_t comps = 0, csz = 1;
    switch (format) {
    case 0x1906: case 0x1909: case 0x1903: comps = 1; break;                 // ALPHA, LUMINANCE, RED
    case 0x190a: case 0x8227: comps = 2; break;                              // LUMINANCE_ALPHA, RG
    case 0x1907: comps = 3; break;                                           // RGB
    case 0x1908: case GL_BGRA_EXT: comps = 4; break;                         // RGBA, BGRA
    default: do { EAGL_DEBUG("texImageIOSurface: refused (reason 3) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    }
    switch (type) {
    case 0x1401: csz = 1; break;                                             // UNSIGNED_BYTE
    case 0x140b: case 0x8d61: csz = 2; break;                                // HALF_FLOAT(_OES)
    case 0x1406: csz = 4; break;                                             // FLOAT
    case 0x8363: case 0x8033: case 0x8034: comps = 1; csz = 2; break;        // packed 16 bit
    case 0x8368: comps = 1; csz = 4; break;                                  // UNSIGNED_INT_2_10_10_10_REV
    default: do { EAGL_DEBUG("texImageIOSurface: refused (reason 4) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    }
    size_t bpp = comps * csz, bpr = planar ? IOSurfaceGetBytesPerRowOfPlane(ioSurface, plane) : IOSurfaceGetBytesPerRow(ioSurface);
    if (w * bpp > bpr) do { EAGL_DEBUG("texImageIOSurface: refused (reason 5) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    BOOL bgra8 = (format == GL_BGRA_EXT && type == 0x1401);                  // swizzled to RGBA below (portable across ES implementations)
    // Zero-copy sampling (opt-in): kind of the GL upload that the GPU can sample straight from the surface memory (A8, L8, LA8, RGBA8, BGRA8, RGBA16F)
    if (g_wrapsample && !g_nowrap && !g_reupload && (GLenum)target == GL_TEXTURE_2D && !planar && osm_sweet_active()) {
        int kind = 0;
        if (type == 0x1401) kind = format == 0x1906 ? 1 : format == 0x1909 ? 2 : format == 0x190a ? 3 : format == 0x1908 ? 4 : format == GL_BGRA_EXT ? 5 : 0;
        else if ((type == 0x140b || type == 0x8d61) && format == 0x1908) kind = 6;
        GLint wb = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &wb);
        if (kind && wb && osm_sweet_wrap_texture((unsigned)wb, IOSurfaceGetID(ioSurface), kind, w, h)) {
            pthread_mutex_lock(&g_live_lock);
            int k = -1; for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == self && g_live[i].name == (GLuint)wb) { k = i; break; }
            if (k < 0 && g_nlive < MAX_LIVE) { k = g_nlive++; memset(&g_live[k], 0, sizeof g_live[k]); }
            if (k >= 0) {
                if (g_live[k].surf && g_live[k].surf != ioSurface) CFRelease(g_live[k].surf);
                if (g_live[k].surf != ioSurface) CFRetain(ioSurface);
                g_live[k] = (LiveSrc){ self, (GLuint)wb, ioSurface, seed_at_copy, w, h, plane, (GLenum)internalFormat, (GLenum)format, (GLenum)type, invert, YES };
            }
            pthread_mutex_unlock(&g_live_lock);
            glTexParameteri((GLenum)target, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri((GLenum)target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            EAGL_DEBUG("texImageIOSurface: surface %u sampled by the GPU in place (kind %d)\n", IOSurfaceGetID(ioSurface), kind);
            return k >= 0;
        }
    }
    uint8_t *tmp = malloc((size_t)w * h * bpp);
    if (!tmp) do { EAGL_DEBUG("texImageIOSurface: refused (reason 6) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    kern_return_t lk = IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *src = lk == KERN_SUCCESS ? (planar ? IOSurfaceGetBaseAddressOfPlane(ioSurface, plane) : IOSurfaceGetBaseAddress(ioSurface)) : NULL;
    if (g_debug && src) { size_t nz = 0, tot = (size_t)w * h * bpp < 65536 ? (size_t)w * h * bpp : 65536; for (size_t i = 0; i < tot; i++) if (src[(i / (w * bpp)) * bpr + i % (w * bpp)]) nz++; EAGL_DEBUG("texImageIOSurface: surface %u plane %u content: %zu of %zu bytes non-zero\n", IOSurfaceGetID(ioSurface), plane, nz, tot); }
    if (!src) {                         // not CPU-mappable here (the render server's display surfaces): nothing to read
        if (lk == KERN_SUCCESS) IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
        EAGL_DEBUG("texImageIOSurface: surface %u has no CPU mapping (lock %x)\n", IOSurfaceGetID(ioSurface), lk);
        free(tmp);
        do { EAGL_DEBUG("texImageIOSurface: refused (reason 7) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    }
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *sp = src + ((invert || g_target_attach) ? y : (h - 1 - y)) * bpr;   // render server (target-form attach): images keep their native top-down rows; CARenderer-style clients: flipped unless invert
        uint8_t *dp = tmp + (size_t)y * w * bpp;
        if (bgra8) for (uint32_t x = 0; x < w; x++) { uint32_t q = ((const uint32_t *)sp)[x]; ((uint32_t *)dp)[x] = (q & 0xff00ff00u) | ((q & 0xff) << 16) | ((q >> 16) & 0xff); }
        else memcpy(dp, sp, (size_t)w * bpp);
    }
    IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    (void)pf;
    GLint oldAlign = 4, oldRow = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &oldAlign);
    glGetIntegerv(GL_UNPACK_ROW_LENGTH, &oldRow);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    GLenum ifmt = internalFormat == GL_BGRA_EXT ? GL_RGBA : (GLenum)internalFormat;
    if (g_reupload) glTexSubImage2D((GLenum)target, 0, 0, 0, w, h, bgra8 ? GL_RGBA : (GLenum)format, (GLenum)type, tmp);
    else glTexImage2D((GLenum)target, 0, ifmt, w, h, 0, bgra8 ? GL_RGBA : (GLenum)format, (GLenum)type, tmp);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) EAGL_DEBUG("  glTexImage2D failed 0x%x (ifmt 0x%lx fmt 0x%lx type 0x%lx)\n", err, (unsigned long)internalFormat, (unsigned long)format, (unsigned long)type);
    // IOSurface textures have no mip chain: make the texture complete with sane defaults (the client overrides them if it cares).
    if (!g_reupload) {
        glTexParameteri((GLenum)target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri((GLenum)target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    if (!g_reupload && err == GL_NO_ERROR && (GLenum)target == GL_TEXTURE_2D) {      // remember it for seed checks
        GLint bound = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
        pthread_mutex_lock(&g_live_lock);
        int k = -1; for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == self && g_live[i].name == (GLuint)bound) { k = i; break; }
        if (bound && k < 0 && g_nlive < MAX_LIVE) { k = g_nlive++; memset(&g_live[k], 0, sizeof g_live[k]); }
        if (bound && k >= 0) {
            if (g_live[k].surf && g_live[k].surf != ioSurface) CFRelease(g_live[k].surf);
            if (g_live[k].surf != ioSurface) CFRetain(ioSurface);
            g_live[k] = (LiveSrc){ self, (GLuint)bound, ioSurface, seed_at_copy, w, h, plane, (GLenum)internalFormat, (GLenum)format, (GLenum)type, invert };
        }
        pthread_mutex_unlock(&g_live_lock);
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, oldAlign);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, oldRow);
    free(tmp);
    return err == GL_NO_ERROR;
}

@end

#pragma GCC visibility push(default)
// --- C SPI exported by Apple's OpenGLES.framework -------------------------------------------------------
EAGLMacroContext *EAGLGetCurrentMacroContextPrivate(void) {
    EAGLContext *c = cur_ctx();
    return c ? [c getMacroContextPrivate] : NULL;
}
void *GLIContextFromEAGLContext(EAGLContext *c) { return c ? (void *)c->_private : NULL; }
void EAGLMemoryNotificationRecycling(void) {}
// GLC* dispatch-selection entry points: no function-table swapping behind Mesa; accept and ignore.
void GLCBackDispatch(void) {}
void GLCFrontDispatch(void) {}
void *GLCGetProfilerStorage(void) { return NULL; }
void GLCRestoreDispatch(void) {}
void GLCRestoreDispatchFunction(void) {}
void GLCSelectDispatchBounded(void) {}
void GLCSelectDispatchFunction(void) {}
void GLCSetCompilationPerformanceCallback(void) {}
void GLCSetProfilerStorage(void) {}
#pragma GCC visibility pop

#ifdef EAGL_INJECT
static int patch_class(Class ours, const char *realName) {
    Class real = objc_getClass(realName);
    if (!real || !ours) return 0;
    for (int meta = 0; meta < 2; meta++) {
        Class from = meta ? object_getClass(ours) : ours, to = meta ? object_getClass(real) : real;
        unsigned n = 0;
        Method *ms = class_copyMethodList(from, &n);
        for (unsigned i = 0; i < n; i++)
            class_replaceMethod(to, method_getName(ms[i]), method_getImplementation(ms[i]), method_getTypeEncoding(ms[i]));
        free(ms);
        if (getenv("EAGL_SHIM_DEBUG")) fprintf(stderr, "EAGL(shim): patched %u %s methods of %s\n", n, meta ? "class" : "instance", realName);
    }
    return 1;
}
// The inserted library initializes before the process links OpenGLES in some cases: patch as soon as the real classes exist
// (now, or when a later image load brings them), exactly once.
static void try_patch(void) {
    static int done;
    if (done) return;
    if (objc_getClass("EAGLContext") && objc_getClass("EAGLSharegroup")) {
        patch_class(objc_getClass("BGEAGLContext"), "EAGLContext");
        patch_class(objc_getClass("BGEAGLSharegroup"), "EAGLSharegroup");
        done = 1;
    }
}
static void on_image(const struct mach_header *mh, intptr_t slide) { (void)mh; (void)slide; try_patch(); }
__attribute__((constructor)) static void eagl_inject_patch(void) {
    try_patch();
    _dyld_register_func_for_add_image(on_image);
}
#endif
