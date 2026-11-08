/*
 * pactest: exercise the kernel PAC emulation (xnu patch 1019, sweetarm64e=1) from an arm64e binary that
 * was NOT run through pacstrip. Build: tools/pacemu/build.sh. Run on the phone: /var/root/pactest
 *
 * Every PAC sequence (pactest_asm.S) is valid arm64e code, so the tool also passes on a CPU with
 * pointer authentication; there (hw.optional.arm.FEAT_PAuth = 1) only the CPU-independent checks run.
 * On the Poco F1 (FEAT_PAuth = 0) the strict checks run too: PAC* leaves the pointer plain, PACGA is
 * pacstrip's EOR Xd, Xn, Xm, ROR #13. The compiler's own code (PACIBSP/RETAB in every frame, BRAA in
 * the libSystem stubs) is unstripped as well, so reaching main() already means RETAB/BRAA work.
 * Output: one PASS/FAIL line per check, then a summary; exit status 0 = all passed.
 */
#include <inttypes.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>

uint64_t t_retab(void), t_retaa(void);
uint64_t t_braa(void), t_brab_sp(void), t_braaz(void), t_brabz(void);
int64_t t_blraa(void), t_blrab_sp(void), t_blraaz_lr(void), t_blrabz(void);
void t_ldraa_pre(const uint64_t *, uint64_t[2]), t_ldraa_off(const uint64_t *, uint64_t[2]);
void t_ldrab_neg(const uint64_t *, uint64_t[2]), t_ldraa_far(const uint64_t *, uint64_t[2]);
void t_ldrab_sp(uint64_t[2]);
uint64_t t_ldraa_load(const uint64_t *);
#define PACDECL(k) uint64_t t_pac_##k(uint64_t, uint64_t), t_roundtrip_##k(uint64_t, uint64_t);
PACDECL(ia) PACDECL(ib) PACDECL(da) PACDECL(db) PACDECL(iza) PACDECL(izb) PACDECL(dza) PACDECL(dzb)
uint64_t t_xpaci(uint64_t), t_xpacd(uint64_t);
uint64_t t_pacga_a(uint64_t, uint64_t), t_pacga_b(uint64_t, uint64_t);
void t_pacga_sp(uint64_t, uint64_t[2]);
void t_loop_nop(uint64_t), t_loop_svc(uint64_t), t_loop_pacia(uint64_t), t_loop_braa(uint64_t);
void t_loop_blraa(uint64_t), t_loop_retab(uint64_t), t_loop_ldraa(uint64_t), t_loop_pacga(uint64_t);
uint32_t t_fjcvtzs(double);

static int npass, nfail, emulated;

static void
check(int ok, const char *name, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

#include <stdarg.h>
static void
check(int ok, const char *name, const char *fmt, ...)
{
	va_list ap;
	printf("%s %s", ok ? "PASS" : "FAIL", name);
	if (fmt && *fmt) {
		printf(": ");
		va_start(ap, fmt);
		vprintf(fmt, ap);
		va_end(ap);
	}
	printf("\n");
	fflush(stdout);
	ok ? npass++ : nfail++;
}

static sigjmp_buf fault_jmp;
static volatile uint64_t fault_addr;
static volatile int fault_sig;

static void
on_fault(int sig, siginfo_t *si, void *uc)
{
	(void)uc;
	fault_sig = sig;
	fault_addr = (uint64_t)si->si_addr;
	siglongjmp(fault_jmp, 1);
}

static double
now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e9 + ts.tv_nsec;
}

int
main(void)
{
	int64_t pauth = -1;
	size_t len = sizeof(int32_t);
	int32_t v = 0;

	if (sysctlbyname("hw.optional.arm.FEAT_PAuth", &v, &len, NULL, 0) == 0) {
		pauth = v;
	}
	emulated = pauth != 1;
	printf("pactest: hw.optional.arm.FEAT_PAuth = %" PRId64 " -> %s checks\n", pauth,
	    emulated ? "emulation (strict)" : "real PAuth (portable)");
	check(1, "main reached", "PACIBSP/RETAB frames and BRAA libSystem stubs of this unstripped binary ran");

	/* returns and branches */
	check(t_retab() == 42, "retab", NULL);
	check(t_retaa() == 43, "retaa", NULL);
	check(t_braa() == 7, "braa x16, x17", NULL);
	check(t_brab_sp() == 8, "brab x16, sp", NULL);
	check(t_braaz() == 10, "braaz x16", NULL);
	check(t_brabz() == 11, "brabz x3", NULL);
	int64_t d;
	d = t_blraa();      check(d == 0, "blraa x16, x17 (LR = PC + 4)", "LR - expected = %" PRId64, d);
	d = t_blrab_sp();   check(d == 0, "blrab x9, sp", "LR - expected = %" PRId64, d);
	d = t_blraaz_lr();  check(d == 0, "blraaz x30 (target = old LR)", "LR - expected = %" PRId64, d);
	d = t_blrabz();     check(d == 0, "blrabz x0", "LR - expected = %" PRId64, d);

	/* loads */
	uint64_t arr[80], out[2];
	for (unsigned i = 0; i < 80; i++) {
		arr[i] = 0xA000000000000000ULL | (uint64_t)i * 0x1111;
	}
	t_ldraa_pre(arr, out);
	check(out[0] == arr[2] && out[1] == (uint64_t)&arr[2], "ldraa x9, [x8, #16]!", "x9=%" PRIx64 " x8-&arr[0]=%" PRId64,
	    out[0], (int64_t)(out[1] - (uint64_t)arr));
	t_ldraa_off(arr, out);
	check(out[0] == arr[1], "ldraa x9, [x8, #8]", "x9=%" PRIx64, out[0]);
	t_ldrab_neg(&arr[4], out);
	check(out[0] == arr[2], "ldrab x9, [x8, #-16]", "x9=%" PRIx64, out[0]);
	t_ldraa_far(arr, out);
	check(out[0] == arr[64] && out[1] == (uint64_t)&arr[64], "ldraa x9, [x8, #512]! (kernel only)",
	    "x9=%" PRIx64, out[0]);
	if (emulated) {
		/* an unsigned SP base only authenticates on a CPU without PAuth */
		t_ldrab_sp(out);
		check(out[0] == 0x1f2e5a5aULL && out[1] == 8, "ldrab x9, [sp, #8]!", "x9=%" PRIx64 " sp delta=%" PRId64,
		    out[0], (int64_t)out[1]);
	}

	struct sigaction sa = { 0 }, old_segv, old_bus;
	sa.sa_sigaction = on_fault;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, &old_segv);
	sigaction(SIGBUS, &sa, &old_bus);
	fault_sig = 0;
	if (sigsetjmp(fault_jmp, 1) == 0) {
		volatile uint64_t r = t_ldraa_load((const uint64_t *)0x10);
		check(0, "ldraa from 0x10 faults", "no fault, read %" PRIx64, r);
	} else {
		check((fault_sig == SIGSEGV || fault_sig == SIGBUS) && (fault_addr & 0x00FFFFFFFFFFFFFFULL) == 0x10,
		    "ldraa from 0x10 faults", "signal %d at %#" PRIx64, fault_sig, fault_addr);
	}
	sigaction(SIGSEGV, &old_segv, NULL);
	sigaction(SIGBUS, &old_bus, NULL);

	/* PAC / AUT / XPAC */
	const uint64_t ptr = (uint64_t)&arr[3], mod = 0x1234;
