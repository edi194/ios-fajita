// SPDX-License-Identifier: MIT
#ifndef MACRO_CTX_H
#define MACRO_CTX_H
struct macro_slot { const char *name; unsigned off; };
extern const struct macro_slot macro_slots[];
extern const int macro_nslots;
extern void *const ms_thunks[];                 // generated: per gl_names[] index, fn(rend, args...) forwarder
#define MACRO_CTX_SIZE 0x2200
void *macro_ctx_new(void *rend);                // EAGLMacroContext: rend at +0, entry points from +8 (CGL macro layout)
void macro_ctx_free(void *m);
#endif
