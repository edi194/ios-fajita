/*
 * adreno_uc_test: exercises the SweetAdreno630 user client (docs/GPU_KERNEL.md) without Mesa.
 * Needs a kernel booted with sweetgpu=8 whose log shows "SweetAdreno630 published".
 *
 *   gpu/kernel-test/build.sh            -> out/adreno_uc_test (arm64e, stripped of PAC and ad-hoc signed by renegade)
 *   scp out/adreno_uc_test root@192.168.7.2:/usr/local/bin/ ; ssh root@192.168.7.2 /usr/local/bin/adreno_uc_test
 *
 * Steps (each prints PASS/FAIL; exit status = number of failures):
 *   1 open service, INFO (abi version, ready)      5 GEM_INFO GET_IOVA/GET_OFFSET + map into this task
 *   2 GET_PARAM chip id, GMEM size, GPU id, VA     6 CP_NOP + CP_MEM_WRITE (direct address) + CP_MEM_WRITE (address via
 *   3 GEM_NEW, error paths (bad handle, size 0)       relocation) through GEM_SUBMIT, WAIT_FENCE, CPU_PREP, check the BO
 *   4 SUBMITQUEUE_NEW / CLOSE                      7 second submit (fence order), poll wait, 8 1 MiB BO written at 16 offsets
 *                                                   (every 4 KiB granule of a 16 KiB page, page ends), GEM_CLOSE, INFO again
 * Add "-v" for the raw numbers.
 */
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurfaceRef.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../../xnu/gpu-abi/sweet_adreno_abi.h"

static int g_fail, g_verbose;
static uint32_t g_last_fence;   /* highest fence this run submitted */
#define CHECK(cond, ...) do { if (cond) { printf("PASS  "); } else { printf("FAIL  "); g_fail++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static io_connect_t g_conn;

static kern_return_t
call(uint32_t sel, void *s, size_t in, size_t out)
{
	size_t o = out;
	return IOConnectCallStructMethod(g_conn, sel, s, in, out ? s : NULL, out ? &o : NULL);
}

static uint32_t
parity(uint32_t v)
{
	v ^= v >> 16; v ^= v >> 8; v ^= v >> 4; v ^= v >> 2; v ^= v >> 1;
	return (v & 1) ^ 1;     /* odd-parity bit as in Linux pm4_calc_odd_parity_bit() */
}

static uint32_t
pkt7(uint32_t opcode, uint32_t cnt)
{
	return 0x70000000u | cnt | (parity(cnt) << 15) | ((opcode & 0x7f) << 16) | (parity(opcode) << 23);
}

static kern_return_t
get_param(uint32_t p, uint64_t *v)
{
	struct sweet_msm_param a = { .pipe = SWEET_MSM_PIPE_3D0, .param = p };
	kern_return_t kr = call(SWEET_GPU_SEL_GET_PARAM, &a, sizeof(a), sizeof(a));
	*v = a.value;
	return kr;
}

/* Read-only register snapshot of the kernel (SWEET_GPU_SEL_DEBUG); index meaning in sweet_adreno_abi.h. */
static void
dump_debug(const char *when)
{
	struct sweet_gpu_debug d;
	memset(&d, 0, sizeof(d));
	kern_return_t kr = call(SWEET_GPU_SEL_DEBUG, &d, 0, sizeof(d));
	printf("DEBUG %s (kr %#x): flags %#x (b0 core readable, b1 lost, b2 ready)\n", when, kr, d.w[0]);
	printf("  GMU: RPMH_POWER_STATE %#x SPTPRAC %#x AHB_FENCE ctrl %#x dropped %#x AO counter %#x%08x KEEPALIVE %u SYSRESET %u HFI %#x HOST_INT %#x\n",
	    d.w[1], d.w[2], d.w[3], d.w[4], d.w[9], d.w[8], d.w[13], d.w[12], d.w[11], d.w[14]);
	printf("  gpucc: GX gdscr %#x (b31 on) gfx3d cbcr %#x (b31 off) CX gdscr %#x\n", d.w[5], d.w[7], d.w[6]);
	printf("  ring: submitted %u completed %u soft WPTR %u\n", d.w[15], d.w[17], d.w[16]);
	printf("  SMMU CB1: FSR %#x FAR %#x%08x FSYNR0 %#x SCTLR %#x; sGFSR %#x sGFSYNR0 %#x\n", d.w[19], d.w[21], d.w[20], d.w[22], d.w[25], d.w[23], d.w[24]);
	if (d.w[0] & 1) {
		printf("  CP: RPTR %u WPTR %u SQE_CNTL %#x STATUS_1 %#x RBBM_STATUS %#x HW_FAULT %#x CP_IRQ %#x PROTECT %#x RBBM_IRQ %#x IB1 %#x%08x rem %u RB_BASE %#x\n",
		    d.w[26], d.w[27], d.w[33], d.w[28], d.w[29], d.w[30], d.w[31], d.w[34], d.w[32], d.w[36], d.w[35], d.w[37], d.w[39]);
	}
}

