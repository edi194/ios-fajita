/*
 * sweet-iokit-test: the first userspace client of the SweetAdreno630 IOKit service.
 *
 * The same walk a Mesa winsys does, with no libdrm in between: open the service, read
 * INFO, allocate two buffers, map one into this task, write a PM4 command buffer into
 * the mapping, submit it with both buffers listed, wait on the fence the kernel returns
 * and read the target back through its own mapping.
 *
 * Build (no Xcode, no macOS):
 *   clang --target=arm64-apple-ios16.0 -isysroot $SDK -fuse-ld=lld -L$SDK/usr/lib \
 *       -framework IOKit -framework CoreFoundation -lSystem -o sweet-iokit-test \
 *       tools/sweet-iokit-test.c
 *
 * The structures and selector numbers mirror iokit/Kernel/arm/SweetAdrenoABI.h.
 */
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define SEL_GEM_NEW     0x42
#define SEL_GEM_INFO    0x43
#define SEL_GEM_SUBMIT  0x46
#define SEL_WAIT_FENCE  0x47
#define SEL_INFO        0x70

#define INFO_GET_IOVA   1u

#define MSM_SUBMIT_CMD_BUF   1u
#define MSM_SUBMIT_BO_READ   1u
#define MSM_SUBMIT_BO_WRITE  2u

struct sweet_gpu_info {
	uint32_t abi_version;
	uint32_t flags;
	uint32_t gpu_id;
	uint32_t chip_id;
	uint64_t va_start;
	uint64_t va_size;
	uint32_t last_fence;
	uint32_t reserved;
};

struct sweet_msm_gem_new {
	uint64_t size;
	uint32_t flags;
	uint32_t handle;
};

struct sweet_msm_gem_info {
	uint32_t handle;
	uint32_t info;
	uint64_t value;
	uint32_t len;
	uint32_t pad;
};

struct sweet_msm_gem_submit_bo {
	uint32_t flags;
	uint32_t handle;
	uint64_t presumed;
};

struct sweet_msm_gem_submit_cmd {
	uint32_t type;
	uint32_t submit_idx;
	uint32_t submit_offset;
	uint32_t size;
	uint32_t pad;
	uint32_t nr_relocs;
	uint64_t relocs;
};

struct sweet_msm_gem_submit {
	uint32_t flags;
	uint32_t fence;
	uint32_t nr_bos;
	uint32_t nr_cmds;
	uint64_t bos;
	uint64_t cmds;
	int32_t fence_fd;
	uint32_t queueid;
	uint64_t in_syncobjs;
	uint64_t out_syncobjs;
	uint32_t nr_in_syncobjs;
	uint32_t nr_out_syncobjs;
	uint32_t syncobj_stride;
	uint32_t pad;
};

struct sweet_msm_timespec {
	int64_t tv_sec;
	int64_t tv_nsec;
};

struct sweet_msm_wait_fence {
	uint32_t fence;
	uint32_t pad;
	struct sweet_msm_timespec timeout;
	uint32_t queueid;
};

/* PM4 type 7 header with the parity bits, as the kernel computes them */
static uint32_t
pkt7(uint32_t opcode, uint32_t count)
{
	uint32_t parity = 0x9669u >> (0xfu & (count ^ (count >> 4) ^ (count >> 8)));
	uint32_t pop = 0x9669u >> (0xfu & (opcode ^ (opcode >> 4) ^ (opcode >> 8)));

	return 0x70000000u | count | ((parity & 1u) << 15) |
	    ((opcode & 0x7fu) << 16) | ((pop & 1u) << 23);
}

#define CP_NOP           16u
#define CP_MEM_WRITE     61u

static int
call(io_connect_t conn, uint32_t sel, void *in, size_t inlen, void *out, size_t *outlen)
{
	return IOConnectCallStructMethod(conn, sel, in, inlen, out, outlen);
}

