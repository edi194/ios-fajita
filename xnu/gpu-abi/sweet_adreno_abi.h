/*
 * SweetAdreno630: IOKit ABI of the Heartwood Adreno 630 kernel driver (Poco F1).
 *
 * This file is the contract between the kernel (iokit/Kernel/arm/SweetAdreno.cpp,
 * the same bytes are installed there as SweetAdrenoABI.h by xnu/patches-11215/0182)
 * and the userland winsys (Mesa freedreno/msm backend, EAGL bridge). Human-readable
 * description, call sequences and error codes: docs/GPU_KERNEL.md. Keep both in sync.
 *
 * The requests are those of the Linux msm DRM driver (include/uapi/drm/msm_drm.h:
 * request numbers = DRM_COMMAND_BASE (0x40) + DRM_MSM_*, structure layouts), so that a
 * libdrm stand-in can forward drmIoctl(fd, DRM_IOCTL_MSM_X, &arg) unchanged:
 *
 *     kern_return_t kr = IOConnectCallStructMethod(conn, SWEET_GPU_SEL_X,
 *                            &arg, sizeof(arg), &arg, &(size_t){ sizeof(arg) });
 *
 * Struct layouts below are the Linux uapi ones (they are an ABI of Mesa, not code).
 * Differences from Linux are listed in docs/GPU_KERNEL.md ("Differences from msm").
 */
#ifndef SWEET_ADRENO_ABI_H
#define SWEET_ADRENO_ABI_H

#include <stdint.h>

/* IOServiceMatching() name of the service; IOServiceOpen(type 0) gives the connection. */
#define SWEET_GPU_SERVICE_NAME          "SweetAdreno630"
#define SWEET_GPU_ABI_VERSION           1

/* Selectors of IOConnectCallStructMethod. */
enum sweet_gpu_selector {
	SWEET_GPU_SEL_GEM_CLOSE         = 0x09, /* DRM_IOCTL_GEM_CLOSE:        struct sweet_gem_close */
	SWEET_GPU_SEL_GET_PARAM         = 0x40, /* DRM_MSM_GET_PARAM:          struct sweet_msm_param (in/out) */
	SWEET_GPU_SEL_SET_PARAM         = 0x41, /* DRM_MSM_SET_PARAM:          unsupported (kIOReturnUnsupported) */
	SWEET_GPU_SEL_GEM_NEW           = 0x42, /* DRM_MSM_GEM_NEW:            struct sweet_msm_gem_new (in/out) */
	SWEET_GPU_SEL_GEM_INFO          = 0x43, /* DRM_MSM_GEM_INFO:           struct sweet_msm_gem_info (in/out) */
	SWEET_GPU_SEL_GEM_CPU_PREP      = 0x44, /* DRM_MSM_GEM_CPU_PREP:       struct sweet_msm_gem_cpu_prep */
	SWEET_GPU_SEL_GEM_CPU_FINI      = 0x45, /* DRM_MSM_GEM_CPU_FINI:       struct sweet_msm_gem_cpu_fini */
	SWEET_GPU_SEL_GEM_SUBMIT        = 0x46, /* DRM_MSM_GEM_SUBMIT:         struct sweet_msm_gem_submit (in/out) */
	SWEET_GPU_SEL_WAIT_FENCE        = 0x47, /* DRM_MSM_WAIT_FENCE:         struct sweet_msm_wait_fence */
	SWEET_GPU_SEL_GEM_MADVISE       = 0x48, /* DRM_MSM_GEM_MADVISE:        struct sweet_msm_gem_madvise (in/out) */
	SWEET_GPU_SEL_SUBMITQUEUE_NEW   = 0x4a, /* DRM_MSM_SUBMITQUEUE_NEW:    struct sweet_msm_submitqueue (in/out) */
	SWEET_GPU_SEL_SUBMITQUEUE_CLOSE = 0x4b, /* DRM_MSM_SUBMITQUEUE_CLOSE:  uint32_t id */
	SWEET_GPU_SEL_SUBMITQUEUE_QUERY = 0x4c, /* DRM_MSM_SUBMITQUEUE_QUERY:  unsupported */
	/* Heartwood additions (not in msm) */
	SWEET_GPU_SEL_INFO              = 0x70, /* struct sweet_gpu_info (out) */
	SWEET_GPU_SEL_SURFACE_BO        = 0x71, /* struct sweet_gpu_surface_bo (in/out): IOSurface memory as a BO */
	SWEET_GPU_SEL_BO_SYNC           = 0x72, /* struct sweet_gpu_bo_sync: clean+invalidate the CPU alias of a BO */
	SWEET_GPU_SEL_DEBUG             = 0x73, /* struct sweet_gpu_debug (out): read-only register snapshot, safe when GX is off */
};

