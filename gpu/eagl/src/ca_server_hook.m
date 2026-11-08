// SPDX-License-Identifier: MIT
// Injection build only: make CoreAnimation's render server (backboardd) draw with CA::OGL on our EAGL shim.
//
// Finding (docs/GPU_EAGL.md): QuartzCore 22H352 has no code that creates an EAGLContext for the render server. The server asks its
// "renderer" through a C++ virtual (vtable slot 49, +0x188): the Metal implementation builds a CA::OGL::MetalContext when an MTLDevice
// exists and otherwise returns NULL, which makes every frame take the CPU software renderer (no backdrop blur). The GLES context class
// of CARenderer (CA::OGL::GLESContext, constructor sub_1848F968C(obj, EAGLContext*)) is still in the binary and implements the same
// virtual interface. This hook wraps slot 49 of the two server classes that implement it: when the original returns NULL it builds the
// same objects the Metal implementation builds, but around a GLES context on a shim EAGLContext, and returns that renderer.
// Any doubt (QuartzCore not the expected build, vtable not writable, context creation failing) leaves the original behaviour.
//
// All addresses are unslid addresses of QuartzCore 22H352 (iPhone11,8 root); every one is checked against code bytes before use.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>
#import <malloc/malloc.h>
#include <stdio.h>
#include <string.h>

#define QC_BASE 0x18470f000ull
#define A(x) ((void *)(qc_base + ((x) - QC_BASE)))

// code points (function entries) with the first instruction words expected (PAC instructions may be NOPs after Renegade's rewrite:
// only the first word, the PACIBSP hint, is compared)
static const struct { uint64_t addr; uint32_t first; const char *what; } SIG[] = {
    { 0x1848f968c, 0xd503237f, "CA::OGL::GLESContext ctor" },
    { 0x184a33b0c, 0xd503237f, "CARenderer init (caller of the ctor)" },
    { 0x18476d7c4, 0xd503237f, "server renderer() class A" },
    { 0x1848c4908, 0xd503237f, "server renderer() class B" },
    { 0x18488ef40, 0xf9405008, "context flags update" },
};
#define SLOT_A 0x1ef97ce70ull           // vtable slot 49 of class A (original -> 0x18476d7c4)
#define SLOT_B 0x1ef97e908ull           // vtable slot 49 of class B (original -> 0x1848c4908)
#define FN_GLES_CTOR 0x1848f968cull     // void *ctor(void *obj, EAGLContext *)
#define FN_FLAGS_UPD 0x18488ef40ull     // void f(ctx), called when the 0x2000200 flag bits changed
#define G_DWORD_FLAGS 0x1eb38328cull    // dword_1EB38328C
#define G_ZONE_ONCE  0x1ed834c88ull     // dispatch_once predicate of the CA malloc zone
#define FN_ZONE_INIT 0x1847f84c8ull
#define G_ZONE       0x1ed836630ull     // CA's malloc zone

static uintptr_t qc_base;
static void *(*orig_a)(char *), *(*orig_b)(char *);
static id g_ctx;
static int g_debug;

static void *zone_calloc(size_t n) {
    static void *(*zc)(malloc_zone_t *, size_t, size_t, unsigned long long);
    if (!zc) zc = dlsym(RTLD_DEFAULT, "malloc_type_zone_calloc");
    long *pred = A(G_ZONE_ONCE);
    if (*pred != -1) dispatch_once_f((dispatch_once_t *)pred, NULL, (dispatch_function_t)A(FN_ZONE_INIT));
    malloc_zone_t *z = *(malloc_zone_t **)A(G_ZONE);
    if (zc && z) return zc(z, 1, n, 3740020753ull);
    return calloc(1, n);
}

static id shim_context(void) {
    if (g_ctx) return g_ctx;
    Class c = objc_getClass("EAGLContext");
    if (!c) return nil;
    id o = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("alloc"));
    o = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(o, sel_registerName("initWithAPI:"), 3);
    if (!o) return nil;
    g_ctx = o;
    return o;
}

