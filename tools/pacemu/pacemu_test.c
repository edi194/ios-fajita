/*
 * Host test of the kernel PAC emulation (xnu/patches-12377/1019-sweet-pac-emulation.patch,
 * osfmk/arm64/sweet_pacemu.h). Run through check.py, which extracts the header from the
 * patch, assembles forms.s and cross-checks against llvm-objdump and pacstrip.py.
 *
 *   pacemu_test unit             built-in semantic tests
 *   pacemu_test decode < words   one hex word per line -> "WORD canonical"
 *   pacemu_test exec < words     one hex word per line -> "WORD result" on the fixed state below
 *   pacemu_test bench            ns per decode+execute, with the kernel's snapshot/compare/write-back
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sweet_pacemu.h"

static void
canonical(uint32_t w, char *buf, size_t n)
{
	struct sweet_pac_insn in;
	static const char *const nop_cls[] = {
		[SWEET_PACC_PAC] = "PAC", [SWEET_PACC_AUT] = "AUT", [SWEET_PACC_XPAC] = "XPAC",
	};

	if (!sweet_pac_decode(w, &in)) {
		snprintf(buf, n, "NONE");
		return;
	}
	switch (in.op) {
	case SWEET_PAC_RET:   snprintf(buf, n, "RET"); break;
	case SWEET_PAC_BR:    snprintf(buf, n, "BR n=%u", in.rn); break;
	case SWEET_PAC_BLR:   snprintf(buf, n, "BLR n=%u", in.rn); break;
	case SWEET_PAC_NOP:   snprintf(buf, n, "NOP %s d=%u", nop_cls[in.cls], in.rd); break;
	case SWEET_PAC_PACGA: snprintf(buf, n, "PACGA d=%u n=%u m=%u", in.rd, in.rn, in.rm); break;
	case SWEET_PAC_LDR:
		snprintf(buf, n, "LDR t=%u n=%u imm=%d%s", in.rd, in.rn, in.imm, in.writeback ? " wb" : "");
		break;
	default:              snprintf(buf, n, "?"); break;
	}
}

/* ---- the fixed machine state shared with check.py ---- */
static void
init_state(struct sweet_pac_cpu *c)
{
	for (unsigned i = 0; i < 31; i++) {
		c->x[i] = 0x0000000100000000ULL + 0x10000ULL * i + 0x40ULL;
	}
	c->sp = 0x000000016fdff000ULL;
	c->pc = 0x0000000100004000ULL;
	c->written = 0;
}

static uint64_t
mem_value(uint64_t addr)
{
	return addr * 0x9E3779B97F4A7C15ULL ^ 0x5555AAAA5555AAAAULL;
}

struct mem {
	uint64_t fault_lo, fault_hi;    /* reads in [lo, hi) fail */
	unsigned loads;
	uint64_t last_addr;
};

static int
load64(void *ctx, uint64_t addr, uint64_t *v)
{
	struct mem *m = ctx;
	m->loads++;
	m->last_addr = addr;
	if (addr >= m->fault_lo && addr < m->fault_hi) {
		return 14;      /* EFAULT */
	}
	*v = mem_value(addr);
	return 0;
}

/* ---- encoders (Arm ARM) ---- */
#define RETAB           0xD65F0FFFu
#define RETAA           0xD65F0BFFu
static uint32_t braa(unsigned n, unsigned m, int b)  { return 0xD71F0800u | (unsigned)b << 10 | n << 5 | m; }
static uint32_t braaz(unsigned n, int b)             { return 0xD61F081Fu | (unsigned)b << 10 | n << 5; }
static uint32_t blraa(unsigned n, unsigned m, int b) { return 0xD73F0800u | (unsigned)b << 10 | n << 5 | m; }
static uint32_t blraaz(unsigned n, int b)            { return 0xD63F081Fu | (unsigned)b << 10 | n << 5; }
static uint32_t pacga(unsigned d, unsigned n, unsigned m) { return 0x9AC03000u | m << 16 | n << 5 | d; }
static uint32_t pac(unsigned opc, int z, unsigned n, unsigned d) { return 0xDAC10000u | (unsigned)z << 13 | opc << 10 | n << 5 | d; }
static uint32_t
ldraa(unsigned t, unsigned n, int off, int wb, int b)
{
	uint32_t s10 = (uint32_t)(off / 8) & 0x3FF;
	return 0xF8200400u | (unsigned)b << 23 | (s10 >> 9) << 22 | (s10 & 0x1FF) << 12 | (unsigned)wb << 11 | n << 5 | t;
}

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); \
	                                     printf(__VA_ARGS__); printf("\n"); } } while (0)