/* Memory mapping: IOConnectMapMemory64(conn, memoryType = BO handle, task, &addr, &size,
 * kIOMapAnywhere | kIOMapWriteCombineCache). The "mmap offset" of GEM_INFO(GET_OFFSET) is the handle. */

/* ---- structures (Linux uapi layouts, fixed width, natural alignment) ---- */

struct sweet_msm_timespec {
	int64_t tv_sec;
	int64_t tv_nsec;
};

/* NOTE: timeouts in this ABI are RELATIVE durations ({0,0} = poll), not absolute CLOCK_MONOTONIC. */

struct sweet_msm_param {
	uint32_t pipe;          /* MSM_PIPE_3D0 (0x10) */
	uint32_t param;         /* MSM_PARAM_* */
	uint64_t value;         /* out */
	uint32_t len;
	uint32_t pad;
};

struct sweet_msm_gem_new {
	uint64_t size;          /* in, rounded up to 4 KiB */
	uint32_t flags;         /* in, MSM_BO_*; the cache flags are ignored: every BO is write-combined */
	uint32_t handle;        /* out, > 0 */
};

struct sweet_msm_gem_info {
	uint32_t handle;
	uint32_t info;          /* MSM_INFO_* */
	uint64_t value;         /* out (GET_*) or in (SET_IOVA) */
	uint32_t len;           /* SET_NAME: ignored */
	uint32_t pad;
};

struct sweet_msm_gem_cpu_prep {
	uint32_t handle;
	uint32_t op;            /* MSM_PREP_READ 1 | WRITE 2 | NOSYNC 4 */
	struct sweet_msm_timespec timeout;      /* relative */
};

struct sweet_msm_gem_cpu_fini {
	uint32_t handle;
};

struct sweet_msm_gem_submit_reloc {
	uint32_t submit_offset; /* byte offset of the dword to patch, from the start of the cmd's BO */
	uint32_t or_;           /* OR'd into the result */
	int32_t  shift;         /* left shift; negative = right shift */
	uint32_t reloc_idx;     /* index into the submit's bos[] */
	uint64_t reloc_offset;  /* byte offset from the start of that BO */
};

struct sweet_msm_gem_submit_cmd {
	uint32_t type;          /* MSM_SUBMIT_CMD_BUF 1, CTX_RESTORE_BUF 2 (run like BUF); PRIMARY (3) unsupported */
	uint32_t submit_idx;    /* index into bos[] of the command stream BO */
	uint32_t submit_offset; /* byte offset into that BO, multiple of 4 */
	uint32_t size;          /* bytes, multiple of 4 */
	uint32_t pad;
	uint32_t nr_relocs;
	uint64_t relocs;        /* user pointer to sweet_msm_gem_submit_reloc[nr_relocs] */
};

struct sweet_msm_gem_submit_bo {
	uint32_t flags;         /* MSM_SUBMIT_BO_READ 1 | WRITE 2 | DUMP 4 | NO_IMPLICIT 8 */
	uint32_t handle;
	uint64_t presumed;      /* ignored (the kernel address is the one from GEM_INFO(GET_IOVA)) */
};

