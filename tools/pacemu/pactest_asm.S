// PAC instruction sequences for pactest (tools/pacemu/pactest.c). Every sequence is valid arm64e code
// (pointers are signed before they are authenticated), so it passes on a CPU with PAuth too; on the
// Poco F1 each non-HINT instruction traps into the kernel emulation (xnu patch 1019).
	.text
	.p2align 2

// uint64_t t_retab(void): non-leaf style frame, return through RETAB
	.globl _t_retab
_t_retab:
	pacibsp
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	mov	x0, #42
	ldp	x29, x30, [sp], #16
	retab

// uint64_t t_retaa(void)
	.globl _t_retaa
_t_retaa:
	paciasp
	mov	x0, #43
	retaa

// uint64_t t_braa(void): BRAA x16, x17 to a local label; 7 if the branch was taken
	.globl _t_braa
_t_braa:
	adr	x16, 1f
	mov	x17, #0x1234
	pacia	x16, x17
	braa	x16, x17
	mov	x0, #0
	ret
1:	mov	x0, #7
	ret

// uint64_t t_brab_sp(void): BRAB with SP as the modifier
	.globl _t_brab_sp
_t_brab_sp:
	adr	x16, 1f
	pacib	x16, sp
	brab	x16, sp
	mov	x0, #0
	ret
1:	mov	x0, #8
	ret

// uint64_t t_braaz(void) / t_brabz(void)
	.globl _t_braaz
_t_braaz:
	adr	x16, 1f
	paciza	x16
	braaz	x16
	mov	x0, #0
	ret
1:	mov	x0, #10
	ret

	.globl _t_brabz
_t_brabz:
	adr	x3, 1f
	pacizb	x3
	brabz	x3
	mov	x0, #0
	ret
1:	mov	x0, #11
	ret

// int64_t t_blraa(void): BLRAA; the callee returns LR, the result is LR - (address after the BLRAA): 0
	.globl _t_blraa
_t_blraa:
	pacibsp
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	adr	x16, 9f
	mov	x17, #0x55
	pacia	x16, x17
	adr	x1, 2f
	blraa	x16, x17
2:	sub	x0, x0, x1
	ldp	x29, x30, [sp], #16
	retab
9:	mov	x0, x30
	ret

// int64_t t_blrab_sp(void): BLRAB with SP as the modifier, same check
	.globl _t_blrab_sp
_t_blrab_sp:
	pacibsp
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	adr	x9, 9f
	pacib	x9, sp
	adr	x1, 2f
	blrab	x9, sp
2:	sub	x0, x0, x1
	ldp	x29, x30, [sp], #16
	retab
9:	mov	x0, x30
	ret

// int64_t t_blraaz_lr(void): BLRAAZ X30 must branch to the OLD X30 and then set LR
	.globl _t_blraaz_lr
_t_blraaz_lr:
	pacibsp
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	adr	x30, 9f
	paciza	x30
	adr	x1, 2f
	blraaz	x30
2:	sub	x0, x0, x1
	ldp	x29, x30, [sp], #16
	retab
9:	mov	x0, x30
	ret

// int64_t t_blrabz(void)
	.globl _t_blrabz
_t_blrabz:
	pacibsp
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	adr	x0, 9f
	pacizb	x0
	adr	x1, 2f
	blrabz	x0
2:	sub	x0, x0, x1
	ldp	x29, x30, [sp], #16
	retab
9:	mov	x0, x30
	ret

// LDRAA/LDRAB. out[0] = loaded value, out[1] = base register after the instruction.
// void t_ldraa_pre(const uint64_t *p, uint64_t out[2]): ldraa x9, [x8, #16]!
	.globl _t_ldraa_pre
