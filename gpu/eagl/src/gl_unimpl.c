// SPDX-License-Identifier: MIT
// Landing pad for gl_tab slots Mesa could not fill. The stub in gl_stubs.c left the slot index in x17.
#include "gl_tab.h"
__attribute__((visibility("hidden"), naked, used)) void gl_unimpl(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x0, x17\n"
        "bl _gl_report_unimplemented\n"
        "ldp x29, x30, [sp], #16\n"
        "movi v0.2d, #0\n"
        "mov x0, #0\n"
        "ret\n");
}