struct sweet_msm_gem_submit {
	uint32_t flags;         /* in: 0 only (no fence fds, syncobjs, SUDO); NO_IMPLICIT (0x80000000) tolerated */
	uint32_t fence;         /* out: sequence number, > 0 */
	uint32_t nr_bos;        /* 1..4096 */
	uint32_t nr_cmds;       /* 1..128 */
	uint64_t bos;           /* user pointers */
	uint64_t cmds;
	int32_t  fence_fd;      /* out: always -1 */
	uint32_t queueid;       /* 0 or a SUBMITQUEUE_NEW id */
	uint64_t in_syncobjs;   /* must be 0 */
	uint64_t out_syncobjs;  /* must be 0 */
	uint32_t nr_in_syncobjs;
	uint32_t nr_out_syncobjs;
	uint32_t syncobj_stride;
	uint32_t pad;
};

struct sweet_msm_wait_fence {
	uint32_t fence;
	uint32_t pad;
	struct sweet_msm_timespec timeout;      /* relative */
	uint32_t queueid;
};

struct sweet_msm_gem_madvise {
	uint32_t handle;
	uint32_t madv;
	uint32_t retained;      /* out: always 1 */
};

struct sweet_msm_submitqueue {
	uint32_t flags;         /* 0 */
	uint32_t prio;          /* 0 (one ring) */
	uint32_t id;            /* out */
};

struct sweet_gem_close {
	uint32_t handle;
	uint32_t pad;
};

/* ---- Heartwood additions ---- */

struct sweet_gpu_info {
	uint32_t abi_version;   /* SWEET_GPU_ABI_VERSION */
	uint32_t flags;         /* bit0 ready, bit1 lost (a submission never completed: reboot needed) */
	uint32_t gpu_id;        /* 630 */
	uint32_t chip_id;       /* 0x06030001 */
	uint64_t va_start;      /* GPU address range the kernel places BOs in */
	uint64_t va_size;
	uint32_t last_fence;    /* last submitted sequence number */
	uint32_t abi_minor;     /* 1: SURFACE_BO accepts client-memory surfaces (read-only mappings), is idempotent, returns planes
	                         * 2: SURFACE_BO can make a writable CPU alias of a client-memory surface (SBO_IN_WRITABLE_ALIAS),
	                         *    see SWEET_GPU_INFO_CAP_SBO_ALIAS */
};
/* INFO.flags capability bits (bit0/bit1 above are ready/lost; capabilities start at bit 4). */
#define SWEET_GPU_INFO_CAP_SBO_ALIAS    0x10    /* minor 2: SBO_IN_WRITABLE_ALIAS works (absent when boot-arg sweetgpualias=0) */

/* IOSurface memory as a BO: the pages of the surface (pixels from byte 0 of its memory) are entered into the
 * GPU address space. On input handle = SWEET_GPU_DESCRIBE_ONLY asks only for the geometry (no BO is made). */
#define SWEET_GPU_DESCRIBE_ONLY         0xffffffffu
/* Minor 1 (INFO.abi_minor >= 1) added everything after `planes`; a caller may pass/accept only the first
 * SWEET_GPU_SURFACE_BO_V1_SIZE bytes (minor 0 layout). */
#define SWEET_GPU_SURFACE_BO_V1_SIZE    48
/* Minor 2 appended `alias_addr`/`alias_size`. A minor 1 caller (112 bytes in, 112 bytes out) is answered with 112 bytes. */
#define SWEET_GPU_SURFACE_BO_MINOR1_SIZE 112
#define SWEET_GPU_SURFACE_BO_MINOR2_SIZE 128
#define SWEET_GPU_SBO_IN_SYNC           0x1     /* in flags: clean+invalidate the CPU alias of the whole BO before returning */
#define SWEET_GPU_SBO_READONLY          0x1     /* out flags: GPU mapping is read-only (client-memory surface) */
#define SWEET_GPU_SBO_CPU_CACHEABLE     0x2     /* out: the CPU maps it cacheable: BO_SYNC after CPU writes / before CPU reads */
#define SWEET_GPU_SBO_WRAPPED           0x4     /* out: the surface is client (another process') memory, pinned */
#define SWEET_GPU_SBO_EXISTING          0x8     /* out: this surface already had a BO for this connection: same handle returned */
/* Minor 2. Input bit (in flags, needs >= 128 input bytes in and out; kIOReturnUnsupported when sweetgpualias=0): also map
 * the pages of the BO READ-WRITE into the calling task and return the address in alias_addr. Any surface: client-memory
 * (wrapped) surfaces get a cacheable alias of their wired pages (their own mappings are read-only), kernel surfaces
 * (the sweetfb low pool, kernel buffers; these BOs are GPU-writable) the ordinary mapping with the surface's cache
 * attribute (write-back for the pool, write-combined otherwise). The mapping lives exactly as long as the BO (GEM_CLOSE or connection close unmaps it; do not munmap it
 * yourself) and is the CPU's door to a surface whose own mapping is read-only. A wrapped surface's GPU mapping stays read-only. Idempotent.
 * After writing through it call BO_SYNC on the written range (clean to the point of coherency) before the surface is
 * used by the GPU, by CoreAnimation's consumer or by the display. */
