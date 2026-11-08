// SPDX-License-Identifier: MIT
// Thin C wrapper around Mesa's OSMesa so that no desktop GL header meets the OpenGLES headers.
#ifndef OSM_H
#define OSM_H
typedef void *osm_ctx;
osm_ctx osm_create(int es_api, osm_ctx share);      // es_api: 1, 2 or 3; returns NULL on failure
void osm_destroy(osm_ctx c);
int osm_make_current(osm_ctx c, void *rgba_buf, int w, int h);   // c == NULL: release the current context
void *osm_getproc(const char *name);
// Hardware path (Mesa patch 0002, freedreno on the Adreno 630): 1 when contexts run on the GPU. The blit copies a renderbuffer
// (is_texture 0) or texture level 0 of the current context into an IOSurface (BGRA, linear) with the GPU; 0 = use the CPU path.
int osm_sweet_active(void);
int osm_sweet_blit(unsigned name, int is_texture, unsigned surface_id, int flip, int opaque);
void osm_sweet_forget(unsigned surface_id);
// Zero-copy display buffer: texture `name` becomes the memory of the IOSurface (no blit); direct_sync = finish the GPU work + BO_SYNC.
int osm_sweet_attach_direct(unsigned name, unsigned surface_id);
void osm_sweet_direct_sync(unsigned surface_id);
// Writable CPU alias of a client-memory (GPU read-only) IOSurface from the kernel (abi_minor 2); 0 when not available. alias_sync after the CPU writes.
int osm_sweet_surface_alias(unsigned surface_id, void **base, unsigned *bpr, unsigned *w, unsigned *h);
void osm_sweet_alias_sync(unsigned surface_id);
// Zero the texture bound to GL_TEXTURE_2D (storage allocated with glTexImage2D(NULL) is undefined; recycled GPU memory shows old pixels).
void osm_sweet_zero_texture(void);
// GPU sampling of client-memory IOSurfaces without a copy (read-only import). kind: 1 A8, 2 L8, 3 L8A8, 4 RGBA8, 5 BGRA8, 6 RGBA16F. 0 = copy instead.
int osm_sweet_wrap_texture(unsigned name, unsigned surface_id, int kind, unsigned w, unsigned h);
void osm_sweet_wrap_sync(unsigned surface_id);
void osm_sweet_stats(double *out, int n);   // cumulative ms per phase of the blit (debug), see OSMesaSweetStats in the Mesa patch
#endif
