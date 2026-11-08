// SPDX-License-Identifier: MIT
// EAGLMacroContext: the structure QuartzCore's GLES renderer gets from -[EAGLContext getMacroContextPrivate] and calls
// GL through, as `((fn)ctx->slot[off])(ctx->rend, args...)`. Layout (22H352, see docs/GPU_EAGL.md): rend at +0, one function
// pointer per entry point at the offsets in macro_slots[] (the same order as macOS's gliDispatch.h for the first ~340 slots,
// Apple's own ES extension after that). Our slots point at forwarders into the same Mesa entry points the gl* exports use.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "gl_tab.h"
#include "macro_ctx.h"
#include "osm.h"

static void macro_unmapped(void) { static int n; if (n++ < 5) fprintf(stderr, "OpenGLES(shim): call through an unmapped EAGLMacroContext slot\n"); }

extern void *const mt_thunks[];
static volatile int g_trace_on;
__attribute__((visibility("default"))) void EAGLShimSetTrace(int on) { g_trace_on = on; }
void gl_trace_hook(int idx, long a, long b, long c, long d) {
    if (!g_trace_on) return;
    fprintf(stderr, "GL %s(0x%lx, 0x%lx, 0x%lx, 0x%lx)\n", gl_names[idx], a, b, c, d);
    if (!strcmp(gl_names[idx], "glShaderSource") && c && getenv("EAGL_TRACE_SHADERS")) {
        const char *const *src = (const char *const *)c;
        for (long i = 0; i < b; i++) fprintf(stderr, "---- shader %ld source %ld\n%s\n----\n", a, i, src[i]);
    }
}

void *macro_ctx_new(void *rend) {
    void *const *thunks = getenv("EAGL_TRACE") ? mt_thunks : ms_thunks;
    void **m = calloc(1, MACRO_CTX_SIZE);
    if (!m) return NULL;
    m[0] = rend;
    for (unsigned o = 8; o + 8 <= MACRO_CTX_SIZE; o += 8) m[o / 8] = (void *)macro_unmapped;
    for (int s = 0; s < macro_nslots; s++) {
        int k = -1;
        for (int i = 0; i < gl_nfuncs; i++) if (!strcmp(gl_names[i], macro_slots[s].name)) { k = i; break; }
        if (k >= 0 && macro_slots[s].off + 8 <= MACRO_CTX_SIZE) {
            // aliases (glFoo / glFooOES) share a slot: prefer the entry without a vendor suffix
            void **dst = &m[macro_slots[s].off / 8];
            if (*dst == (void *)macro_unmapped || strlen(gl_names[k]) < 64) *dst = thunks[k];
        }
    }
    return m;
}
void macro_ctx_free(void *m) { free(m); }

// --- wrappers for entry points with 8+ arguments (arguments beyond x7 live on the stack, so the register shift is not enough) ---
typedef unsigned U; typedef int I; typedef long L;
static void *target(const char *name) {
    for (int i = 0; i < gl_nfuncs; i++) if (!strcmp(gl_names[i], name)) return gl_tab[i];
    return (void *)macro_unmapped;
}
#define CACHED(name) static void *t; if (!t) t = target(name)

// Debug log of the big/compressed texture uploads CoreAnimation does through the 8+ argument entry points (EAGL_SHIM_DEBUG): what it asks for,
// where the data comes from (client pointer or a bound pixel-unpack buffer) and the GL error afterwards.
static int dbg_on(void) { static int v = -1; if (v < 0) v = getenv("EAGL_SHIM_DEBUG") != NULL; return v; }
static unsigned gl_err(void) { static unsigned (*ge)(void); if (!ge) ge = (unsigned (*)(void))target("glGetError"); return ge(); }
static int gl_int(unsigned pname) { static void (*gi)(unsigned, int *); int v = -1; if (!gi) gi = (void (*)(unsigned, int *))target("glGetIntegerv"); gi(pname, &v); return v; }
#define UPLOAD_LOG(name, tgt, lvl, ifmt, w, h, size, data) do { if (dbg_on() && (size) > 100000 || dbg_on() && !strncmp(name, "Compressed", 10) && (w) * (h) > 20000) \
    fprintf(stderr, "EAGL(shim): %s target 0x%x level %d ifmt 0x%x %dx%d size %ld data %p unpack-buffer %d -> error 0x%x\n", name, (unsigned)(tgt), (int)(lvl), (unsigned)(ifmt), (int)(w), (int)(h), (long)(size), (const void *)(data), gl_int(0x88EF), gl_err()); } while (0)