#define RT(k) do { \
	        uint64_t s = t_pac_##k(ptr, mod), r = t_roundtrip_##k(ptr, mod); \
	        check(r == ptr && (!emulated || s == ptr), "pac" #k "/aut" #k, \
	            "signed %" PRIx64 " roundtrip %" PRIx64 " ptr %" PRIx64, s, r, ptr); \
	} while (0)
	RT(ia); RT(ib); RT(da); RT(db); RT(iza); RT(izb); RT(dza); RT(dzb);
	check(t_xpaci(ptr) == ptr, "xpaci", NULL);
	check(t_xpacd(ptr) == ptr, "xpacd", NULL);

	/* PACGA: deterministic, independent of the registers; on this CPU pacstrip's value */
	const uint64_t n = 0x00007fff12345678ULL, m = 0x0000000102030405ULL;
	uint64_t ga = t_pacga_a(n, m), gb = t_pacga_b(n, m), ga2 = t_pacga_a(n, m);
	if (!emulated && t_pac_ia(ptr, mod) == ptr) {
		/* a plain arm64 process on macOS: PAC keys off, the GA key is not kept per process */
		printf("SKIP pacga: this process has its PAC keys disabled (not arm64e)\n");
	} else check(ga == gb && ga == ga2, "pacga deterministic (x0,x0,x1 = x7,x13,x21)", "%" PRIx64 " %" PRIx64 " %" PRIx64,
	    ga, gb, ga2);
	if (emulated) {
		const uint64_t want = n ^ (m >> 13 | m << 51);
		check(ga == want, "pacga = pacstrip EOR ROR #13", "got %" PRIx64 " want %" PRIx64, ga, want);
		t_pacga_sp(n, out);
		check(out[0] == n, "pacga x2, x0, sp = MOV", "got %" PRIx64, out[0]);
	} else if (t_pac_ia(ptr, mod) != ptr) {
		check((ga & 0xFFFFFFFFULL) == 0, "pacga low 32 bits zero (real PAuth)", "%" PRIx64, ga);
	}

	/* 0141 (not part of 1019, checked in passing) */
	check(t_fjcvtzs(-3.75) == (uint32_t)-3, "fjcvtzs (kernel 0141)", NULL);

	/*
	 * Profile: ns per instruction, minus the native loop. svc is a getppid() system call, i.e. the
	 * exception entry/exit every trap pays at least; trap - svc is what the emulation path adds.
	 */
	static const struct { const char *name; void (*fn)(uint64_t); } prof[] = {
		{ "nop (native)", t_loop_nop }, { "svc getppid", t_loop_svc }, { "pacia", t_loop_pacia },
		{ "braa", t_loop_braa }, { "blraa", t_loop_blraa }, { "retab (+bl)", t_loop_retab },
		{ "ldraa", t_loop_ldraa }, { "pacga", t_loop_pacga },
	};
	const uint64_t loops = 100000;
	double base = 0, svc = 0;
	for (unsigned i = 0; i < sizeof(prof) / sizeof(prof[0]); i++) {
		double best = 1e30;
		for (int rep = 0; rep < 3; rep++) {             /* best of 3 */
			double t0 = now_ns();
			prof[i].fn(loops);
			double t = (now_ns() - t0) / loops;
			best = t < best ? t : best;
		}
		if (i == 0) {
			base = best;
		} else if (i == 1) {
			svc = best - base;
		}
		printf("PROF %-14s %8.1f ns/insn", prof[i].name, best - (i ? base : 0));
		if (i >= 2 && svc > 0) {
			printf("  (%.2f x a syscall)", (best - base) / svc);
		}
		printf("\n");
	}

	printf("%s: %d passed, %d failed\n", nfail ? "FAIL" : "PASS", npass, nfail);
	return nfail != 0;
}