_t_ldraa_pre:
	mov	x8, x0
	pacdza	x8
	ldraa	x9, [x8, #16]!
	stp	x9, x8, [x1]
	ret

// void t_ldraa_off(const uint64_t *p, uint64_t out[2]): ldraa x9, [x8, #8]
	.globl _t_ldraa_off
_t_ldraa_off:
	mov	x8, x0
	pacdza	x8
	ldraa	x9, [x8, #8]
	stp	x9, x8, [x1]
	ret

// void t_ldrab_neg(const uint64_t *p, uint64_t out[2]): ldrab x9, [x8, #-16], p points at element 4
	.globl _t_ldrab_neg
_t_ldrab_neg:
	mov	x8, x0
	pacdzb	x8
	ldrab	x9, [x8, #-16]
	stp	x9, x8, [x1]
	ret

// void t_ldraa_far(const uint64_t *p, uint64_t out[2]): ldraa x9, [x8, #512]! (no LDR pre-index form:
// pacstrip leaves it, only the kernel handles it)
	.globl _t_ldraa_far
_t_ldraa_far:
	mov	x8, x0
	pacdza	x8
	ldraa	x9, [x8, #512]!
	stp	x9, x8, [x1]
	ret

// void t_ldrab_sp(uint64_t out[2]): ldrab x9, [sp, #8]! on a known stack slot; out[1] = sp delta
	.globl _t_ldrab_sp
_t_ldrab_sp:
	sub	sp, sp, #32
	mov	x10, #0x5a5a
	movk	x10, #0x1f2e, lsl #16
	str	x10, [sp, #8]
	mov	x11, sp
	ldrab	x9, [sp, #8]!
	mov	x12, sp
	sub	x12, x12, x11
	mov	sp, x11
	add	sp, sp, #32
	stp	x9, x12, [x0]
	ret

// uint64_t t_ldraa_load(const uint64_t *p): ldraa x0, [x8]; used with a bad pointer (SIGSEGV expected)
	.globl _t_ldraa_load
_t_ldraa_load:
	mov	x8, x0
	pacdza	x8
	ldraa	x0, [x8]
	ret

// PAC/AUT/XPAC: uint64_t t_pac_xx(uint64_t ptr, uint64_t mod) returns the signed pointer,
// t_roundtrip_xx returns sign + authenticate (= ptr on any CPU).
	.macro PACFN name, pac, aut
	.globl _t_pac_\name
_t_pac_\name:
	\pac	x0, x1
	ret
	.globl _t_roundtrip_\name
_t_roundtrip_\name:
	\pac	x0, x1
	\aut	x0, x1
	ret
	.endm
	.macro PACZFN name, pac, aut
	.globl _t_pac_\name
_t_pac_\name:
	\pac	x0
	ret
	.globl _t_roundtrip_\name
_t_roundtrip_\name:
	\pac	x0
	\aut	x0
	ret
	.endm
	PACFN	ia, pacia, autia
	PACFN	ib, pacib, autib
	PACFN	da, pacda, autda
	PACFN	db, pacdb, autdb
	PACZFN	iza, paciza, autiza
	PACZFN	izb, pacizb, autizb
	PACZFN	dza, pacdza, autdza
	PACZFN	dzb, pacdzb, autdzb

// uint64_t t_xpaci(uint64_t ptr): sign with IA then strip
	.globl _t_xpaci
_t_xpaci:
	paciza	x0
	xpaci	x0
	ret
	.globl _t_xpacd
_t_xpacd:
	pacdza	x0
	xpacd	x0
	ret

// PACGA. uint64_t t_pacga_a(n, m): pacga x0, x0, x1; t_pacga_b(n, m): the same inputs in other registers
	.globl _t_pacga_a
_t_pacga_a:
	pacga	x0, x0, x1
	ret
	.globl _t_pacga_b
_t_pacga_b:
	mov	x13, x0
	mov	x21, x1
	pacga	x7, x13, x21
	mov	x0, x7
	ret
// void t_pacga_sp(uint64_t n, uint64_t out[2]): out[0] = pacga x0, n, sp; out[1] = sp
	.globl _t_pacga_sp
_t_pacga_sp:
	pacga	x2, x0, sp
	mov	x3, sp
	stp	x2, x3, [x1]
	ret

// Timing loops, void t_loop_xx(uint64_t n): n iterations of one instruction (+ the loop's subs/b.ne).
// t_loop_nop is the native baseline, t_loop_svc a getppid() system call (the floor of any trap).
	.globl _t_loop_nop
_t_loop_nop:
1:	nop
	subs	x0, x0, #1
	b.ne	1b
	ret
	.globl _t_loop_svc
_t_loop_svc:
	mov	x9, x0
1:	mov	x16, #39			// SYS_getppid
	svc	#0x80
	subs	x9, x9, #1
	b.ne	1b
	ret
	.globl _t_loop_pacia
_t_loop_pacia:
	mov	x1, #0x1000
1:	pacia	x1, x2
	subs	x0, x0, #1
	b.ne	1b
	ret
	.globl _t_loop_braa
_t_loop_braa:
	adr	x16, 2f
	mov	x17, #7
	pacia	x16, x17
1:	braa	x16, x17
2:	subs	x0, x0, #1
	b.ne	1b
	ret
	.globl _t_loop_blraa
_t_loop_blraa:
	pacibsp
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	adr	x16, 9f
	mov	x17, #7
	pacia	x16, x17
1:	blraa	x16, x17
	subs	x0, x0, #1
	b.ne	1b
	ldp	x29, x30, [sp], #16
	retab
9:	ret
	.globl _t_loop_retab
_t_loop_retab:
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
1:	bl	2f
	subs	x0, x0, #1
	b.ne	1b
	ldp	x29, x30, [sp], #16
	ret
2:	pacibsp
	retab
	.globl _t_loop_ldraa
_t_loop_ldraa:
	sub	sp, sp, #16
	mov	x8, sp
	pacdza	x8
1:	ldraa	x9, [x8]
	subs	x0, x0, #1
	b.ne	1b
	add	sp, sp, #16
	ret
	.globl _t_loop_pacga
_t_loop_pacga:
	mov	x1, #5
1:	pacga	x2, x1, x0
	subs	x0, x0, #1
	b.ne	1b
	ret

// uint32_t t_fjcvtzs(double): kernel patch 0141
	.globl _t_fjcvtzs
_t_fjcvtzs:
	fjcvtzs	w0, d0
	ret