void mw_CompressedTexImage2D(void *r, U a, I b, U c, I d, I e, I f, I g, const void *p) { CACHED("glCompressedTexImage2D"); ((void (*)(U, I, U, I, I, I, I, const void *))t)(a, b, c, d, e, f, g, p); UPLOAD_LOG("CompressedTexImage2D", a, b, c, d, e, g, p); }
void mw_TexImage2D(void *r, U a, I b, I c, I d, I e, I f, U g, U h, const void *p) { CACHED("glTexImage2D"); ((void (*)(U, I, I, I, I, I, U, U, const void *))t)(a, b, c, d, e, f, g, h, p); if (!p && b == 0 && a == 0xde1 && (long)d * e > 0 && (long)d * e <= 4000000) { static int on = -1; if (on < 0) on = getenv("BGL_ZERO") != NULL; if (on) osm_sweet_zero_texture();   /* opt-in: with it backboardd stopped submitting GPU work on the phone */ } UPLOAD_LOG("TexImage2D", a, b, c, d, e, (long)d * e * 4, p); }
void mw_TexSubImage2D(void *r, U a, I b, I c, I d, I e, I f, U g, U h, const void *p) { CACHED("glTexSubImage2D"); ((void (*)(U, I, I, I, I, I, U, U, const void *))t)(a, b, c, d, e, f, g, h, p); }
void mw_CopyTexImage2D(void *r, U a, I b, U c, I d, I e, I f, I g, I h) { CACHED("glCopyTexImage2D"); ((void (*)(U, I, U, I, I, I, I, I))t)(a, b, c, d, e, f, g, h); }
void mw_CopyTexSubImage2D(void *r, U a, I b, I c, I d, I e, I f, I g, I h) { CACHED("glCopyTexSubImage2D"); ((void (*)(U, I, I, I, I, I, I, I))t)(a, b, c, d, e, f, g, h); }
void mw_CompressedTexSubImage2D(void *r, U a, I b, I c, I d, I e, I f, U g, I h, const void *p) { CACHED("glCompressedTexSubImage2D"); ((void (*)(U, I, I, I, I, I, U, I, const void *))t)(a, b, c, d, e, f, g, h, p); UPLOAD_LOG("CompressedTexSubImage2D", a, b, g, e, f, h, p); }
void mw_TexImage3D(void *r, U a, I b, I c, I d, I e, I f, I g, U h, U i, const void *p) { CACHED("glTexImage3D"); ((void (*)(U, I, I, I, I, I, I, U, U, const void *))t)(a, b, c, d, e, f, g, h, i, p); }
void mw_TexSubImage3D(void *r, U a, I b, I c, I d, I e, I f, I g, I h, U i, U j, const void *p) { CACHED("glTexSubImage3D"); ((void (*)(U, I, I, I, I, I, I, I, U, U, const void *))t)(a, b, c, d, e, f, g, h, i, j, p); }
void mw_CopyTexSubImage3D(void *r, U a, I b, I c, I d, I e, I f, I g, I h, I i) { CACHED("glCopyTexSubImage3D"); ((void (*)(U, I, I, I, I, I, I, I, I))t)(a, b, c, d, e, f, g, h, i); }
void mw_CompressedTexImage3D(void *r, U a, I b, U c, I d, I e, I f, I g, I h, const void *p) { CACHED("glCompressedTexImage3D"); ((void (*)(U, I, U, I, I, I, I, I, const void *))t)(a, b, c, d, e, f, g, h, p); }
void mw_CompressedTexSubImage3D(void *r, U a, I b, I c, I d, I e, I f, I g, I h, U i, I j, const void *p) { CACHED("glCompressedTexSubImage3D"); ((void (*)(U, I, I, I, I, I, I, I, U, I, const void *))t)(a, b, c, d, e, f, g, h, i, j, p); }
void mw_BlitFramebuffer(void *r, I a, I b, I c, I d, I e, I f, I g, I h, U i, U j) { CACHED("glBlitFramebuffer"); ((void (*)(I, I, I, I, I, I, I, I, U, U))t)(a, b, c, d, e, f, g, h, i, j); }
