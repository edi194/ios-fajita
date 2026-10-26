/*
 * sweet-gputest: the first userspace client of /dev/sweetgpu.
 *
 * Runs as a LaunchDaemon on the real root (the GPU bring-up is called from the UFS
 * attach path, so a RAM-disk root has no GPU at all). It walks the ABI a driver would:
 * INFO, GEM_NEW twice, GET_IOVA, SELECT, write the command buffer, GEM_SUBMIT,
 * WAIT_FENCE, SELECT the target, read it back and compare.
 *
 * Static, position independent, no relocations and no writable data, because
 * tools/mkinit.py lays this object's text straight into a Mach-O. Strings are .ascii
 * in __text and reached with adr; the ioctl structs and the packet buffer live on the
 * stack. Raw XNU syscalls: number in x16, svc #0x80, carry set on error.
 *
 * The command words are _IOWR('G', n, struct) = 0xc0000000 | (sizeof << 16) | 0x4700 | n,
 * the same values the kernel builds in patch 0155.
 */
#define SYS_exit	1
#define SYS_read	3
#define SYS_write	4
#define SYS_open	5
#define SYS_ioctl	54
#define SYS_execve	59

#define IOC_INFO	0xc0184770
#define IOC_GEM_NEW	0xc0104742
#define IOC_GEM_INFO	0xc0104743
#define IOC_SELECT	0xc0084744
#define IOC_SUBMIT	0xc0104746
#define IOC_WAIT	0xc0104747

#define INFO_GET_IOVA	1

/* stack layout inside the 512-byte frame */
#define O_INFO		0
#define O_NEWCMD	32
#define O_NEWDST	48
#define O_GEMINFO	64
#define O_SELECT	80
#define O_SUBMIT	96
#define O_WAIT		112
#define O_PKTS		160
#define O_BACK		224

	.text
/* 32-bit immediate into a register without a literal pool */
.macro MOVW reg, val
	movz	\reg, #(\val & 0xffff)
	movk	\reg, #((\val >> 16) & 0xffff), lsl #16
.endm
	.globl	_start
	.p2align 2
_start:
	/*
	 * Do not trust the sp the kernel hands a static binary spawned by launchd:
	 * the crash report of the first attempt (2026-10-25) showed sp outside the
	 * mapped stack (0x16fdffb58 vs a stack ending at 0x16f604000), so the first
	 * ldr [sp] was a SIGBUS. mmap one page pair and switch to it first.
	 */
	mov	x0, #0			/* addr: let the kernel pick */
	mov	x1, #0x4000		/* 16 KiB */
	mov	x2, #3			/* PROT_READ | PROT_WRITE */
	mov	x3, #0x1002		/* MAP_PRIVATE | MAP_ANON */
	mov	x4, #-1
	mov	x5, #0
	mov	x16, #197		/* SYS_mmap */
	svc	#0x80
	b.cc	1f
	mov	x0, sp			/* mmap refused: keep what we were given */
	b	2f
1:
	add	x0, x0, #0x3000	/* top of our page, leaving room below */
2:
	mov	sp, x0

	/* console */
	adr	x0, s_console
	mov	x1, #1			/* O_WRONLY */
	mov	x2, #0
	mov	x16, #SYS_open
	svc	#0x80
	b.cc	1f
	mov	x19, #1
	b	2f
1:
	mov	x19, x0
2:
	/* /dev/sweetgpu */
	adr	x0, s_dev
	mov	x1, #2			/* O_RDWR */
	mov	x2, #0
	mov	x16, #SYS_open
	svc	#0x80
	b.cc	3f
	adr	x1, m_nodev
	bl	puts
	b	stop