// The body of the Metal implementation (sub_18476D7C4 / sub_1848C4908) after the device exists, with a GLES context instead.
// off_ctx/off_ren: where the server keeps the context and the renderer (class A: 1024/1032, class B: 696/704).
static void *make_gl_renderer(char *srv, int off_ctx, int off_ren, uint32_t flags_or, int use_753) {
    char *shared = *(char **)(srv + 96);
    id ec = shim_context();
    if (!ec) return NULL;
    ((BOOL (*)(id, SEL, id))objc_msgSend)((id)objc_getClass("EAGLContext"), sel_registerName("setCurrentContext:"), ec);
    char *ctx = zone_calloc(2232);
    if (!ctx) return NULL;
    ((void *(*)(void *, id))A(FN_GLES_CTOR))(ctx, ec);
    char *wrap = zone_calloc(104);
    void *scratch = malloc(0x40000);
    if (!wrap || !scratch) return NULL;
    *(void **)wrap = ctx;
    *(void **)(wrap + 48) = scratch;
    *(int *)(wrap + 96) = 1;
    *(void **)(srv + off_ctx) = ctx;
    *(void **)(srv + off_ren) = wrap;
    *(void **)(shared + 312) = wrap;
    // flags of the context, as the original tail does
    uint32_t v10;
    if (use_753) v10 = ((*(uint32_t *)(shared + 753) & 0x4000) ? 33685520u : 131088u) | *(uint32_t *)(srv + 184);
    else v10 = *(uint32_t *)(srv + 184) | flags_or;
    uint32_t old = *(uint32_t *)(ctx + 224);
    *(uint32_t *)(ctx + 224) = v10;
    *(uint32_t *)(ctx + 432) = *(uint32_t *)A(G_DWORD_FLAGS) | v10;
    // class A compares with the new value, class B with the server's own flag word (as the originals do)
    if ((((old ^ (use_753 ? v10 : *(uint32_t *)(srv + 184))) & 0x2000200)) != 0) ((void (*)(void *))A(FN_FLAGS_UPD))(ctx);
    if (g_debug) fprintf(stderr, "ca_server_hook: GLES renderer %p (context %p) installed in server %p\n", wrap, ctx, srv);
    return wrap;
}

static void *hook_a(char *srv) {
    void *r = orig_a(srv);
    if (r) return r;
    if (g_debug) fprintf(stderr, "ca_server_hook: class A renderer() returned NULL (no Metal device): building GLES\n");
    return make_gl_renderer(srv, 1024, 1032, 0, 1);
}
static void *hook_b(char *srv) {
    void *r = orig_b(srv);
    if (r) return r;
    if (g_debug) fprintf(stderr, "ca_server_hook: class B renderer() returned NULL (no Metal device): building GLES\n");
    return make_gl_renderer(srv, 696, 704, 0x20010, 0);
}

static int patch_slot(uint64_t slot_unslid, void *hook, void **orig) {
    void **p = A(slot_unslid);
    vm_address_t page = (vm_address_t)p & ~0x3fffull;
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { if (g_debug) fprintf(stderr, "ca_server_hook: vm_protect %p failed %d\n", (void *)page, kr); return 0; }
    *orig = *p;
    *p = hook;
    vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ);
    return 1;
}

static void try_install(const struct mach_header *mh) {
    static int done;
    Dl_info di;
    if (done || !dladdr(mh, &di) || !di.dli_fname || !strstr(di.dli_fname, "/QuartzCore.framework/QuartzCore")) return;
    done = 1;
    qc_base = (uintptr_t)mh;
    g_debug = getenv("EAGL_SHIM_DEBUG") != NULL;
    if (getenv("BGL_CA_HOOK") == NULL || !strcmp(getenv("BGL_CA_HOOK"), "0")) { if (g_debug) fprintf(stderr, "ca_server_hook: disabled\n"); return; }
    for (unsigned i = 0; i < sizeof SIG / sizeof *SIG; i++) {
        uint32_t w = *(uint32_t *)A(SIG[i].addr);
        if (w != SIG[i].first) { fprintf(stderr, "ca_server_hook: QuartzCore is not the expected build (%s: %08x), not hooking\n", SIG[i].what, w); return; }
    }
    int a = patch_slot(SLOT_A, (void *)hook_a, (void **)&orig_a);
    int b = patch_slot(SLOT_B, (void *)hook_b, (void **)&orig_b);
    fprintf(stderr, "ca_server_hook: QuartzCore %p: class A %s, class B %s\n", (void *)mh, a ? "hooked" : "NOT hooked", b ? "hooked" : "NOT hooked");
}

static void on_image(const struct mach_header *mh, intptr_t slide) { (void)slide; try_install(mh); }
__attribute__((constructor)) static void ca_server_hook_init(void) { _dyld_register_func_for_add_image(on_image); }
