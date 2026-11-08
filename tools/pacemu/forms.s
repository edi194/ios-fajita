// Every instruction form the kernel PAC emulation (xnu patch 1019, osfmk/arm64/sweet_pacemu.h) decodes,
// plus near neighbours it must leave alone. Assembled with `clang -arch arm64e` by check.py; the comment
// after each line is the decoder's expected canonical output.
	retaa                          // RET
	retab                          // RET
	braa    x1, x2                 // BR n=1
	brab    x3, sp                 // BR n=3
	braaz   x4                     // BR n=4
	brabz   x30                    // BR n=30
	braa    x30, x0                // BR n=30
	blraa   x5, x6                 // BLR n=5
	blrab   x7, sp                 // BLR n=7
	blraaz  x30                    // BLR n=30
	blrabz  x0                     // BLR n=0
	blrab   x16, x17               // BLR n=16
	ldraa   x9, [x8, #32]!         // LDR t=9 n=8 imm=32 wb
	ldraa   x0, [x1]               // LDR t=0 n=1 imm=0
	ldrab   x2, [sp, #-4096]       // LDR t=2 n=31 imm=-4096
	ldraa   x3, [x4, #4088]!       // LDR t=3 n=4 imm=4088 wb
	ldrab   xzr, [x5, #-8]         // LDR t=31 n=5 imm=-8
	ldraa   x6, [sp, #16]!         // LDR t=6 n=31 imm=16 wb
	ldrab   x7, [x6, #-256]!       // LDR t=7 n=6 imm=-256 wb
	ldraa   x10, [x11, #2040]      // LDR t=10 n=11 imm=2040
	pacia   x0, x1                 // NOP PAC d=0
	pacib   x2, sp                 // NOP PAC d=2
	pacda   x3, x4                 // NOP PAC d=3
	pacdb   x5, x6                 // NOP PAC d=5
	paciza  x7                     // NOP PAC d=7
	pacizb  x8                     // NOP PAC d=8
	pacdza  x9                     // NOP PAC d=9
	pacdzb  x10                    // NOP PAC d=10
	autia   x11, x12               // NOP AUT d=11
	autib   x13, sp                // NOP AUT d=13
	autda   x14, x15               // NOP AUT d=14
	autdb   x16, x17               // NOP AUT d=16
	autiza  x18                    // NOP AUT d=18
	autizb  x19                    // NOP AUT d=19
	autdza  x20                    // NOP AUT d=20
	autdzb  x21                    // NOP AUT d=21
	xpaci   x22                    // NOP XPAC d=22
	xpacd   x23                    // NOP XPAC d=23
	xpaci   x30                    // NOP XPAC d=30
	pacga   x0, x1, x2             // PACGA d=0 n=1 m=2
	pacga   x3, x4, sp             // PACGA d=3 n=4 m=31
	pacga   x8, x8, x10            // PACGA d=8 n=8 m=10
	pacga   xzr, xzr, x5           // PACGA d=31 n=31 m=5
// left alone: hint space (NOP on this CPU), ordinary branches/loads, kernel-only and unrelated words
	ret                            // NONE
	ret     x1                     // NONE
	br      x1                     // NONE
	blr     x2                     // NONE
	ldr     x0, [x1, #8]!          // NONE
	ldr     x0, [x1]               // NONE
	ldur    x0, [x1, #-8]          // NONE
	ldr     x0, [x1, x2]           // NONE
	ldadd   x0, x1, [x2]           // NONE
	swp     x0, x1, [x2]           // NONE
	pacibsp                        // NONE
	autibsp                        // NONE
	paciasp                        // NONE
	pacia1716                      // NONE
	autib1716                      // NONE
	xpaclri                        // NONE
	bti     c                      // NONE
	nop                            // NONE
	eretaa                         // NONE
	eretab                         // NONE
	eor     x0, x1, x2, ror #13    // NONE
	fjcvtzs w0, d1                 // NONE
	rbit    x0, x1                 // NONE
	clz     x0, x1                 // NONE
	udiv    x0, x1, x2             // NONE