3:
	mov	x20, x0

	/* INFO */
	mov	x0, x20
	MOVW	x1, IOC_INFO
	add	x2, sp, #O_INFO
	bl	ioctl
	cbnz	x0, fail
	ldr	w9, [sp, #O_INFO]	/* abi_version */
	cmp	w9, #1
	b.eq	4f
	adr	x1, m_abi
	bl	puts
	b	stop
4:
	/* GEM_NEW command buffer, 0x2000 */
	mov	w9, #0x2000
	str	w9, [sp, #O_NEWCMD]
	str	wzr, [sp, #O_NEWCMD + 4]
	mov	x0, x20
	MOVW	x1, IOC_GEM_NEW
	add	x2, sp, #O_NEWCMD
	bl	ioctl
	cbnz	x0, fail
	ldr	w21, [sp, #O_NEWCMD + 8]	/* cmd handle */

	/* GEM_NEW target, 0x1000 */
	mov	w9, #0x1000
	str	w9, [sp, #O_NEWDST]
	str	wzr, [sp, #O_NEWDST + 4]
	mov	x0, x20
	MOVW	x1, IOC_GEM_NEW
	add	x2, sp, #O_NEWDST
	bl	ioctl
	cbnz	x0, fail
	ldr	w22, [sp, #O_NEWDST + 8]	/* dst handle */

	/* GEM_INFO(GET_IOVA) on the target */
	str	w22, [sp, #O_GEMINFO]
	mov	w9, #INFO_GET_IOVA
	str	w9, [sp, #O_GEMINFO + 4]
	mov	x0, x20
	MOVW	x1, IOC_GEM_INFO
	add	x2, sp, #O_GEMINFO
	bl	ioctl
	cbnz	x0, fail
	ldr	w23, [sp, #O_GEMINFO + 8]	/* dst iova */

	/* SELECT the command buffer */
	str	w21, [sp, #O_SELECT]
	str	wzr, [sp, #O_SELECT + 4]
	mov	x0, x20
	MOVW	x1, IOC_SELECT
	add	x2, sp, #O_SELECT
	bl	ioctl
	cbnz	x0, fail

	/* packets: NOP, MEM_WRITE(dst+0x10, 0xcafe0001), MEM_WRITE(dst+0x20, 0xcafe0002) */
	add	x9, sp, #O_PKTS
	movz	w10, #0x0001
	movk	w10, #0x7010, lsl #16		/* pkt7(CP_NOP, 1) = 0x70100001 */
	str	w10, [x9, #0]
	str	wzr, [x9, #4]
	movz	w10, #0x8003
	movk	w10, #0x703d, lsl #16		/* pkt7(CP_MEM_WRITE=61, 3) = 0x703d8003 */
	add	w11, w23, #0x10
	str	w10, [x9, #8]
	str	w11, [x9, #12]
	str	wzr, [x9, #16]
	mov	w12, #0x0001
	movk	w12, #0xcafe, lsl #16
	str	w12, [x9, #20]
	add	w11, w23, #0x20
	str	w10, [x9, #24]
	str	w11, [x9, #28]
	str	wzr, [x9, #32]
	mov	w12, #0x0002
	movk	w12, #0xcafe, lsl #16
	str	w12, [x9, #36]

	/* write 40 bytes into the selected buffer */
	mov	x0, x20
	add	x1, sp, #O_PKTS
	mov	x2, #40
	mov	x16, #SYS_write
	svc	#0x80
	b.cc	5f
	adr	x1, m_write
	bl	puts
	b	stop
5:
	/* GEM_SUBMIT(cmd handle, offset 0, 10 dwords) */
	str	w21, [sp, #O_SUBMIT]
	str	wzr, [sp, #O_SUBMIT + 4]
	mov	w9, #10
	str	w9, [sp, #O_SUBMIT + 8]
	mov	x0, x20
	MOVW	x1, IOC_SUBMIT
	add	x2, sp, #O_SUBMIT
	bl	ioctl
	cbnz	x0, fail
	ldr	w24, [sp, #O_SUBMIT + 12]	/* fence */

	/* WAIT_FENCE(fence, 2000 ms) */
	str	w24, [sp, #O_WAIT]
	mov	w9, #2000
	str	w9, [sp, #O_WAIT + 4]
	mov	x0, x20
	MOVW	x1, IOC_WAIT
	add	x2, sp, #O_WAIT
	bl	ioctl
	cbnz	x0, fail

	/* SELECT the target and read it back */
	str	w22, [sp, #O_SELECT]
	mov	x0, x20
	MOVW	x1, IOC_SELECT
	add	x2, sp, #O_SELECT
	bl	ioctl
	cbnz	x0, fail

	mov	x0, x20
	add	x1, sp, #O_BACK
	mov	x2, #48
	mov	x16, #SYS_read
	svc	#0x80
	b.cc	6f
	adr	x1, m_read
	bl	puts
	b	stop
6:
	ldr	w25, [sp, #O_BACK + 16]	/* offset 0x10 */
	ldr	w26, [sp, #O_BACK + 32]	/* offset 0x20 */
	mov	w27, #0x0001
	movk	w27, #0xcafe, lsl #16
	mov	w28, #0x0002
	movk	w28, #0xcafe, lsl #16
	cmp	w25, w27
	b.ne	fail
	cmp	w26, w28
	b.ne	fail

	adr	x1, m_pass
	bl	puts
	b	stop

fail:
	adr	x1, m_fail
	bl	puts
stop:
	/*
	 * Hand over to the IOKit client. This tool runs as a stock daemon binary, which is the
	 * only way we have to get userspace code running at boot, so the IOKit test rides behind
	 * it instead of replacing another system binary.
	 */
	adr	x0, s_iokit
	add	x1, sp, #0x400
	str	x0, [x1]
	str	xzr, [x1, #8]
	mov	x2, #0
	mov	x16, #SYS_execve
	svc	#0x80
	/* execve failed: exit quietly */
	mov	x0, #0
	mov	x16, #SYS_exit
	svc	#0x80
	b	stop

/* ioctl(fd=x0, cmd=x1, arg=x2) -> x0 = 0 or -1 */
ioctl:
	mov	x16, #SYS_ioctl
	svc	#0x80
	b.cc	1f
	mov	x0, #-1
1:
	ret

/* puts(x1 = string) on the console */
puts:
	mov	x2, #0
1:
	ldrb	w3, [x1, x2]
	cbz	w3, 2f
	add	x2, x2, #1
	b	1b
2:
	mov	x0, x19
	mov	x16, #SYS_write
	svc	#0x80
	ret

	.p2align 2
s_console:
	.asciz	"/dev/console"
s_dev:
	.asciz	"/dev/sweetgpu"
s_iokit:
	.asciz	"/usr/local/bin/sweet-iokit-test"
m_nodev:
	.asciz	"GPU TEST: /dev/sweetgpu is not there\n"
m_abi:
	.asciz	"GPU TEST: unexpected ABI version\n"
m_write:
	.asciz	"GPU TEST: writing the command buffer failed\n"
m_read:
	.asciz	"GPU TEST: reading the result failed\n"
m_pass:
	.asciz	"GPU TEST: PASS - userspace submitted through /dev/sweetgpu and read the result back\n"
m_fail:
	.asciz	"GPU TEST: FAIL\n"