static enum sweet_pac_result
run(uint32_t w, struct sweet_pac_cpu *c, struct mem *m, uint64_t *fa)
{
	return sweet_pac_execute(w, c, load64, m, fa);
}

static int
unit(void)
{
	struct sweet_pac_cpu c, o;
	struct mem m = { 0 };
	uint64_t fa = 0;

	/* RETAA/RETAB: PC = LR, nothing else */
	init_state(&c); o = c;
	CHECK(run(RETAB, &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.x[30], "retab");
	c.pc = o.pc; CHECK(memcmp(&c, &o, sizeof(c)) == 0, "retab changed registers");
	init_state(&c);
	CHECK(run(RETAA, &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.x[30], "retaa");

	/* BRAA/BRABZ: PC = Xn, the modifier is ignored, LR untouched */
	init_state(&c);
	CHECK(run(braa(3, 31, 1), &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.x[3] && c.x[30] == o.x[30], "brab x3, sp");
	init_state(&c);
	CHECK(run(braaz(30, 1), &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.x[30], "brabz x30");
	init_state(&c);
	CHECK(run(braa(31, 2, 0), &c, &m, &fa) == SWEET_PAC_DONE && c.pc == 0, "braa xzr: target 0");

	/* BLRAA: LR = PC + 4; BLRAAZ X30 branches to the OLD LR */
	init_state(&c);
	CHECK(run(blraa(16, 17, 1), &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.x[16] && c.x[30] == o.pc + 4 &&
	    c.x[16] == o.x[16] && c.x[17] == o.x[17], "blrab x16, x17");
	init_state(&c);
	CHECK(run(blraaz(30, 0), &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.x[30] && c.x[30] == o.pc + 4,
	    "blraaz x30: pc=%" PRIx64 " lr=%" PRIx64, c.pc, c.x[30]);

	/* Z forms with a non-zero Rm/Rn field are unallocated */
	CHECK(run(braaz(4, 0) & ~31u, &c, &m, &fa) == SWEET_PAC_UNHANDLED, "braaz with rm=0");
	CHECK(run(pac(0, 1, 3, 7), &c, &m, &fa) == SWEET_PAC_UNHANDLED, "paciza with rn=3");

	/* PAC/AUT/XPAC: NOP, the pointer stays plain */
	for (unsigned opc = 0; opc < 8; opc++) {
		for (int z = 0; z < 2; z++) {
			init_state(&c);
			CHECK(run(pac(opc, z, z ? 31 : 5, 7), &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.pc + 4,
			    "pac/aut opc %u z %d", opc, z);
			c.pc = o.pc; CHECK(memcmp(&c, &o, sizeof(c)) == 0, "pac/aut opc %u z %d changed registers", opc, z);
		}
	}
	init_state(&c);
	CHECK(run(0xDAC143E0u | 9, &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.pc + 4 && c.x[9] == o.x[9], "xpaci");

	/* PACGA: pacstrip's EOR Xd, Xn, Xm, ROR #13; independent of the register numbers; SP -> MOV */
	{
		const uint64_t a = 0x00007fff12345678ULL, b = 0x0000000102030405ULL;
		const uint64_t want = a ^ (b >> 13 | b << 51);
		init_state(&c); c.x[1] = a; c.x[2] = b;
		CHECK(run(pacga(0, 1, 2), &c, &m, &fa) == SWEET_PAC_DONE && c.x[0] == want && c.pc == o.pc + 4, "pacga x0,x1,x2");
		init_state(&c); c.x[20] = a; c.x[4] = b;
		CHECK(run(pacga(9, 20, 4), &c, &m, &fa) == SWEET_PAC_DONE && c.x[9] == want, "pacga x9,x20,x4 (same value)");
		init_state(&c); c.x[8] = a; c.x[10] = b;
		CHECK(run(pacga(8, 8, 10), &c, &m, &fa) == SWEET_PAC_DONE && c.x[8] == want, "pacga x8,x8,x10 (chained)");
		init_state(&c); c.x[4] = a;
		CHECK(run(pacga(3, 4, 31), &c, &m, &fa) == SWEET_PAC_DONE && c.x[3] == a, "pacga x3,x4,sp");
		init_state(&c); o = c;
		CHECK(run(pacga(31, 1, 2), &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.pc + 4, "pacga xzr");
		c.pc = o.pc; CHECK(memcmp(&c, &o, sizeof(c)) == 0, "pacga xzr wrote a register");
		init_state(&c); c.x[5] = b;
		CHECK(run(pacga(0, 31, 5), &c, &m, &fa) == SWEET_PAC_DONE && c.x[0] == (b >> 13 | b << 51), "pacga x0,xzr,x5");
	}

	/* LDRAA/LDRAB: plain and pre-index, SP base, XZR target, Rt == Rn */
	init_state(&c); o = c;
	CHECK(run(ldraa(9, 8, 32, 1, 0), &c, &m, &fa) == SWEET_PAC_DONE && c.x[8] == o.x[8] + 32 &&
	    c.x[9] == mem_value(o.x[8] + 32) && c.pc == o.pc + 4, "ldraa x9, [x8, #32]!");
	init_state(&c);
	CHECK(run(ldraa(2, 31, -4096, 0, 1), &c, &m, &fa) == SWEET_PAC_DONE && c.sp == o.sp &&
	    c.x[2] == mem_value(o.sp - 4096), "ldrab x2, [sp, #-4096]");
	init_state(&c);
	CHECK(run(ldraa(6, 31, 16, 1, 0), &c, &m, &fa) == SWEET_PAC_DONE && c.sp == o.sp + 16 &&
	    c.x[6] == mem_value(o.sp + 16), "ldraa x6, [sp, #16]!");
	init_state(&c);
	CHECK(run(ldraa(7, 7, -256, 1, 1), &c, &m, &fa) == SWEET_PAC_DONE && c.x[7] == mem_value(o.x[7] - 256),
	    "ldrab x7, [x7, #-256]! (loaded value wins)");
	init_state(&c);
	CHECK(run(ldraa(31, 5, -8, 0, 1), &c, &m, &fa) == SWEET_PAC_DONE && c.pc == o.pc + 4, "ldrab xzr");
	c.pc = o.pc; CHECK(memcmp(&c, &o, sizeof(c)) == 0, "ldrab xzr wrote a register");
	init_state(&c);
	CHECK(run(ldraa(3, 4, 4088, 1, 0), &c, &m, &fa) == SWEET_PAC_DONE && c.x[4] == o.x[4] + 4088, "ldraa +4088!");

	/* cpu->written: exactly the registers the instruction wrote (bit 31 = SP) */
	{
		init_state(&c);
		run(ldraa(9, 8, 16, 1, 0), &c, &m, &fa);
		CHECK(c.written == (1u << 9 | 1u << 8), "written ldraa wb: %#x", c.written);
		init_state(&c);
		run(ldraa(6, 31, 16, 1, 0), &c, &m, &fa);
		CHECK(c.written == (1u << 6 | 1u << 31), "written ldraa sp wb: %#x", c.written);
		init_state(&c);
		run(ldraa(31, 5, -8, 0, 1), &c, &m, &fa);
		CHECK(c.written == 0, "written ldrab xzr: %#x", c.written);
		init_state(&c);
		run(blraaz(30, 0), &c, &m, &fa);
		CHECK(c.written == 1u << 30, "written blraaz: %#x", c.written);
		init_state(&c);
		run(pacga(31, 1, 2), &c, &m, &fa);
		CHECK(c.written == 0, "written pacga xzr: %#x", c.written);
		init_state(&c);
		run(pacga(3, 4, 31), &c, &m, &fa);
		CHECK(c.written == 1u << 3, "written pacga x3: %#x", c.written);
		init_state(&c);
		run(pac(0, 0, 1, 0), &c, &m, &fa);
		CHECK(c.written == 0, "written pacia: %#x", c.written);
		init_state(&c);
		run(RETAB, &c, &m, &fa);
		CHECK(c.written == 0, "written retab: %#x", c.written);
	}

	/* a failing load changes nothing and reports the address */
	init_state(&c);
	m = (struct mem){ .fault_lo = o.x[1] + 8, .fault_hi = o.x[1] + 16 };
	CHECK(run(ldraa(1, 1, 8, 1, 0), &c, &m, &fa) == SWEET_PAC_FAULT && fa == o.x[1] + 8 && m.loads == 1,
	    "ldraa fault: fa=%" PRIx64, fa);
	CHECK(memcmp(&c, &o, sizeof(c)) == 0, "ldraa fault changed registers");

	/* anything else: untouched */
	init_state(&c);
	CHECK(run(0xD65F03C0u, &c, &m, &fa) == SWEET_PAC_UNHANDLED && memcmp(&c, &o, sizeof(c)) == 0, "ret");
	CHECK(run(0xD503233Fu, &c, &m, &fa) == SWEET_PAC_UNHANDLED, "paciasp is a hint");
	CHECK(run(0x1E7E0020u, &c, &m, &fa) == SWEET_PAC_UNHANDLED, "fjcvtzs is 0141's");

	printf("%s: unit tests, %d failure(s)\n", failures ? "FAIL" : "PASS", failures);
	return failures != 0;
}

/* the software part of one trap, as sleh.c does it: snapshot, execute, write back cpu.written */
static int
bench(void)
{
	static const struct { const char *name; uint32_t w; } mix[] = {
		{ "pacia x0, x1", 0xDAC10020u }, { "autdza x5", 0xDAC13BE5u }, { "braa x16, x17", 0xD71F0A11u },
		{ "blrab x8, x9", 0xD73F0D09u }, { "retab", 0xD65F0FFFu }, { "ldraa x9, [x8, #16]!", 0xF8202D09u },
		{ "pacga x0, x1, x2", 0x9AC23020u },
	};
	struct sweet_pac_cpu state, cpu, orig;
	struct mem m = { 0 };
	uint64_t fa = 0, sink = 0;
	const unsigned n = 20000000;

	init_state(&state);
	orig = state;
	for (unsigned k = 0; k < sizeof(mix) / sizeof(mix[0]); k++) {
		struct timespec t0, t1;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		for (unsigned i = 0; i < n; i++) {
			for (unsigned r = 0; r < 31; r++) {     /* get_saved_state_reg() x 31 + sp + pc */
				cpu.x[r] = state.x[r];
			}
			cpu.sp = state.sp;
			cpu.pc = state.pc;
			run(mix[k].w, &cpu, &m, &fa);
			for (uint32_t wm = cpu.written; wm != 0; wm &= wm - 1) {
				const unsigned r = (unsigned)__builtin_ctz(wm);
				if (r < 31) {
					state.x[r] = cpu.x[r];
				} else {
					state.sp = cpu.sp;
				}
			}
			state.pc = cpu.pc;
			sink += state.pc;
			state.pc = orig.pc;             /* same work every iteration */
			state.x[8] = orig.x[8];
			__asm__ volatile("" ::: "memory");
		}
		clock_gettime(CLOCK_MONOTONIC, &t1);
		const double ns = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / n;
		printf("%-22s %5.1f ns\n", mix[k].name, ns);
	}
	return sink == 1;
}

int
main(int argc, char **argv)
{
	char line[256], out[128];

	if (argc < 2 || strcmp(argv[1], "unit") == 0) {
		return unit();
	}
	if (strcmp(argv[1], "bench") == 0) {
		return bench();
	}
	const int exec = strcmp(argv[1], "exec") == 0;
	if (!exec && strcmp(argv[1], "decode") != 0) {
		fprintf(stderr, "usage: %s unit|decode|exec\n", argv[0]);
		return 2;
	}
	while (fgets(line, sizeof(line), stdin)) {
		const uint32_t w = (uint32_t)strtoul(line, NULL, 16);
		if (!exec) {
			canonical(w, out, sizeof(out));
			printf("%08x %s\n", w, out);
			continue;
		}
		struct sweet_pac_cpu c, o;
		struct mem m = { 0 };
		uint64_t fa = 0;
		init_state(&c); o = c;
		enum sweet_pac_result r = run(w, &c, &m, &fa);
		if (r != SWEET_PAC_DONE) {
			printf("%08x %s\n", w, r == SWEET_PAC_FAULT ? "FAULT" : "NONE");
			continue;
		}
		printf("%08x pc=%" PRIx64, w, c.pc);
		if (c.sp != o.sp) {
			printf(" sp=%" PRIx64, c.sp);
		}
		for (unsigned i = 0; i < 31; i++) {
			if (c.x[i] != o.x[i]) {
				printf(" x%u=%" PRIx64, i, c.x[i]);
			}
		}
		/* the kernel writes back only cpu.written: every change must be in it */
		for (unsigned i = 0; i < 32; i++) {
			const int changed = i < 31 ? c.x[i] != o.x[i] : c.sp != o.sp;
			if (changed && !(c.written & (1u << i))) {
				printf(" NOT-IN-WRITTEN-MASK:%u", i);
			}
		}
		printf("\n");
	}
	return 0;
}
