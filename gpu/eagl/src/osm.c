// SPDX-License-Identifier: MIT
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <GL/osmesa.h>
#include "osm.h"

#define OSMESA_ES_PROFILE 0x36      // added by gpu/eagl/mesa/0001-osmesa-es-profile.patch

// Mesa shader disk cache (ir3 binaries keyed by sha1 of the shader + the LC_UUID of this libOSMesa): compiled once, not at every boot or effect.
// Directory: <BGL_CACHE_DIR or /private/var/tmp/bergamota-gl-cache>/<uid> (parent 1777 so every UI process can create its own; per-user subdirectory
// so the owner is always the writer). MESA_SHADER_CACHE_DIR / MESA_SHADER_CACHE_DISABLE from the environment win; size limit 128M (MESA_SHADER_CACHE_MAX_SIZE).
static void setup_shader_cache(void) {
    if (getenv("MESA_SHADER_CACHE_DISABLE") || getenv("MESA_SHADER_CACHE_DIR")) return;
    const char *base = getenv("BGL_CACHE_DIR");
    if (!base || !*base) base = "/private/var/tmp/bergamota-gl-cache";
    char dir[512];
    if (mkdir(base, 01777) != 0 && errno != EEXIST) return;
    chmod(base, 01777);
    snprintf(dir, sizeof dir, "%s/%u", base, (unsigned)getuid());
    if (mkdir(dir, 0700) != 0 && errno != EEXIST) return;
    if (access(dir, W_OK) != 0) return;        // owned by someone else and not writable: run without the cache
    setenv("MESA_SHADER_CACHE_DIR", dir, 0);
    setenv("MESA_SHADER_CACHE_MAX_SIZE", "128M", 0);
}

osm_ctx osm_create(int es_api, osm_ctx share) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, setup_shader_cache);
    const int attr[] = {
        OSMESA_FORMAT, OSMESA_RGBA, OSMESA_DEPTH_BITS, 0, OSMESA_STENCIL_BITS, 0,
        OSMESA_PROFILE, OSMESA_ES_PROFILE,
        OSMESA_CONTEXT_MAJOR_VERSION, es_api, OSMESA_CONTEXT_MINOR_VERSION, 0, 0 };
    return (osm_ctx)OSMesaCreateContextAttribs(attr, (OSMesaContext)share);
}
void osm_destroy(osm_ctx c) { OSMesaDestroyContext((OSMesaContext)c); }
int osm_make_current(osm_ctx c, void *buf, int w, int h) {
    if (!c) { OSMesaMakeCurrent(NULL, NULL, GL_UNSIGNED_BYTE, 0, 0); return 1; }
    return OSMesaMakeCurrent((OSMesaContext)c, buf, GL_UNSIGNED_BYTE, w, h) ? 1 : 0;
}
void *osm_getproc(const char *name) { return (void *)OSMesaGetProcAddress(name); }

extern int OSMesaSweetActive(void);
extern int OSMesaSweetBlit(unsigned name, int is_texture, unsigned surface_id, int flip, int opaque);
extern void OSMesaSweetForgetSurface(unsigned surface_id);
int osm_sweet_active(void) { return OSMesaSweetActive(); }
int osm_sweet_blit(unsigned name, int is_texture, unsigned surface_id, int flip, int opaque) { return OSMesaSweetBlit(name, is_texture, surface_id, flip, opaque); }
void osm_sweet_forget(unsigned surface_id) { OSMesaSweetForgetSurface(surface_id); }

extern void OSMesaSweetStats(double *out, int n);
void osm_sweet_stats(double *out, int n) { OSMesaSweetStats(out, n); }
extern int OSMesaSweetAttachDirect(unsigned name, unsigned surface_id);
extern void OSMesaSweetDirectSync(unsigned surface_id);
int osm_sweet_attach_direct(unsigned name, unsigned surface_id) { return OSMesaSweetAttachDirect(name, surface_id); }
void osm_sweet_direct_sync(unsigned surface_id) { OSMesaSweetDirectSync(surface_id); }
extern int OSMesaSweetSurfaceAlias(unsigned surface_id, void **base, unsigned *bpr, unsigned *w, unsigned *h);
extern void OSMesaSweetAliasSync(unsigned surface_id);
int osm_sweet_surface_alias(unsigned surface_id, void **base, unsigned *bpr, unsigned *w, unsigned *h) { return OSMesaSweetSurfaceAlias(surface_id, base, bpr, w, h); }
void osm_sweet_alias_sync(unsigned surface_id) { OSMesaSweetAliasSync(surface_id); }
extern void OSMesaSweetZeroTexture(void);
void osm_sweet_zero_texture(void) { OSMesaSweetZeroTexture(); }
extern int OSMesaSweetWrapTexture(unsigned name, unsigned surface_id, int kind, unsigned w, unsigned h);
extern void OSMesaSweetWrapSync(unsigned surface_id);
int osm_sweet_wrap_texture(unsigned name, unsigned surface_id, int kind, unsigned w, unsigned h) { return OSMesaSweetWrapTexture(name, surface_id, kind, w, h); }
void osm_sweet_wrap_sync(unsigned surface_id) { OSMesaSweetWrapSync(surface_id); }