int
main(void)
{
	io_service_t svc;
	io_connect_t conn = 0;
	kern_return_t kr;
	struct sweet_gpu_info info;
	size_t len;
	int rc = 1;

	CFMutableDictionaryRef match = IOServiceMatching("SweetAdreno630");
	if (match == NULL) {
		printf("GPU IOKIT: no dictionary\n");
		return 1;
	}
	svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
	if (svc == 0) {
		printf("GPU IOKIT: SweetAdreno630 not in the registry\n");
		return 1;
	}
	kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
	IOObjectRelease(svc);
	if (kr != KERN_SUCCESS) {
		printf("GPU IOKIT: open failed %#x\n", kr);
		return 1;
	}

	memset(&info, 0, sizeof(info));
	len = sizeof(info);
	if (call(conn, SEL_INFO, NULL, 0, &info, &len) != 0) {
		printf("GPU IOKIT: INFO failed\n");
		return 1;
	}
	printf("GPU IOKIT: abi %u flags %#x gpu %u chip %#x va %#llx+%#llx fence %u\n",
	    info.abi_version, info.flags, info.gpu_id, info.chip_id,
	    (unsigned long long)info.va_start, (unsigned long long)info.va_size,
	    info.last_fence);

	/* two buffers: the command stream and the target */
	struct sweet_msm_gem_new cmd = { .size = 0x2000, .flags = 0 };
	struct sweet_msm_gem_new dst = { .size = 0x1000, .flags = 0 };
	if (call(conn, SEL_GEM_NEW, &cmd, sizeof(cmd), &cmd, &len) != 0 || cmd.handle == 0 ||
	    call(conn, SEL_GEM_NEW, &dst, sizeof(dst), &dst, &len) != 0 || dst.handle == 0) {
		printf("GPU IOKIT: GEM_NEW failed\n");
		return 1;
	}

	struct sweet_msm_gem_info gi = { .handle = dst.handle, .info = INFO_GET_IOVA };
	len = sizeof(gi);
	if (call(conn, SEL_GEM_INFO, &gi, sizeof(gi), &gi, &len) != 0 || gi.value == 0) {
		printf("GPU IOKIT: GET_IOVA failed\n");
		return 1;
	}
	uint64_t dst_va = gi.value;

	/* map both buffers into this task: memoryType is the handle */
	mach_vm_address_t cmd_map = 0, dst_map = 0;
	mach_vm_size_t cmd_map_size = 0, dst_map_size = 0;
	kr = IOConnectMapMemory64(conn, cmd.handle, mach_task_self(), &cmd_map, &cmd_map_size,
	    kIOMapAnywhere);
	if (kr != KERN_SUCCESS) {
		printf("GPU IOKIT: map of the command buffer failed %#x\n", kr);
		return 1;
	}
	kr = IOConnectMapMemory64(conn, dst.handle, mach_task_self(), &dst_map, &dst_map_size,
	    kIOMapAnywhere);
	if (kr != KERN_SUCCESS) {
		printf("GPU IOKIT: map of the target failed %#x\n", kr);
		return 1;
	}

	/* NOP, MEM_WRITE(dst+0x10, 0x600d0001), MEM_WRITE(dst+0x20, 0x600d0002) */
	uint32_t *ib = (uint32_t *)(uintptr_t)cmd_map;
	unsigned n = 0;
	ib[n++] = pkt7(CP_NOP, 1);
	ib[n++] = 0;
	for (unsigned i = 0; i < 2; i++) {
		ib[n++] = pkt7(CP_MEM_WRITE, 3);
		ib[n++] = (uint32_t)(dst_va + 0x10u * (i + 1));
		ib[n++] = (uint32_t)((dst_va + 0x10u * (i + 1)) >> 32);
		ib[n++] = 0x600d0001u + i;
	}
	__builtin_arm_dsb(15);

	struct sweet_msm_gem_submit_bo bos[2] = {
		{ .flags = MSM_SUBMIT_BO_READ, .handle = cmd.handle },
		{ .flags = MSM_SUBMIT_BO_WRITE, .handle = dst.handle },
	};
	struct sweet_msm_gem_submit_cmd cmds[1] = {
		{ .type = MSM_SUBMIT_CMD_BUF, .submit_idx = 0, .submit_offset = 0,
		  .size = n * 4, .nr_relocs = 0, .relocs = 0 },
	};
	struct sweet_msm_gem_submit sub = {
		.flags = 0, .nr_bos = 2, .nr_cmds = 1,
		.bos = (uint64_t)(uintptr_t)bos, .cmds = (uint64_t)(uintptr_t)cmds,
		.fence_fd = -1, .queueid = 0,
	};
	len = sizeof(sub);
	if (call(conn, SEL_GEM_SUBMIT, &sub, sizeof(sub), &sub, &len) != 0 || sub.fence == 0) {
		printf("GPU IOKIT: GEM_SUBMIT failed\n");
		return 1;
	}
	printf("GPU IOKIT: submitted %u dwords, fence %u\n", n, sub.fence);

	struct sweet_msm_wait_fence wait = {
		.fence = sub.fence, .timeout = { .tv_sec = 2, .tv_nsec = 0 }, .queueid = 0,
	};
	len = sizeof(wait);
	if (call(conn, SEL_WAIT_FENCE, &wait, sizeof(wait), &wait, &len) != 0) {
		printf("GPU IOKIT: WAIT_FENCE failed\n");
		return 1;
	}

	uint32_t *out = (uint32_t *)(uintptr_t)dst_map;
	uint32_t want1 = 0x600d0001u, want2 = 0x600d0002u;
	printf("GPU IOKIT: read back %#x %#x (want %#x %#x)\n",
	    out[4], out[8], want1, want2);
	if (out[4] == want1 && out[8] == want2) {
		printf("GPU IOKIT: PASS - a userspace process submitted through IOKit and read the GPU's writes\n");
		rc = 0;
	} else {
		printf("GPU IOKIT: FAIL\n");
	}

	IOServiceClose(conn);
	return rc;
}
