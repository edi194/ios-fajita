// SPDX-License-Identifier: MIT
#ifndef GL_TAB_H
#define GL_TAB_H
extern void *gl_tab[];
extern const char *const gl_names[];
extern const int gl_nfuncs;
void gl_resolve_all(void);          // fill gl_tab from the Mesa glapi dispatcher (idempotent)
void gl_report_unimplemented(int idx);
#endif
