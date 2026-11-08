// SPDX-License-Identifier: MIT
// Fills gl_tab: every exported gl* entry point forwards to the Mesa glapi dispatcher, which routes to the
// context made current by OSMesaMakeCurrent on this thread. Names Mesa lacks get a vendor-suffix-stripped alias
// or a no-op / "unimplemented" handler that logs once.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "osm.h"
#include "gl_tab.h"

static void gl_noop(void) {}

// Debug/marker/label entry points: harmless to ignore.
static const char *const noop_names[] = {
    "glInsertEventMarkerEXT", "glPushGroupMarkerEXT", "glPopGroupMarkerEXT", "glLabelObjectEXT",
    "glDiscardFramebufferEXT", "glCopyTextureLevelsAPPLE", "glGetObjectLabelEXT", 0 };

static const char *const suffixes[] = { "OES", "EXT", "APPLE", "ANGLE", "KHR", "IMG", "ARB", 0 };

// Called (through gl_unimpl in gl_unimpl.S) when a client calls an exported entry point Mesa could not provide.
static unsigned char reported[1024];
void gl_report_unimplemented(int idx) {
    if (idx >= 0 && idx < gl_nfuncs && !reported[idx]) {
        reported[idx] = 1;
        fprintf(stderr, "OpenGLES(shim): %s is not implemented\n", gl_names[idx]);
    }
}

extern void gl_unimpl(void);

static void *lookup(const char *n) {
    void *p = osm_getproc(n);
    return p;
}

void gl_resolve_all(void) {
    static int done;
    if (done) return;
    done = 1;
    for (int i = 0; i < gl_nfuncs; i++) {
        const char *n = gl_names[i];
        void *p = 0;
        for (int k = 0; noop_names[k]; k++)
            if (!strcmp(n, noop_names[k])) p = (void *)gl_noop;
        if (!p) p = lookup(n);
        if (!p) {
            size_t l = strlen(n);
            for (int k = 0; suffixes[k] && !p; k++) {
                size_t sl = strlen(suffixes[k]);
                if (l > sl + 2 && !strcmp(n + l - sl, suffixes[k])) {
                    char buf[128];
                    memcpy(buf, n, l - sl); buf[l - sl] = 0;
                    p = lookup(buf);
                }
            }
        }
        if (!p) {                       // glVertexAttrib4f -> glVertexAttrib4fARB and similar
            char buf[128];
            snprintf(buf, sizeof buf, "%sARB", n);
            p = lookup(buf);
            if (!p) { snprintf(buf, sizeof buf, "%sEXT", n); p = lookup(buf); }   // glVertexAttribI4i -> ...EXT
        }
        gl_tab[i] = p ? p : (void *)gl_unimpl;
    }
}

__attribute__((constructor)) static void gl_resolve_ctor(void) { gl_resolve_all(); }