static struct sweet_msm_timespec
rel(int sec, int nsec)
{
	struct sweet_msm_timespec t = { sec, nsec };
	return t;
}

int
main(int argc, char **argv)
{
	g_verbose = argc > 1 && !strcmp(argv[1], "-v");
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(SWEET_GPU_SERVICE_NAME));
	CHECK(svc != IO_OBJECT_NULL, "service %s found", SWEET_GPU_SERVICE_NAME);
	if (svc == IO_OBJECT_NULL) {
		printf("is the kernel booted with sweetgpu=8 and did the log say \"SweetAdreno630 published\"?\n");
		return 1;
	}
	kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
	CHECK(kr == KERN_SUCCESS, "IOServiceOpen -> %#x", kr);
	if (kr != KERN_SUCCESS) {
		return 1;
	}

	/* 1 */
	struct sweet_gpu_info info;
	memset(&info, 0, sizeof(info));
	kr = call(SWEET_GPU_SEL_INFO, &info, 0, sizeof(info));
	CHECK(kr == 0 && info.abi_version == SWEET_GPU_ABI_VERSION, "INFO abi %u (want %u) kr %#x", info.abi_version, SWEET_GPU_ABI_VERSION, kr);
	CHECK((info.flags & 3) == 1, "INFO flags %#x (1 = ready, 2 = lost) chip %#x va %#llx+%#llx last_fence %u",
	    info.flags, info.chip_id, info.va_start, info.va_size, info.last_fence);
	if ((info.flags & 3) != 1) {
		return 1;
	}

	dump_debug("at start (GPU idle since boot)");
	/* 2 */
	uint64_t v = 0;
	kr = get_param(SWEET_MSM_PARAM_CHIP_ID, &v);
	CHECK(kr == 0 && v == 0x06030001, "GET_PARAM CHIP_ID %#llx (want 0x06030001)", v);
	kr = get_param(SWEET_MSM_PARAM_GPU_ID, &v);
	CHECK(kr == 0 && v == 630, "GET_PARAM GPU_ID %llu", v);
	kr = get_param(SWEET_MSM_PARAM_GMEM_SIZE, &v);
	CHECK(kr == 0 && v == 0x100000, "GET_PARAM GMEM_SIZE %#llx", v);
	kr = get_param(SWEET_MSM_PARAM_MAX_FREQ, &v);
	CHECK(kr == 0 && v != 0, "GET_PARAM MAX_FREQ %llu Hz", v);
	uint64_t t0 = 0, t1 = 0;
	kr = get_param(SWEET_MSM_PARAM_TIMESTAMP, &t0);
	usleep(1000);
	(void)get_param(SWEET_MSM_PARAM_TIMESTAMP, &t1);
	CHECK(kr == 0 && t1 > t0, "GET_PARAM TIMESTAMP advances: %llu -> %llu (19.2 MHz: ~19200 per ms)", t0, t1);
	kr = get_param(SWEET_MSM_PARAM_VA_START, &v);
	CHECK(kr == 0 && v == 0x80000000ull, "GET_PARAM VA_START %#llx", v);
	kr = get_param(0x7777, &v);
	CHECK(kr != 0, "GET_PARAM unknown -> %#x (expected error)", kr);

	/* 3 */
	struct sweet_msm_gem_new nb = { .size = 0 };
	kr = call(SWEET_GPU_SEL_GEM_NEW, &nb, sizeof(nb), sizeof(nb));
	CHECK(kr != 0, "GEM_NEW size 0 -> %#x (expected error)", kr);
	struct sweet_msm_gem_info bad = { .handle = 0x1234, .info = SWEET_MSM_INFO_GET_IOVA };
	kr = call(SWEET_GPU_SEL_GEM_INFO, &bad, sizeof(bad), sizeof(bad));
	CHECK(kr != 0, "GEM_INFO bad handle -> %#x (expected error)", kr);
	struct sweet_msm_gem_new nb2 = { .size = 16384, .flags = 0 };
	kr = call(SWEET_GPU_SEL_GEM_NEW, &nb2, sizeof(nb2), sizeof(nb2));
	CHECK(kr == 0 && nb2.handle != 0, "GEM_NEW 16384 -> handle %u kr %#x", nb2.handle, kr);
	if (kr != 0) {
		return g_fail ? g_fail : 1;
	}

	/* 4 */
	struct sweet_msm_submitqueue q = { 0 };
	kr = call(SWEET_GPU_SEL_SUBMITQUEUE_NEW, &q, sizeof(q), sizeof(q));
	CHECK(kr == 0 && q.id != 0, "SUBMITQUEUE_NEW id %u", q.id);
	uint32_t qid = q.id;
	kr = call(SWEET_GPU_SEL_SUBMITQUEUE_CLOSE, &qid, sizeof(qid), 0);
	CHECK(kr == 0, "SUBMITQUEUE_CLOSE %u", qid);

	/* 5 */
	struct sweet_msm_gem_info gi = { .handle = nb2.handle, .info = SWEET_MSM_INFO_GET_IOVA };
	kr = call(SWEET_GPU_SEL_GEM_INFO, &gi, sizeof(gi), sizeof(gi));
	uint64_t iova = gi.value;
	CHECK(kr == 0 && iova >= 0x80000000ull && iova < 0x100000000ull && !(iova & 0xfff), "GEM_INFO GET_IOVA %#llx", iova);
	struct sweet_msm_gem_info go = { .handle = nb2.handle, .info = SWEET_MSM_INFO_GET_OFFSET };
	kr = call(SWEET_GPU_SEL_GEM_INFO, &go, sizeof(go), sizeof(go));
	CHECK(kr == 0 && go.value == nb2.handle, "GEM_INFO GET_OFFSET %llu (= handle, the memoryType)", go.value);
	mach_vm_address_t addr = 0;
	mach_vm_size_t size = 0;
	kr = IOConnectMapMemory64(g_conn, (uint32_t)go.value, mach_task_self(), &addr, &size, kIOMapAnywhere | kIOMapWriteCombineCache);
	CHECK(kr == 0 && addr != 0 && size >= 16384, "IOConnectMapMemory64 -> %#llx size %llu kr %#x", (unsigned long long)addr, (unsigned long long)size, kr);
	if (kr != 0) {
		return g_fail ? g_fail : 1;
	}
	volatile uint32_t *bo = (volatile uint32_t *)(uintptr_t)addr;
	CHECK(bo[0] == 0 && bo[4095] == 0, "BO is zero-filled");

	/* 6: command stream at BO+0, targets at BO+0x1000 (direct) and BO+0x1004 (through a relocation) */
	struct sweet_msm_gem_cpu_prep cp = { .handle = nb2.handle, .op = SWEET_MSM_PREP_WRITE, .timeout = rel(1, 0) };
	kr = call(SWEET_GPU_SEL_GEM_CPU_PREP, &cp, sizeof(cp), 0);
	CHECK(kr == 0, "CPU_PREP write (idle BO) kr %#x", kr);
	const uint32_t v1 = 0x5ee70011u, v2 = 0x5ee70022u;
	unsigned n = 0;
	bo[n++] = pkt7(16, 1);                          /* CP_NOP */
	bo[n++] = 0;
	bo[n++] = pkt7(61, 3);                          /* CP_MEM_WRITE addr_lo addr_hi value */
	bo[n++] = (uint32_t)(iova + 0x1000);
	bo[n++] = (uint32_t)((iova + 0x1000) >> 32);
	bo[n++] = v1;
	bo[n++] = pkt7(61, 3);
	unsigned reloc_at = n;
	bo[n++] = 0xdeadbeef;                           /* patched by the kernel: iova(BO) + 0x1004 */
	bo[n++] = 0;
	bo[n++] = v2;
	struct sweet_msm_gem_cpu_fini cf = { .handle = nb2.handle };
	kr = call(SWEET_GPU_SEL_GEM_CPU_FINI, &cf, sizeof(cf), 0);
	CHECK(kr == 0, "CPU_FINI kr %#x", kr);

	struct sweet_msm_gem_submit_reloc rl = { .submit_offset = reloc_at * 4, .or_ = 0, .shift = 0, .reloc_idx = 0, .reloc_offset = 0x1004 };
	struct sweet_msm_gem_submit_bo sb = { .flags = SWEET_MSM_SUBMIT_BO_READ | SWEET_MSM_SUBMIT_BO_WRITE, .handle = nb2.handle };
	struct sweet_msm_gem_submit_cmd sc = { .type = SWEET_MSM_SUBMIT_CMD_BUF, .submit_idx = 0, .submit_offset = 0, .size = n * 4,
		.nr_relocs = 1, .relocs = (uint64_t)(uintptr_t)&rl };
	struct sweet_msm_gem_submit sub = { .nr_bos = 1, .nr_cmds = 1, .bos = (uint64_t)(uintptr_t)&sb, .cmds = (uint64_t)(uintptr_t)&sc };
	kr = call(SWEET_GPU_SEL_GEM_SUBMIT, &sub, sizeof(sub), sizeof(sub));
	if (kr == 0) {
		g_last_fence = sub.fence;
	}
	CHECK(kr == 0 && sub.fence != 0, "GEM_SUBMIT (NOP + 2x MEM_WRITE, one reloc) -> fence %u kr %#x", sub.fence, kr);
	if (kr != 0) {
		return g_fail ? g_fail : 1;
	}
	CHECK(bo[reloc_at] == (uint32_t)(iova + 0x1004), "relocation patched: %#x (want %#x)", bo[reloc_at], (uint32_t)(iova + 0x1004));
	struct sweet_msm_wait_fence wf = { .fence = sub.fence, .timeout = rel(2, 0) };
	kr = call(SWEET_GPU_SEL_WAIT_FENCE, &wf, sizeof(wf), 0);
	CHECK(kr == 0, "WAIT_FENCE %u kr %#x", sub.fence, kr);
	if (kr != 0) {
		dump_debug("after the WAIT_FENCE failed");
	}
	cp.op = SWEET_MSM_PREP_READ;
	kr = call(SWEET_GPU_SEL_GEM_CPU_PREP, &cp, sizeof(cp), 0);
	CHECK(kr == 0, "CPU_PREP read kr %#x", kr);
	CHECK(bo[0x1000 / 4] == v1, "BO+0x1000 = %#x (want %#x: direct CP_MEM_WRITE)", bo[0x1000 / 4], v1);
	CHECK(bo[0x1004 / 4] == v2, "BO+0x1004 = %#x (want %#x: CP_MEM_WRITE through the relocation)", bo[0x1004 / 4], v2);

	/* 7: a second submission, polled; fences are ordered */
	bo[0x1008 / 4] = 0;
	n = 0;
	bo[n++] = pkt7(61, 3);
	bo[n++] = (uint32_t)(iova + 0x1008);
	bo[n++] = 0;
	bo[n++] = 0xc0ffee00u;
	sc.size = n * 4;
	sc.nr_relocs = 0;
	sc.relocs = 0;
	struct sweet_msm_gem_submit sub2 = sub;
	sub2.fence = 0;
	kr = call(SWEET_GPU_SEL_GEM_SUBMIT, &sub2, sizeof(sub2), sizeof(sub2));
	if (kr == 0) {
		g_last_fence = sub2.fence;
	}
	CHECK(kr == 0 && (int32_t)(sub2.fence - sub.fence) > 0, "second GEM_SUBMIT fence %u > %u kr %#x", sub2.fence, sub.fence, kr);
	wf.fence = sub2.fence;
	wf.timeout = rel(0, 0);
	int polls = 0;
	for (; polls < 2000 && (kr = call(SWEET_GPU_SEL_WAIT_FENCE, &wf, sizeof(wf), 0)) != 0; polls++) {
		usleep(1000);
	}
	CHECK(kr == 0 && bo[0x1008 / 4] == 0xc0ffee00u, "polled WAIT_FENCE done after %d polls, BO+0x1008 = %#x", polls, bo[0x1008 / 4]);
	struct sweet_msm_wait_fence future = { .fence = sub2.fence + 1000, .timeout = rel(0, 0) };
	kr = call(SWEET_GPU_SEL_WAIT_FENCE, &future, sizeof(future), 0);
	CHECK(kr != 0, "WAIT_FENCE on a fence never submitted -> %#x (expected error)", kr);
	sub2.queueid = 63;
	kr = call(SWEET_GPU_SEL_GEM_SUBMIT, &sub2, sizeof(sub2), sizeof(sub2));
	CHECK(kr != 0, "GEM_SUBMIT with an unopened queue id -> %#x (expected error)", kr);

	/* 8: a 1 MiB BO (many 16 KiB xnu pages, each 4 KiB GPU page mapped separately): CP_MEM_WRITE at offsets in every 4 KiB
	 * granule of the first 16 KiB page, across page boundaries and at the very end. Command stream in the first 4 KiB. */
	{
		struct sweet_msm_gem_new big = { .size = 1 << 20 };
		kr = call(SWEET_GPU_SEL_GEM_NEW, &big, sizeof(big), sizeof(big));
		CHECK(kr == 0 && big.handle != 0, "GEM_NEW 1 MiB -> handle %u kr %#x", big.handle, kr);
		if (kr == 0) {
			struct sweet_msm_gem_info bi = { .handle = big.handle, .info = SWEET_MSM_INFO_GET_IOVA };
			(void)call(SWEET_GPU_SEL_GEM_INFO, &bi, sizeof(bi), sizeof(bi));
			struct sweet_msm_gem_info bo2 = { .handle = big.handle, .info = SWEET_MSM_INFO_GET_OFFSET };
			(void)call(SWEET_GPU_SEL_GEM_INFO, &bo2, sizeof(bo2), sizeof(bo2));
			mach_vm_address_t baddr = 0;
			mach_vm_size_t bsize = 0;
			kr = IOConnectMapMemory64(g_conn, (uint32_t)bo2.value, mach_task_self(), &baddr, &bsize, kIOMapAnywhere | kIOMapWriteCombineCache);
			CHECK(kr == 0 && bsize >= (1 << 20), "map 1 MiB BO -> %#llx size %llu", (unsigned long long)baddr, (unsigned long long)bsize);
			if (kr == 0) {
				volatile uint32_t *bb = (volatile uint32_t *)(uintptr_t)baddr;
				static const uint32_t offs[] = { 0x1000, 0x2000, 0x3000, 0x3ffc, 0x4000, 0x4004, 0x5000, 0x7000, 0x8000, 0x10000,
					0x40000, 0x7f000, 0x80000, 0xc0010, 0xff000, 0xffffc };
				const unsigned noffs = sizeof(offs) / sizeof(offs[0]);
				unsigned k = 0;
				for (unsigned i = 0; i < noffs; i++) {
					bb[offs[i] / 4] = 0;
				}
				for (unsigned i = 0; i < noffs; i++) {
					bb[k++] = pkt7(61, 3);
					bb[k++] = (uint32_t)(bi.value + offs[i]);
					bb[k++] = (uint32_t)((bi.value + offs[i]) >> 32);
					bb[k++] = 0xb16b0000u | i;
				}
				struct sweet_msm_gem_submit_bo sb2 = { .flags = SWEET_MSM_SUBMIT_BO_READ | SWEET_MSM_SUBMIT_BO_WRITE, .handle = big.handle };
				struct sweet_msm_gem_submit_cmd sc2 = { .type = SWEET_MSM_SUBMIT_CMD_BUF, .submit_idx = 0, .submit_offset = 0, .size = k * 4 };
				struct sweet_msm_gem_submit su = { .nr_bos = 1, .nr_cmds = 1, .bos = (uint64_t)(uintptr_t)&sb2, .cmds = (uint64_t)(uintptr_t)&sc2 };
				kr = call(SWEET_GPU_SEL_GEM_SUBMIT, &su, sizeof(su), sizeof(su));
				if (kr == 0) {
					g_last_fence = su.fence;
				}
				CHECK(kr == 0 && su.fence != 0, "GEM_SUBMIT %u MEM_WRITEs into the 1 MiB BO -> fence %u kr %#x", noffs, su.fence, kr);
				struct sweet_msm_wait_fence w2 = { .fence = su.fence, .timeout = rel(2, 0) };
				kr = call(SWEET_GPU_SEL_WAIT_FENCE, &w2, sizeof(w2), 0);
				CHECK(kr == 0, "WAIT_FENCE %u kr %#x", su.fence, kr);
				if (kr != 0) {
					dump_debug("after the 1 MiB submit failed");
				}
				unsigned bad = 0;
				for (unsigned i = 0; i < noffs; i++) {
					if (bb[offs[i] / 4] != (0xb16b0000u | i)) {
						printf("  offset %#x = %#x (want %#x)\n", offs[i], bb[offs[i] / 4], 0xb16b0000u | i);
						bad++;
					}
				}
				CHECK(bad == 0, "%u of %u writes landed in the 1 MiB BO", noffs - bad, noffs);
				IOConnectUnmapMemory64(g_conn, (uint32_t)bo2.value, mach_task_self(), baddr);
			}
			struct sweet_gem_close bc = { .handle = big.handle };
			(void)call(SWEET_GPU_SEL_GEM_CLOSE, &bc, sizeof(bc), 0);
		}
	}

	/* 9: IOSurface import (SWEET_GPU_SEL_SURFACE_BO): a kernel surface (GPU writes a dword into it, CPU reads it back) and a
	 * client-memory ("wrapped") surface (imported read-only, flags checked, same handle on the second call). */
	{
		struct sweet_gpu_info inf2;
		memset(&inf2, 0, sizeof(inf2));
		(void)call(SWEET_GPU_SEL_INFO, &inf2, 0, sizeof(inf2));
		CHECK(inf2.abi_minor >= 1, "INFO abi_minor %u (>= 1: surface import with planes/flags)", inf2.abi_minor);
		int w = 256, h = 64, bpr = 256 * 4, fmt = 'BGRA', bpe = 4;
		CFNumberRef nw = CFNumberCreate(NULL, kCFNumberIntType, &w), nh = CFNumberCreate(NULL, kCFNumberIntType, &h),
		    nb = CFNumberCreate(NULL, kCFNumberIntType, &bpr), nf = CFNumberCreate(NULL, kCFNumberIntType, &fmt),
		    ne = CFNumberCreate(NULL, kCFNumberIntType, &bpe);
		CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFDictionarySetValue(d, kIOSurfaceWidth, nw);
		CFDictionarySetValue(d, kIOSurfaceHeight, nh);
		CFDictionarySetValue(d, kIOSurfaceBytesPerRow, nb);
		CFDictionarySetValue(d, kIOSurfacePixelFormat, nf);
		CFDictionarySetValue(d, kIOSurfaceBytesPerElement, ne);
		IOSurfaceRef surf = IOSurfaceCreate(d);
		CHECK(surf != NULL, "IOSurfaceCreate 256x64 BGRA");
		if (surf) {
			struct sweet_gpu_surface_bo sb3;
			memset(&sb3, 0, sizeof(sb3));
			sb3.surface_id = IOSurfaceGetID(surf);
			kr = call(SWEET_GPU_SEL_SURFACE_BO, &sb3, sizeof(sb3), sizeof(sb3));
			CHECK(kr == 0 && sb3.handle != 0 && sb3.iova >= 0x80000000ull && sb3.bytes_per_row == (uint32_t)bpr && sb3.tiling == 0 && sb3.ubwc == 0,
			    "SURFACE_BO kernel surface: handle %u iova %#llx size %llu stride %u offset %u flags %#x plane0 {off %u stride %u %ux%u} kr %#x",
			    sb3.handle, sb3.iova, sb3.size, sb3.bytes_per_row, sb3.offset, sb3.flags, sb3.plane[0].offset, sb3.plane[0].stride,
			    sb3.plane[0].width, sb3.plane[0].height, kr);
			if (kr == 0) {
				struct sweet_gpu_surface_bo again = sb3;
				again.flags = 0;
				kr = call(SWEET_GPU_SEL_SURFACE_BO, &again, sizeof(again), sizeof(again));
				CHECK(kr == 0 && again.handle == sb3.handle && (again.flags & SWEET_GPU_SBO_EXISTING), "SURFACE_BO again: same handle %u, EXISTING flag (%#x)", again.handle, again.flags);
				/* GPU writes a dword at pixel (3,2): through a tiny cmd BO */
				struct sweet_msm_gem_new cb = { .size = 4096 };
				(void)call(SWEET_GPU_SEL_GEM_NEW, &cb, sizeof(cb), sizeof(cb));
				struct sweet_msm_gem_info ci = { .handle = cb.handle, .info = SWEET_MSM_INFO_GET_IOVA }, co = { .handle = cb.handle, .info = SWEET_MSM_INFO_GET_OFFSET };
				(void)call(SWEET_GPU_SEL_GEM_INFO, &ci, sizeof(ci), sizeof(ci));
				(void)call(SWEET_GPU_SEL_GEM_INFO, &co, sizeof(co), sizeof(co));
				mach_vm_address_t ca = 0;
				mach_vm_size_t cs = 0;
				kr = IOConnectMapMemory64(g_conn, (uint32_t)co.value, mach_task_self(), &ca, &cs, kIOMapAnywhere | kIOMapWriteCombineCache);
				if (kr == 0) {
					volatile uint32_t *c = (volatile uint32_t *)(uintptr_t)ca;
					uint64_t px = sb3.iova + sb3.offset + 2ull * sb3.bytes_per_row + 3 * 4;
					c[0] = pkt7(61, 3);
					c[1] = (uint32_t)px;
					c[2] = (uint32_t)(px >> 32);
					c[3] = 0xa11ce001u;
					struct sweet_msm_gem_submit_bo b4[2] = { { .flags = SWEET_MSM_SUBMIT_BO_READ, .handle = cb.handle },
						{ .flags = SWEET_MSM_SUBMIT_BO_WRITE, .handle = sb3.handle } };
					struct sweet_msm_gem_submit_cmd c4 = { .type = SWEET_MSM_SUBMIT_CMD_BUF, .submit_idx = 0, .size = 16 };
					struct sweet_msm_gem_submit s4 = { .nr_bos = 2, .nr_cmds = 1, .bos = (uint64_t)(uintptr_t)b4, .cmds = (uint64_t)(uintptr_t)&c4 };
					kr = call(SWEET_GPU_SEL_GEM_SUBMIT, &s4, sizeof(s4), sizeof(s4));
					if (kr == 0) {
						g_last_fence = s4.fence;
					}
					struct sweet_msm_wait_fence w4 = { .fence = s4.fence, .timeout = rel(2, 0) };
					kr |= call(SWEET_GPU_SEL_WAIT_FENCE, &w4, sizeof(w4), 0);
					struct sweet_gpu_bo_sync sy = { .handle = sb3.handle };
					(void)call(SWEET_GPU_SEL_BO_SYNC, &sy, sizeof(sy), 0);
					IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
					uint32_t got = ((volatile uint32_t *)((uint8_t *)IOSurfaceGetBaseAddress(surf) + 2 * bpr))[3];
					IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
					CHECK(kr == 0 && got == 0xa11ce001u, "GPU wrote pixel (3,2) of the kernel surface: %#x (want 0xa11ce001) kr %#x", got, kr);
					IOConnectUnmapMemory64(g_conn, (uint32_t)co.value, mach_task_self(), ca);
				}
				struct sweet_gem_close cc2 = { .handle = cb.handle };
				(void)call(SWEET_GPU_SEL_GEM_CLOSE, &cc2, sizeof(cc2), 0);
				cc2.handle = sb3.handle;
				kr = call(SWEET_GPU_SEL_GEM_CLOSE, &cc2, sizeof(cc2), 0);
				CHECK(kr == 0, "GEM_CLOSE of the surface BO");
			}
			CFRelease(surf);
		}
		/* client memory surface: our own anonymous pages wrapped by IOSurface (IOSurfaceAddress); skipped if refused */
		size_t len = 256 * 64 * 4;
		void *mem = mmap(NULL, len + 16384, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
		if (mem != MAP_FAILED) {
			memset((uint8_t *)mem + 16, 0x5a, len);
			int64_t addr64 = (int64_t)(uintptr_t)((uint8_t *)mem + 16);     /* not page aligned on purpose */
			CFNumberRef na = CFNumberCreate(NULL, kCFNumberSInt64Type, &addr64);
			int asz = (int)len;
			CFNumberRef ns = CFNumberCreate(NULL, kCFNumberIntType, &asz);
			CFDictionarySetValue(d, CFSTR("IOSurfaceAddress"), na);
			CFDictionarySetValue(d, kIOSurfaceAllocSize, ns);
			IOSurfaceRef ws = IOSurfaceCreate(d);
			if (ws == NULL) {
				printf("SKIP  wrapped IOSurface could not be created from client memory\n");
			} else {
				struct sweet_gpu_surface_bo wb;
				memset(&wb, 0, sizeof(wb));
				wb.surface_id = IOSurfaceGetID(ws);
				wb.flags = SWEET_GPU_SBO_IN_SYNC;
				kr = call(SWEET_GPU_SEL_SURFACE_BO, &wb, sizeof(wb), sizeof(wb));
				CHECK(kr == 0 && wb.handle != 0, "SURFACE_BO wrapped surface: handle %u iova %#llx size %llu offset %u flags %#x kr %#x", wb.handle, wb.iova, wb.size, wb.offset, wb.flags, kr);
				if (kr == 0) {
					CHECK((wb.flags & SWEET_GPU_SBO_WRAPPED) && (wb.flags & SWEET_GPU_SBO_READONLY) && (wb.flags & SWEET_GPU_SBO_CPU_CACHEABLE),
					    "wrapped flags WRAPPED|READONLY|CPU_CACHEABLE (%#x)", wb.flags);
					CHECK(wb.offset == 16, "pixel (0,0) is %u bytes into the first page (client address +16)", wb.offset);
					/* minor 2: writable CPU alias (the owner's memory here is RW, so the alias must show through the owner's mapping) */
					if (inf2.abi_minor >= 2 && (inf2.flags & SWEET_GPU_INFO_CAP_SBO_ALIAS)) {
						struct sweet_gpu_surface_bo ab = wb;
						ab.flags = SWEET_GPU_SBO_IN_WRITABLE_ALIAS;
						kr = call(SWEET_GPU_SEL_SURFACE_BO, &ab, sizeof(ab), sizeof(ab));
						CHECK(kr == 0 && ab.handle == wb.handle && (ab.flags & SWEET_GPU_SBO_ALIAS) && ab.alias_addr != 0 && ab.alias_size == wb.size,
						    "SURFACE_BO writable alias: handle %u addr %#llx size %llu flags %#x kr %#x", ab.handle, ab.alias_addr, ab.alias_size, ab.flags, kr);
						if (kr == 0 && ab.alias_addr != 0) {
							volatile uint8_t *al = (volatile uint8_t *)(uintptr_t)ab.alias_addr;
							for (unsigned i = 0; i < 64; i++) {
								al[ab.offset + i] = (uint8_t)(0xa0 + i);
							}
							struct sweet_gpu_bo_sync sy = { .handle = ab.handle, .offset = 0, .size = 0 };
							kr = call(SWEET_GPU_SEL_BO_SYNC, &sy, sizeof(sy), 0);
							int bad = 0;
							for (unsigned i = 0; i < 64; i++) {
								bad += ((volatile uint8_t *)mem)[16 + i] != (uint8_t)(0xa0 + i);
							}
							CHECK(kr == 0 && bad == 0, "alias stores visible through the owner's mapping after BO_SYNC (kr %#x, %d bad bytes)", kr, bad);
							struct sweet_gpu_surface_bo again2 = ab;
							kr = call(SWEET_GPU_SEL_SURFACE_BO, &again2, sizeof(again2), sizeof(again2));
							CHECK(kr == 0 && again2.alias_addr == ab.alias_addr, "alias is idempotent (same address %#llx)", again2.alias_addr);
						}
					}
					struct sweet_gem_close wc = { .handle = wb.handle };
					(void)call(SWEET_GPU_SEL_GEM_CLOSE, &wc, sizeof(wc), 0);
				}
				CFRelease(ws);
			}
			munmap(mem, len + 16384);
		}
		CFRelease(d);
	}

	IOConnectUnmapMemory64(g_conn, (uint32_t)go.value, mach_task_self(), addr);
	struct sweet_gem_close gc = { .handle = nb2.handle };
	kr = call(SWEET_GPU_SEL_GEM_CLOSE, &gc, sizeof(gc), 0);
	CHECK(kr == 0, "GEM_CLOSE kr %#x", kr);
	kr = call(SWEET_GPU_SEL_GEM_CLOSE, &gc, sizeof(gc), 0);
	CHECK(kr != 0, "GEM_CLOSE again -> %#x (expected error)", kr);
	memset(&info, 0, sizeof(info));
	kr = call(SWEET_GPU_SEL_INFO, &info, 0, sizeof(info));
	CHECK(kr == 0 && (info.flags & 3) == 1 && info.last_fence == g_last_fence, "INFO after the run: flags %#x last_fence %u (want %u)", info.flags, info.last_fence, g_last_fence);
	IOServiceClose(g_conn);
	printf("%s: %d failure(s)\n", g_fail ? "FAILED" : "ALL PASSED", g_fail);
	return g_fail;
}
