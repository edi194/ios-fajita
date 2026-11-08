/*
 * Enxerto entry: arm64 Linux Image header so Qualcomm ABL treats
 * us like a kernel. ABL enters at EL1, MMU/D-cache off, x0 = DTB pointer.
 */
	.section .text.head, "ax"
	.globl _head
_head:
	b	_start			/* code0 */
	.long	0			/* code1 */
	.quad	0			/* text_offset */
	.quad	_end			/* image_size (linked at 0) */
	.quad	0xa			/* flags: LE, 4K pages, place anywhere */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.quad	0			/* res4 */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* res5 (PE offset) */

	.text
	.globl _start
_start:
	msr	daifset, #0xf
	mov	x19, x0			/* DTB pointer from ABL */
	msr	spsel, #1
	adr	x1, _stack_top
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb
	/* zero .bss */
	adr	x1, _bss_start
	adr	x2, _bss_end
1:	cmp	x1, x2
	b.hs	2f
	str	xzr, [x1], #8
	b	1b
2:	mov	x0, x19
	bl	enxerto_main
3:	wfe
	b	3b

/* PSCI CPU_ON target. x0 = context id = cpu index (1..7). */
	.globl secondary_entry
secondary_entry:
	msr	daifset, #0xf
	msr	spsel, #1
	adr	x1, _sec_stacks
	add	x1, x1, x0, lsl #12
	add	x1, x1, #0x1000
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb
	bl	secondary_main
4:	wfe
	b	4b

/*
 * Exception vectors. Each slot stashes x29/x30, loads its slot number
 * and jumps to the common path, which saves x0-x28 and calls
 * exc_handler(slot, regs). IRQs return; everything else ends in the
 * on-screen panic.
 */
.macro vent slot
	.balign	0x80
	stp	x29, x30, [sp, #-16]!
	mov	x29, #\slot
	b	exc_common
.endm

	.balign	0x800
	.globl vectors
vectors:
	vent 0
	vent 1
	vent 2
	vent 3
	vent 4
	vent 5
	vent 6
	vent 7
	vent 8
	vent 9
	vent 10
	vent 11
	vent 12
	vent 13
	vent 14
	vent 15

exc_common:
	sub	sp, sp, #(30 * 8)
	stp	x0, x1, [sp, #0]
	stp	x2, x3, [sp, #16]
	stp	x4, x5, [sp, #32]
	stp	x6, x7, [sp, #48]
	stp	x8, x9, [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	str	x28, [sp, #224]
	mov	x0, x29
	mov	x1, sp
	bl	exc_handler
	ldp	x0, x1, [sp, #0]
	ldp	x2, x3, [sp, #16]
	ldp	x4, x5, [sp, #32]
	ldp	x6, x7, [sp, #48]
	ldp	x8, x9, [sp, #64]
	ldp	x10, x11, [sp, #80]
	ldp	x12, x13, [sp, #96]
	ldp	x14, x15, [sp, #112]
	ldp	x16, x17, [sp, #128]
	ldp	x18, x19, [sp, #144]
	ldp	x20, x21, [sp, #160]
	ldp	x22, x23, [sp, #176]
	ldp	x24, x25, [sp, #192]
	ldp	x26, x27, [sp, #208]
	ldr	x28, [sp, #224]
	add	sp, sp, #(30 * 8)
	ldp	x29, x30, [sp], #16
	eret

/*
 * mmu_off_jump(entry, arg, ranges[3] = {lo, hi} x 3): see mmu.h. The ranges
 * are loaded into registers first; after that nothing touches memory.
 */
	.macro	civac_range lo, hi
	bic	x15, \lo, x14
1:	cmp	x15, \hi
	b.hs	2f
	dc	civac, x15
	add	x15, x15, x13
	b	1b
2:
	.endm

	.globl mmu_off_jump
mmu_off_jump:
	msr	daifset, #0xf
	mov	x16, x0			/* entry */
	mov	x17, x1			/* arg */
	ldp	x3, x4, [x2, #0]
	ldp	x5, x6, [x2, #16]
	ldp	x7, x8, [x2, #32]
	mrs	x9, ctr_el0		/* DminLine: log2 words */
	ubfx	x9, x9, #16, #4
	mov	x13, #4
	lsl	x13, x13, x9		/* line bytes */
	sub	x14, x13, #1
	dsb	sy
	civac_range x3, x4
	civac_range x5, x6
	civac_range x7, x8
	dsb	sy
	mrs	x9, sctlr_el1
	mov	x10, #((1 << 0) | (1 << 2))	/* M, C */
	orr	x10, x10, #(1 << 12)		/* I */
	bic	x9, x9, x10
	msr	sctlr_el1, x9
	isb
	civac_range x3, x4
	civac_range x5, x6
	civac_range x7, x8
	dsb	sy
	tlbi	vmalle1
	ic	iallu
	dsb	sy
	isb
	mov	x0, x17
	br	x16

/*
 * mmu_off_ret(ranges[3] = {lo, hi} x 3): leave the cached window of mmu_enable_ranges and RETURN.
 * Clean+invalidate every range (the image too: the stack is in it) to the PoC, clear SCTLR.M and .C
 * (I stays on), invalidate the ranges again (lines refilled speculatively before the switch) and the
 * TLBs. The ranges are loaded into registers first; between the first clean and the SCTLR write nothing
 * touches memory, and the function only uses caller-saved registers, so the caller's stack (cleaned
 * with the rest of the image) is read back from memory with the MMU off.
 */
	.globl mmu_off_ret
mmu_off_ret:
	msr	daifset, #0xf
	ldp	x3, x4, [x0, #0]
	ldp	x5, x6, [x0, #16]
	ldp	x7, x8, [x0, #32]
	mrs	x9, ctr_el0		/* DminLine: log2 words */
	ubfx	x9, x9, #16, #4
	mov	x13, #4
	lsl	x13, x13, x9		/* line bytes */
	sub	x14, x13, #1
	dsb	sy
	civac_range x3, x4
	civac_range x5, x6
	civac_range x7, x8
	dsb	sy
	mrs	x9, sctlr_el1
	mov	x10, #((1 << 0) | (1 << 2))	/* M, C */
	bic	x9, x9, x10
	msr	sctlr_el1, x9
	isb
	civac_range x3, x4
	civac_range x5, x6
	civac_range x7, x8
	dsb	sy
	tlbi	vmalle1
	dsb	sy
	isb
	ret