#define SWEET_GPU_SBO_IN_WRITABLE_ALIAS 0x2     /* in flags */
#define SWEET_GPU_SBO_ALIAS             0x10    /* out: alias_addr/alias_size are valid (a RW CPU mapping exists) */
struct sweet_gpu_surface_plane {
	uint32_t offset;        /* byte offset of the plane in the BO (includes the client-memory start delta) */
	uint32_t stride;        /* bytes per row of the plane */
	uint32_t width;
	uint32_t height;
};
struct sweet_gpu_surface_bo {
	uint32_t surface_id;    /* in: IOSurfaceGetID() */
	uint32_t handle;        /* in: DESCRIBE_ONLY or 0; out: BO handle (0 when describing) */
	uint64_t size;          /* out: bytes mapped (whole 4 KiB pages) */
	uint64_t iova;          /* out: GPU address of byte 0 of the surface memory (0 when describing) */
	uint32_t offset;        /* out: byte offset of pixel (0,0) in the BO */
	uint32_t bytes_per_row;
	uint32_t width;
	uint32_t height;
	uint32_t pixel_format;
	uint32_t planes;
	/* ---- minor 1 ---- */
	uint32_t flags;         /* in: SWEET_GPU_SBO_IN_*; out: SWEET_GPU_SBO_* */
	uint32_t tiling;        /* out: 0 = linear (IOSurfaces here are never tiled) */
	uint32_t ubwc;          /* out: 0 = no UBWC (IOSurfaces here are never compressed) */
	uint32_t reserved;
	struct sweet_gpu_surface_plane plane[3];        /* out: first three planes (planes == 0: plane 0 describes the surface) */
	/* ---- minor 2 ---- */
	uint64_t alias_addr;    /* out: SBO_ALIAS: address in the calling task of byte 0 of the BO (pixel (0,0) is at + offset) */
	uint64_t alias_size;    /* out: SBO_ALIAS: bytes mapped (== size) */
};
_Static_assert(sizeof(struct sweet_gpu_surface_bo) == SWEET_GPU_SURFACE_BO_MINOR2_SIZE, "sweet_gpu_surface_bo is 128 bytes (minor 2)");

struct sweet_gpu_bo_sync {
	uint32_t handle;
	uint32_t flags;         /* 0 */
	uint64_t offset;        /* byte range inside the BO; size 0 = to the end */
	uint64_t size;
};

/* SWEET_GPU_SEL_DEBUG: word index -> meaning. GPU-core words (26..39) are 0 unless w[0] bit0 is set.
 *  0 flags: bit0 GPU core readable (GX GDSC on + gfx3d clock on), bit1 lost, bit2 ready
 *  1 GMU RPMH_POWER_STATE (0xf = hardware slumber)   2 SPTPRAC_PWR_CLK_STATUS   3 AO_AHB_FENCE_CTRL (0 = allow)
 *  4 AHB_FENCE_STATUS (dropped accesses)   5 gpucc GX GDSCR (bit31 = on)   6 gpucc CX GDSCR   7 gx_gfx3d CBCR (bit31 = off)
 *  8/9 GMU always-on counter lo/hi (19.2 MHz)   10 GMU2HOST_INTR_INFO   11 HFI_CTRL_STATUS   12 CM3_SYSRESET
 *  13 PWR_COL_KEEPALIVE   14 AO_HOST_INTERRUPT_STATUS   15 last submitted seqno   16 soft ring WPTR   17 completed seqno (fence word)
 *  18 CM3_FW_INIT_RESULT   19 SMMU CB1 FSR   20/21 CB1 FAR lo/hi   22 CB1 FSYNR0   23 sGFSR   24 sGFSYNR0   25 CB1 SCTLR
 *  26 CP_RB_RPTR  27 CP_RB_WPTR  28 CP_STATUS_1  29 RBBM_STATUS  30 CP_HW_FAULT  31 CP_INTERRUPT_STATUS  32 RBBM_INT_0_STATUS
 *  33 CP_SQE_CNTL  34 CP_PROTECT_STATUS  35/36 CP_IB1_BASE lo/hi  37 CP_IB1_REM_SIZE  38 CP_ALWAYS_ON_COUNTER  39 CP_RB_BASE */
#define SWEET_GPU_DEBUG_WORDS           40
struct sweet_gpu_debug {
	uint32_t w[SWEET_GPU_DEBUG_WORDS];
};

/* ---- msm constants used above (values of msm_drm.h) ---- */

#define SWEET_MSM_PIPE_3D0              0x10

#define SWEET_MSM_PARAM_GPU_ID          0x01    /* 630 */
#define SWEET_MSM_PARAM_GMEM_SIZE       0x02    /* 0x100000 */
#define SWEET_MSM_PARAM_CHIP_ID         0x03    /* 0x06030001 */
#define SWEET_MSM_PARAM_MAX_FREQ        0x04    /* 710000000 (the GPU runs at 257 MHz until DCVS is implemented) */
#define SWEET_MSM_PARAM_TIMESTAMP       0x05    /* CP_ALWAYS_ON_COUNTER, 19.2 MHz */
#define SWEET_MSM_PARAM_GMEM_BASE       0x06    /* 0x100000 */
#define SWEET_MSM_PARAM_PRIORITIES      0x07    /* 1 */
#define SWEET_MSM_PARAM_PP_PGTABLE      0x08    /* 0: one address space for everybody */
#define SWEET_MSM_PARAM_FAULTS          0x09    /* 0 */
#define SWEET_MSM_PARAM_SUSPENDS        0x0a    /* 0 */
#define SWEET_MSM_PARAM_VA_START        0x0e    /* 0x80000000 */
#define SWEET_MSM_PARAM_VA_SIZE         0x0f    /* 0x80000000 */

#define SWEET_MSM_BO_SCANOUT            0x00000001
#define SWEET_MSM_BO_GPU_READONLY       0x00000002

#define SWEET_MSM_INFO_GET_OFFSET       0       /* value = handle: the memoryType for IOConnectMapMemory64 */
#define SWEET_MSM_INFO_GET_IOVA         1
#define SWEET_MSM_INFO_SET_NAME         2       /* accepted, ignored */
#define SWEET_MSM_INFO_SET_IOVA         4       /* only before the BO was ever submitted; range must be free, 4 KiB aligned */
#define SWEET_MSM_INFO_GET_FLAGS        5

#define SWEET_MSM_PREP_READ             0x01
#define SWEET_MSM_PREP_WRITE            0x02
#define SWEET_MSM_PREP_NOSYNC           0x04

#define SWEET_MSM_SUBMIT_CMD_BUF        1
#define SWEET_MSM_SUBMIT_CMD_CTX_RESTORE_BUF 2
#define SWEET_MSM_SUBMIT_CMD_PRIMARY    3

#define SWEET_MSM_SUBMIT_BO_READ        0x0001
#define SWEET_MSM_SUBMIT_BO_WRITE       0x0002
#define SWEET_MSM_SUBMIT_BO_DUMP        0x0004
#define SWEET_MSM_SUBMIT_BO_NO_IMPLICIT 0x0008

#define SWEET_MSM_SUBMIT_NO_IMPLICIT    0x80000000u

#endif /* SWEET_ADRENO_ABI_H */
