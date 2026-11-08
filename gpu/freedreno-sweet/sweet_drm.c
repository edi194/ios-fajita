/*
 * SPDX-License-Identifier: MIT
 *
 * libdrm stand-in for Mesa's freedreno "msm" backend on Heartwood (Poco F1, Adreno 630).
 *
 * Mesa's src/freedreno/drm/msm backend talks to /dev/dri/renderD* through libdrm (drmCommandWriteRead,
 * drmIoctl, drmGetVersion) and mmap()s buffers at the offset GEM_INFO(GET_OFFSET) returns. On Heartwood the
 * same requests are selectors of the IOKit user client "SweetAdreno630" (xnu/gpu-abi/sweet_adreno_abi.h,
 * docs/GPU_KERNEL.md), so this file provides, under the libdrm names, exactly what the backend calls and
 * forwards each request to IOConnectCallStructMethod. No Mesa source change is needed:
 *
 *   - "device fds" are dups of /dev/null (so os_dupfd_cloexec, close and fstat keep working); every such
 *     fd means THE connection (one GPU, one connection per process);
 *   - mmap()/munmap() of such an fd are interposed (dyld __interpose) and turned into
 *     IOConnectMapMemory64 / IOConnectUnmapMemory64 with the BO handle as memoryType (msm "offset" = handle);
 *   - absolute CLOCK_MONOTONIC timeouts of WAIT_FENCE / GEM_CPU_PREP become relative ones (the kernel ABI);
 *   - the reported DRM version is msm 1.3: no softpin, no robustness params, relocations + kernel-assigned
 *     iovas (GET_IOVA), submit queues, GMEM_BASE. Newer versions would make Mesa assign GPU addresses itself.
 *
 * Build: gpu/freedreno-sweet/build.sh (arm64e dylib, install name libdrm.2.dylib so a Mesa linked against a
 * libdrm of the same name uses it; also libdrm_freedreno-free: Mesa's freedreno does not use libdrm_freedreno).
 * Turnip (Vulkan) also runs over it: syncobjs are emulated on the kernel's fences and drmGetDevices2 names one device (below).
 * Mesa configuration: gpu/freedreno-sweet/README.md.
 */
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "../../xnu/gpu-abi/sweet_adreno_abi.h"

#define EXPORT __attribute__((visibility("default")))
#define DRM_COMMAND_BASE 0x40
#define DRM_IOCTL_GEM_CLOSE_NR 0x09

typedef struct _drmVersion {
	int   version_major, version_minor, version_patchlevel;
	int   name_len;
	char *name;
	int   date_len;
	char *date;
	int   desc_len;
	char *desc;
} drmVersion, *drmVersionPtr;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static io_connect_t g_conn;
static dev_t g_null_rdev;
static int g_trace;

/*
 * Buffer log (Chlorophyll, GPU fault hunting): when /private/var/tmp/drm-bolog exists at connect time, every BO this
 * process creates, imports, gets a GPU address for and closes, and every submit (its fence and BO handles), is appended
 * to /private/var/tmp/drmlog/<process>-<pid>.log, one line each, microseconds since boot first:
 *   T new h=H size=S | T sbo h=H surf=ID size=S iova=A | T iova h=H A | T close h=H | T submit fence=F bos=H,H,...
 * A kernel SMMU fault prints the faulting GPU address (FAR) and the last submitted fence: the log names the BO that
 * covered that address, when it was closed and which submit used it. The file starts over at 32 MiB (the old one is .old).
 */
static int g_bolog = -1;
static int g_bolog_fd = -1;
static char g_bolog_path[160];
static pthread_mutex_t g_bolog_lock = PTHREAD_MUTEX_INITIALIZER;

static void
bolog_open(void)
{
	struct stat st;

	g_bolog = stat("/private/var/tmp/drm-bolog", &st) == 0;
	if (!g_bolog) {
		return;
	}
	char name[64];
	const char *pn = getprogname();
	snprintf(name, sizeof(name), "%s", pn ? pn : "proc");
	mkdir("/private/var/tmp/drmlog", 0777);
	snprintf(g_bolog_path, sizeof(g_bolog_path), "/private/var/tmp/drmlog/%s-%d.log", name, (int)getpid());
	g_bolog_fd = open(g_bolog_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	if (g_bolog_fd < 0) {
		g_bolog = 0;
	}
}

static void
bolog_line(const char *line, size_t n)
{
	struct stat st;

	pthread_mutex_lock(&g_bolog_lock);
	if (g_bolog_fd >= 0 && fstat(g_bolog_fd, &st) == 0 && st.st_size > (32 << 20)) {
		char old[176];
		snprintf(old, sizeof(old), "%s.old", g_bolog_path);
		rename(g_bolog_path, old);
		close(g_bolog_fd);
		g_bolog_fd = open(g_bolog_path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
	}
	if (g_bolog_fd >= 0) {
		(void)write(g_bolog_fd, line, n);
	}
	pthread_mutex_unlock(&g_bolog_lock);
}

static unsigned long long
bolog_us(void)
{
	return (unsigned long long)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000ull);
}

/* after a successful call: in = what was sent, out = what came back */
static void
bolog_call(uint32_t sel, const uint8_t *in, const uint8_t *out, size_t outsz)
{
	char b[4096];
	int n = 0;

	switch (sel) {
	case SWEET_GPU_SEL_GEM_NEW: {
		const struct sweet_msm_gem_new *i = (const void *)in, *o = (const void *)out;
		n = snprintf(b, sizeof(b), "%llu new h=%u size=%llu\n", bolog_us(), outsz >= sizeof(*o) ? o->handle : 0,
		    (unsigned long long)i->size);
		break;
	}
	case SWEET_GPU_SEL_SURFACE_BO: {
		const struct sweet_gpu_surface_bo *o = (const void *)out;
		if (outsz < sizeof(o->iova) + 16 || o->handle == 0) {
			return;
		}
		n = snprintf(b, sizeof(b), "%llu sbo h=%u surf=%u size=%llu iova=0x%llx w=%u h=%u bpr=%u off=%u fmt=0x%x planes=%u\n",
		    bolog_us(), o->handle, o->surface_id, (unsigned long long)o->size, (unsigned long long)o->iova, o->width, o->height,
		    o->bytes_per_row, o->offset, o->pixel_format, o->planes);
		break;
	}
	case SWEET_GPU_SEL_GEM_INFO: {
		const struct sweet_msm_gem_info *i = (const void *)in, *o = (const void *)out;
		if (i->info != SWEET_MSM_INFO_GET_IOVA || outsz < sizeof(*o)) {
			return;
		}
		n = snprintf(b, sizeof(b), "%llu iova h=%u 0x%llx\n", bolog_us(), i->handle, (unsigned long long)o->value);
		break;
	}
	case SWEET_GPU_SEL_GEM_CLOSE: {
		const struct sweet_gem_close *i = (const void *)in;
		n = snprintf(b, sizeof(b), "%llu close h=%u\n", bolog_us(), i->handle);
		break;
	}
	case SWEET_GPU_SEL_GEM_SUBMIT: {
		const struct sweet_msm_gem_submit *i = (const void *)in, *o = (const void *)out;
		const struct sweet_msm_gem_submit_bo *bos = (const void *)(uintptr_t)i->bos;
		n = snprintf(b, sizeof(b), "%llu submit fence=%u bos=", bolog_us(), outsz >= 8 ? o->fence : 0);
		for (uint32_t k = 0; k < i->nr_bos && n < (int)sizeof(b) - 16; k++) {
			n += snprintf(b + n, sizeof(b) - (size_t)n, k ? ",%u" : "%u", bos[k].handle);
		}
		if (n < (int)sizeof(b) - 1) {
			b[n++] = '\n';
		}
		break;
	}
	default:
		return;
	}
	if (n > 0) {
		bolog_line(b, (size_t)(n < (int)sizeof(b) ? n : (int)sizeof(b)));
	}
}

static struct {
	void    *addr;
	uint32_t handle;
	size_t   len;
} g_maps[16384];
static unsigned g_nmaps;

static int
io_errno(kern_return_t kr)
{
	switch (kr) {
	case kIOReturnSuccess: return 0;
	case kIOReturnNoMemory: case kIOReturnNoSpace: case kIOReturnNoResources: return ENOMEM;
	case kIOReturnBadArgument: return EINVAL;
	case kIOReturnTimeout: return ETIMEDOUT;
	case kIOReturnBusy: return EBUSY;
	case kIOReturnNotReady: case kIOReturnNotFound: return ENODEV;
	case kIOReturnUnsupported: return ENOSYS;
	case kIOReturnNotPermitted: return EPERM;
	default: return EIO;
	}
}

static int
connect_once(void)
{
	int ok = 0;

	pthread_mutex_lock(&g_lock);
	if (g_conn == IO_OBJECT_NULL) {
		struct stat st;
		if (stat("/dev/null", &st) == 0) {
			g_null_rdev = st.st_rdev;
		}
		g_trace = getenv("SWEET_DRM_TRACE") != NULL;
		bolog_open();
		io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(SWEET_GPU_SERVICE_NAME));
		if (svc != IO_OBJECT_NULL) {
			if (IOServiceOpen(svc, mach_task_self(), 0, &g_conn) != KERN_SUCCESS) {
				g_conn = IO_OBJECT_NULL;
			}
			IOObjectRelease(svc);
		}
	}
	ok = g_conn != IO_OBJECT_NULL;
	pthread_mutex_unlock(&g_lock);
	return ok;
}

static int
is_ours(int fd)
{
	struct stat st;

	if (g_conn == IO_OBJECT_NULL || fd < 0 || fstat(fd, &st) != 0) {
		return 0;
	}
	return S_ISCHR(st.st_mode) && st.st_rdev == g_null_rdev;
}

static size_t g_sbo_size = SWEET_GPU_SURFACE_BO_V1_SIZE;   /* minor 0 layout until INFO says abi_minor >= 1 */

/* Sizes of the kernel structures (what the user client requires at least). */
static size_t
sel_size(uint32_t sel)
{
	switch (sel) {
	case SWEET_GPU_SEL_GEM_CLOSE: return sizeof(struct sweet_gem_close);
	case SWEET_GPU_SEL_GET_PARAM: return sizeof(struct sweet_msm_param);
	case SWEET_GPU_SEL_GEM_NEW: return sizeof(struct sweet_msm_gem_new);
	case SWEET_GPU_SEL_GEM_INFO: return sizeof(struct sweet_msm_gem_info);
	case SWEET_GPU_SEL_GEM_CPU_PREP: return sizeof(struct sweet_msm_gem_cpu_prep);
	case SWEET_GPU_SEL_GEM_CPU_FINI: return sizeof(struct sweet_msm_gem_cpu_fini);
	case SWEET_GPU_SEL_GEM_SUBMIT: return sizeof(struct sweet_msm_gem_submit);
	case SWEET_GPU_SEL_WAIT_FENCE: return sizeof(struct sweet_msm_wait_fence);
	case SWEET_GPU_SEL_GEM_MADVISE: return sizeof(struct sweet_msm_gem_madvise);
	case SWEET_GPU_SEL_SUBMITQUEUE_NEW: return sizeof(struct sweet_msm_submitqueue);
	case SWEET_GPU_SEL_SUBMITQUEUE_CLOSE: return sizeof(uint32_t);
	case SWEET_GPU_SEL_INFO: return sizeof(struct sweet_gpu_info);
	case SWEET_GPU_SEL_SURFACE_BO: return g_sbo_size;
	case SWEET_GPU_SEL_BO_SYNC: return sizeof(struct sweet_gpu_bo_sync);
	default: return 0;
	}
}

static int64_t
abs_to_rel_ns(const struct sweet_msm_timespec *t)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	int64_t d = (t->tv_sec - now.tv_sec) * 1000000000ll + (t->tv_nsec - now.tv_nsec);
	return d < 0 ? 0 : d;
}

static void
rel_timeout(struct sweet_msm_timespec *t)
{
	int64_t ns = abs_to_rel_ns(t);
	t->tv_sec = ns / 1000000000ll;
	t->tv_nsec = ns % 1000000000ll;
}

/* The last failed WAIT_FENCE, for whoever reports the failure (Chlorophyll's "fence timeout" also covers a fence the kernel
 * refuses as never submitted, and a GPU that is not ready): what the kernel said, and how long the call really took. */
static char g_wait_err[192];
static unsigned g_wait_err_n;

static void
wait_failed(const struct sweet_msm_wait_fence *w, kern_return_t kr, const struct timespec *t0)
{
	struct timespec t1;
	clock_gettime(CLOCK_MONOTONIC, &t1);
	int64_t took = (t1.tv_sec - t0->tv_sec) * 1000000000ll + (t1.tv_nsec - t0->tv_nsec);
	int64_t asked = w->timeout.tv_sec * 1000000000ll + w->timeout.tv_nsec;
	struct sweet_gpu_info info;
	size_t outsz = sizeof(info);
	memset(&info, 0, sizeof(info));
	kern_return_t ki = IOConnectCallStructMethod(g_conn, SWEET_GPU_SEL_INFO, NULL, 0, &info, &outsz);
	snprintf(g_wait_err, sizeof(g_wait_err), "WAIT_FENCE #%u fence %u queue %u: kr %#x (errno %d) after %lld of %lld ms; info kr %#x flags %#x last submitted %u",
	    ++g_wait_err_n, w->fence, w->queueid, kr, io_errno(kr), (long long)(took / 1000000), (long long)(asked / 1000000), ki, info.flags, info.last_fence);
}

/* Chlorophyll takes this when a fence wait fails: copies the last WAIT_FENCE failure into buf and forgets it, so an
 * empty answer means the wait failed without a WAIT_FENCE failing (Mesa's own wait for its submit thread). */
EXPORT void
sweet_drm_take_wait_error(char *buf, size_t size)
{
	if (size == 0) {
		return;
	}
	snprintf(buf, size, "%s", g_wait_err);
	g_wait_err[0] = 0;
}

/* One request: returns 0 or -errno. */
static int
sweet_call(uint32_t sel, void *data, size_t size)
{
	uint8_t in[256], out[256];
	size_t want = sel_size(sel), outsz = sizeof(out);

	if (!connect_once()) {
		return -ENODEV;
	}
	if (want == 0 || want > sizeof(in)) {
		return -ENOSYS;
	}
	if (sel == SWEET_GPU_SEL_GEM_MADVISE) {
		/* The kernel never purges a BO: its MADVISE only checks the handle and answers retained = 1. Mesa's BO cache
		 * calls it on every cached allocation and free (WILLNEED/DONTNEED), a kernel round trip each: 43 % of the
		 * GPU calls in backboardd's profile during a home-screen swipe. Answered here, as the kernel would. */
		((struct sweet_msm_gem_madvise *)data)->retained = 1;
		return 0;
	}
	memset(in, 0, sizeof(in));
	memcpy(in, data, size < want ? size : want);
	if (sel == SWEET_GPU_SEL_GEM_SUBMIT) {
		/* msm keeps the pipe id (MSM_PIPE_3D0 = 0x10) in the low bits of submit.flags; this kernel wants only NO_IMPLICIT there */
		((struct sweet_msm_gem_submit *)in)->flags &= ~0xffffu;
	}
	if (sel == SWEET_GPU_SEL_WAIT_FENCE) {
		rel_timeout(&((struct sweet_msm_wait_fence *)in)->timeout);
	} else if (sel == SWEET_GPU_SEL_GEM_CPU_PREP) {
		rel_timeout(&((struct sweet_msm_gem_cpu_prep *)in)->timeout);
	}
	struct timespec t0;
	if (sel == SWEET_GPU_SEL_WAIT_FENCE) {
		clock_gettime(CLOCK_MONOTONIC, &t0);
	}
	kern_return_t kr = IOConnectCallStructMethod(g_conn, sel, in, want, out, &outsz);
	if (sel == SWEET_GPU_SEL_WAIT_FENCE && kr != KERN_SUCCESS) {
		wait_failed((struct sweet_msm_wait_fence *)in, kr, &t0);
	}
	if (g_trace && kr != KERN_SUCCESS && sel != SWEET_GPU_SEL_WAIT_FENCE) {
		fprintf(stderr, "sweet_drm: selector %#x -> %#x\n", sel, kr);
	}
	if (kr == KERN_SUCCESS && g_bolog > 0) {
		bolog_call(sel, in, out, outsz);
	}
	if (kr == KERN_SUCCESS && outsz) {
		memcpy(data, out, outsz < size ? outsz : size);
	}
	return -io_errno(kr);
}

/* ---- libdrm API used by Mesa's freedreno msm backend ---- */

static int sweet_submit(void *data, unsigned long size);

EXPORT int
drmCommandWriteRead(int fd, unsigned long idx, void *data, unsigned long size)
{
	(void)fd;
	if (DRM_COMMAND_BASE + idx == SWEET_GPU_SEL_GEM_SUBMIT) {
		return sweet_submit(data, size);
	}
	return sweet_call((uint32_t)(DRM_COMMAND_BASE + idx), data, size);
}

EXPORT int
drmCommandWrite(int fd, unsigned long idx, void *data, unsigned long size)
{
	return drmCommandWriteRead(fd, idx, data, size);
}

EXPORT int
drmCommandRead(int fd, unsigned long idx, void *data, unsigned long size)
{
	return drmCommandWriteRead(fd, idx, data, size);
}

EXPORT int
drmIoctl(int fd, unsigned long request, void *arg)
{
	unsigned nr = (unsigned)(request & 0xff);
	size_t size = (request >> 16) & 0x3fff;
	int r;

	(void)fd;
	if (nr != DRM_IOCTL_GEM_CLOSE_NR && nr < DRM_COMMAND_BASE) {
		errno = ENOSYS;
		return -1;
	}
	r = sweet_call(nr, arg, size ? size : sel_size(nr));
	if (r) {
		errno = -r;
		return -1;
	}
	return 0;
}

EXPORT drmVersionPtr
drmGetVersion(int fd)
{
	drmVersionPtr v;

	if (!is_ours(fd) && !connect_once()) {
		errno = ENODEV;
		return NULL;
	}
	v = calloc(1, sizeof(*v));
	if (!v) {
		return NULL;
	}
	v->version_major = 1;
	/* 1.4 = FD_VERSION_SOFTPIN. Mesa 25.0.7's legacy (< 1.4) ringbuffer lacks attach_bo (NULL call in fd_batch_create, found on the phone), so the
	 * "sp" submit/ringbuffer path is the only one that works; gallium freedreno still takes the iova of every BO from GEM_INFO(GET_IOVA)
	 * (kernel-assigned) and passes it as `presumed`, which the kernel ignores. No relocations are emitted in this mode. */
	v->version_minor = 4;
	v->name = strdup("msm");
	v->name_len = 3;
	v->date = strdup("20261023");
	v->date_len = 8;
	v->desc = strdup("Heartwood SweetAdreno630");
	v->desc_len = (int)strlen(v->desc);
	return v;
}

EXPORT void
drmFreeVersion(drmVersionPtr v)
{
	if (v) {
		free(v->name);
		free(v->date);
		free(v->desc);
		free(v);
	}
}

/* "msm" (or any name) opens the one GPU connection; the fd is a dup of /dev/null. */
EXPORT int
drmOpenWithType(const char *name, const char *busid, int type)
{
	(void)name; (void)busid; (void)type;
	if (!connect_once()) {
		errno = ENODEV;
		return -1;
	}
	return open("/dev/null", O_RDWR | O_CLOEXEC);
}

EXPORT int
drmGetCap(int fd, uint64_t cap, uint64_t *value)
{
	(void)fd; (void)cap;
	*value = 0;             /* no syncobj, no prime */
	return 0;
}

/*
 * "Prime fds" for Turnip's dma-buf import (Chlorophyll on Turnip, chl_texture_from_iosurface): an IOSurface made a BO by
 * SURFACE_BO, handed to Vulkan as VkImportMemoryFdInfoKHR. The fd is a dup of /dev/null registered here with the BO's handle
 * and size; drmPrimeFDToHandle answers the handle, sweet_drm_prime_size the size (Turnip's msm_bo_init_dmabuf asks lseek
 * otherwise, patches/mesa-26.2/turnip-ios.patch). Vulkan owns and closes the fd after the import.
 */
EXPORT int sweet_drm_surface_bo(int fd, struct sweet_gpu_surface_bo *io);
#define PRIME_MAX 256
static struct { int fd; uint32_t handle; uint64_t size; } g_prime[PRIME_MAX];
static pthread_mutex_t g_prime_lock = PTHREAD_MUTEX_INITIALIZER;

EXPORT int
sweet_drm_surface_prime(int surface_id, struct sweet_gpu_surface_bo *out)
{
	memset(out, 0, sizeof(*out));
	out->surface_id = (uint32_t)surface_id;
	int r = sweet_drm_surface_bo(-1, out);
	if (r) {
		errno = -r;
		return -1;
	}
	int pfd = open("/dev/null", O_RDWR | O_CLOEXEC);
	if (pfd < 0)
		return -1;
	pthread_mutex_lock(&g_prime_lock);
	int slot = -1;
	for (int i = 0; i < PRIME_MAX && slot < 0; i++)
		if (g_prime[i].fd == pfd || g_prime[i].fd == 0)
			slot = i;
	if (slot < 0)
		slot = pfd % PRIME_MAX;
	g_prime[slot].fd = pfd;
	g_prime[slot].handle = out->handle;
	g_prime[slot].size = out->size;
	pthread_mutex_unlock(&g_prime_lock);
	return pfd;
}

EXPORT int64_t
sweet_drm_prime_size(int prime_fd)
{
	int64_t size = -1;
	pthread_mutex_lock(&g_prime_lock);
	for (int i = 0; i < PRIME_MAX; i++)
		if (g_prime[i].fd == prime_fd && prime_fd > 0) {
			size = (int64_t)g_prime[i].size;
			break;
		}
	pthread_mutex_unlock(&g_prime_lock);
	return size;
}

EXPORT int
drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle)
{
	(void)fd;
	int r = -1;
	pthread_mutex_lock(&g_prime_lock);
	for (int i = 0; i < PRIME_MAX; i++)
		if (g_prime[i].fd == prime_fd && prime_fd > 0) {
			*handle = g_prime[i].handle;
			r = 0;
			break;
		}
	pthread_mutex_unlock(&g_prime_lock);
	if (r)
		errno = EINVAL;
	return r;
}

EXPORT int
drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd)
{
	(void)fd; (void)handle; (void)flags; (void)prime_fd;
	errno = ENOSYS;
	return -1;
}

/*
 * ---- syncobjs, emulated on the kernel's fences (Turnip) ----
 *
 * Turnip's msm backend needs DRM syncobjs: binary sync objects that a submit signals (MSM_SUBMIT_SYNCOBJ_OUT) or waits for
 * (MSM_SUBMIT_SYNCOBJ_IN), and that the CPU creates, resets, signals and waits on. The kernel has none, but it has one ring and
 * one global fence sequence, so a syncobj is just a state here: unsignaled, signaled, or pending on fence F. A submit's out
 * syncobjs become pending on its fence; its in syncobjs need nothing more than to be submitted already (the ring runs in order);
 * a CPU wait on a pending syncobj is WAIT_FENCE. drmGetCap still reports no DRM_CAP_SYNCOBJ, so Gallium freedreno never takes
 * this path (it uses syncobjs only for fence fds, which are not emulated); Turnip finds syncobjs by creating one.
 */
#define SOBJ_MAX 8192
enum { SOBJ_FREE, SOBJ_UNSIGNALED, SOBJ_SIGNALED, SOBJ_PENDING };
static struct { uint32_t state, fence; } g_sobj[SOBJ_MAX];     /* handle = index, 0 unused */
static uint32_t g_sobj_next = 1;
static pthread_mutex_t g_sobj_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_sobj_cv = PTHREAD_COND_INITIALIZER;      /* a syncobj got a fence or was signaled */

#define MSM_SUBMIT_SYNCOBJ_IN   0x08000000u
#define MSM_SUBMIT_SYNCOBJ_OUT  0x04000000u
#define DRM_SYNCOBJ_CREATE_SIGNALED            (1u << 0)
#define DRM_SYNCOBJ_WAIT_FLAGS_WAIT_ALL        (1u << 0)
#define DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT (1u << 1)

struct msm_submit_syncobj { uint32_t handle, flags; uint64_t point; };

static int
sobj_valid(uint32_t h)
{
	return h > 0 && h < SOBJ_MAX && g_sobj[h].state != SOBJ_FREE;
}

static int
sobj_err(int e)
{
	errno = e;
	return -e;
}

static int64_t
mono_ns(void)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return now.tv_sec * 1000000000ll + now.tv_nsec;
}

/* WAIT_FENCE on the global sequence until the absolute CLOCK_MONOTONIC deadline: 0, -ETIME or another -errno */
static int
fence_wait_abs(uint32_t fence, int64_t deadline)
{
	struct sweet_msm_wait_fence w;
	memset(&w, 0, sizeof(w));
	w.fence = fence;
	w.queueid = 0;
	int64_t left = deadline - mono_ns();
	if (left < 0) {
		left = 0;
	}
	/* sweet_call converts an absolute timeout to a relative one; hand it the absolute deadline */
	int64_t abs = mono_ns() + left;
	w.timeout.tv_sec = abs / 1000000000ll;
	w.timeout.tv_nsec = abs % 1000000000ll;
	int r = sweet_call(SWEET_GPU_SEL_WAIT_FENCE, &w, sizeof(w));
	return r == -ETIMEDOUT ? -ETIME : r;
}

EXPORT int
drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle)
{
	(void)fd;
	pthread_mutex_lock(&g_sobj_lock);
	for (uint32_t n = 0; n < SOBJ_MAX - 1; n++) {
		uint32_t h = g_sobj_next;
		g_sobj_next = g_sobj_next + 1 < SOBJ_MAX ? g_sobj_next + 1 : 1;
		if (g_sobj[h].state == SOBJ_FREE) {
			g_sobj[h].state = (flags & DRM_SYNCOBJ_CREATE_SIGNALED) ? SOBJ_SIGNALED : SOBJ_UNSIGNALED;
			g_sobj[h].fence = 0;
			*handle = h;
			pthread_mutex_unlock(&g_sobj_lock);
			return 0;
		}
	}
	pthread_mutex_unlock(&g_sobj_lock);
	return sobj_err(ENOMEM);
}

EXPORT int
drmSyncobjDestroy(int fd, uint32_t handle)
{
	(void)fd;
	pthread_mutex_lock(&g_sobj_lock);
	int ok = sobj_valid(handle);
	if (ok) {
		g_sobj[handle].state = SOBJ_FREE;
	}
	pthread_mutex_unlock(&g_sobj_lock);
	return ok ? 0 : sobj_err(EINVAL);
}

static int
sobj_set(const uint32_t *h, uint32_t n, uint32_t state)
{
	pthread_mutex_lock(&g_sobj_lock);
	for (uint32_t i = 0; i < n; i++) {
		if (!sobj_valid(h[i])) {
			pthread_mutex_unlock(&g_sobj_lock);
			return sobj_err(EINVAL);
		}
	}
	for (uint32_t i = 0; i < n; i++) {
		g_sobj[h[i]].state = state;
		g_sobj[h[i]].fence = 0;
	}
	pthread_cond_broadcast(&g_sobj_cv);
	pthread_mutex_unlock(&g_sobj_lock);
	return 0;
}

EXPORT int
drmSyncobjReset(int fd, const uint32_t *h, uint32_t n)
{
	(void)fd;
	return sobj_set(h, n, SOBJ_UNSIGNALED);
}

EXPORT int
drmSyncobjSignal(int fd, const uint32_t *h, uint32_t n)
{
	(void)fd;
	return sobj_set(h, n, SOBJ_SIGNALED);
}

/* Wait until syncobj h is signaled (0), the deadline passes (-ETIME), or it is unsignaled with no fence and the caller does not
 * wait for submission (-EINVAL). Called and returns with g_sobj_lock held. */
static int
sobj_wait_one(uint32_t h, int64_t deadline, uint32_t flags)
{
	for (;;) {
		if (!sobj_valid(h)) {
			return -EINVAL;
		}
		if (g_sobj[h].state == SOBJ_SIGNALED) {
			return 0;
		}
		if (g_sobj[h].state == SOBJ_PENDING) {
			uint32_t f = g_sobj[h].fence;
			pthread_mutex_unlock(&g_sobj_lock);
			int r = fence_wait_abs(f, deadline);
			pthread_mutex_lock(&g_sobj_lock);
			if (r) {
				return r;
			}
			if (sobj_valid(h) && g_sobj[h].state == SOBJ_PENDING && g_sobj[h].fence == f) {
				g_sobj[h].state = SOBJ_SIGNALED;
			}
			continue;
		}
		if (!(flags & DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT)) {
			return -EINVAL;
		}
		int64_t left = deadline - mono_ns();
		if (left <= 0) {
			return -ETIME;
		}
		struct timespec rel = { .tv_sec = left / 1000000000ll, .tv_nsec = left % 1000000000ll };
		if (rel.tv_sec > 3600) {
			rel.tv_sec = 3600;
		}
		pthread_cond_timedwait_relative_np(&g_sobj_cv, &g_sobj_lock, &rel);
	}
}

/* Is h signaled now? A pending fence is polled (0 timeout). Called with g_sobj_lock held. */
static int
sobj_poll_one(uint32_t h)
{
	if (g_sobj[h].state == SOBJ_SIGNALED) {
		return 1;
	}
	if (g_sobj[h].state != SOBJ_PENDING) {
		return 0;
	}
	return sobj_wait_one(h, 0, 0) == 0;
}

EXPORT int
drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles, int64_t timeout_nsec, unsigned flags, uint32_t *first_signaled)
{
	(void)fd;
	int r = 0;

	pthread_mutex_lock(&g_sobj_lock);
	for (unsigned i = 0; i < num_handles; i++) {
		if (!sobj_valid(handles[i])) {
			pthread_mutex_unlock(&g_sobj_lock);
			return sobj_err(EINVAL);
		}
	}
	if (flags & DRM_SYNCOBJ_WAIT_FLAGS_WAIT_ALL || num_handles == 1) {
		for (unsigned i = 0; i < num_handles && r == 0; i++) {
			r = sobj_wait_one(handles[i], timeout_nsec, flags);
		}
		if (r == 0 && first_signaled) {
			*first_signaled = 0;
		}
	} else {
		/* any: poll every 100 us (rare in Turnip: vkWaitForFences with waitAll = false) */
		for (;;) {
			int found = -1, all_unsubmitted = 1;
			for (unsigned i = 0; i < num_handles && found < 0; i++) {
				if (sobj_poll_one(handles[i])) {
					found = (int)i;
				}
				if (g_sobj[handles[i]].state != SOBJ_UNSIGNALED) {
					all_unsubmitted = 0;
				}
			}
			if (found >= 0) {
				if (first_signaled) {
					*first_signaled = (uint32_t)found;
				}
				break;
			}
			if (all_unsubmitted && !(flags & DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT)) {
				r = -EINVAL;
				break;
			}
			if (mono_ns() >= timeout_nsec) {
				r = -ETIME;
				break;
			}
			struct timespec rel = { 0, 100000 };
			pthread_cond_timedwait_relative_np(&g_sobj_cv, &g_sobj_lock, &rel);
		}
	}
	pthread_mutex_unlock(&g_sobj_lock);
	return r ? sobj_err(-r) : 0;
}

/* Timelines, transfers and fds are not emulated (no DRM_CAP_SYNCOBJ_TIMELINE: Turnip emulates timelines on binary syncobjs). */
EXPORT int drmSyncobjTimelineSignal(int fd, const uint32_t *h, uint64_t *p, uint32_t n) { (void)fd; (void)h; (void)p; (void)n; return sobj_err(ENOSYS); }
EXPORT int drmSyncobjTimelineWait(int fd, uint32_t *h, uint64_t *p, unsigned n, int64_t t, unsigned f, uint32_t *first) { (void)fd; (void)h; (void)p; (void)n; (void)t; (void)f; (void)first; return sobj_err(ENOSYS); }
EXPORT int drmSyncobjQuery(int fd, uint32_t *h, uint64_t *p, uint32_t n) { (void)fd; (void)h; (void)p; (void)n; return sobj_err(ENOSYS); }
EXPORT int drmSyncobjQuery2(int fd, uint32_t *h, uint64_t *p, uint32_t n, uint32_t f) { (void)fd; (void)h; (void)p; (void)n; (void)f; return sobj_err(ENOSYS); }
EXPORT int drmSyncobjTransfer(int fd, uint32_t dh, uint64_t dp, uint32_t sh, uint64_t sp, uint32_t f) { (void)fd; (void)dh; (void)dp; (void)sh; (void)sp; (void)f; return sobj_err(ENOSYS); }
EXPORT int drmSyncobjHandleToFD(int fd, uint32_t handle, int *obj_fd) { (void)fd; (void)handle; (void)obj_fd; return sobj_err(ENOSYS); }
EXPORT int drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle) { (void)fd; (void)obj_fd; (void)handle; return sobj_err(ENOSYS); }
EXPORT int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd) { (void)fd; (void)handle; (void)sync_file_fd; return sobj_err(ENOSYS); }
EXPORT int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd) { (void)fd; (void)handle; (void)sync_file_fd; return sobj_err(ENOSYS); }

/*
 * GEM_SUBMIT: the kernel takes no syncobjs (and at least one command), so they are taken off here. In syncobjs must already be
 * signaled or pending (the ring is in order); out syncobjs become pending on the submit's fence. A submit with no command (Turnip
 * signals semaphores that way) is not sent: its fence is the last submitted one.
 */
static int
sweet_submit(void *data, unsigned long size)
{
	struct sweet_msm_gem_submit *req = data;
	const struct msm_submit_syncobj *in = NULL, *out = NULL;
	uint32_t nin = 0, nout = 0, stride = 0;
	int r;

	if (size < sizeof(*req)) {
		return -EINVAL;
	}
	if (req->flags & (MSM_SUBMIT_SYNCOBJ_IN | MSM_SUBMIT_SYNCOBJ_OUT)) {
		stride = req->syncobj_stride ? req->syncobj_stride : sizeof(struct msm_submit_syncobj);
		if (req->flags & MSM_SUBMIT_SYNCOBJ_IN) {
			in = (const void *)(uintptr_t)req->in_syncobjs;
			nin = req->nr_in_syncobjs;
		}
		if (req->flags & MSM_SUBMIT_SYNCOBJ_OUT) {
			out = (const void *)(uintptr_t)req->out_syncobjs;
			nout = req->nr_out_syncobjs;
		}
	}
	pthread_mutex_lock(&g_sobj_lock);
	for (uint32_t i = 0; i < nin; i++) {
		uint32_t h = ((const struct msm_submit_syncobj *)((const uint8_t *)in + i * stride))->handle;
		if (!sobj_valid(h) || g_sobj[h].state == SOBJ_UNSIGNALED) {
			pthread_mutex_unlock(&g_sobj_lock);
			return -EINVAL;   /* what msm answers for a syncobj with no fence */
		}
	}
	for (uint32_t i = 0; i < nout; i++) {
		if (!sobj_valid(((const struct msm_submit_syncobj *)((const uint8_t *)out + i * stride))->handle)) {
			pthread_mutex_unlock(&g_sobj_lock);
			return -EINVAL;
		}
	}
	pthread_mutex_unlock(&g_sobj_lock);

	struct sweet_msm_gem_submit k = *req;
	k.flags &= ~(MSM_SUBMIT_SYNCOBJ_IN | MSM_SUBMIT_SYNCOBJ_OUT);
	k.in_syncobjs = k.out_syncobjs = 0;
	k.nr_in_syncobjs = k.nr_out_syncobjs = k.syncobj_stride = 0;
	if (k.nr_cmds == 0) {
		struct sweet_gpu_info info;
		memset(&info, 0, sizeof(info));
		r = sweet_call(SWEET_GPU_SEL_INFO, &info, sizeof(info));
		k.fence = info.last_fence;
		k.fence_fd = -1;
	} else {
		r = sweet_call(SWEET_GPU_SEL_GEM_SUBMIT, &k, sizeof(k));
	}
	if (r) {
		return r;
	}
	req->fence = k.fence;
	req->fence_fd = k.fence_fd;
	if (nout) {
		pthread_mutex_lock(&g_sobj_lock);
		for (uint32_t i = 0; i < nout; i++) {
			uint32_t h = ((const struct msm_submit_syncobj *)((const uint8_t *)out + i * stride))->handle;
			if (sobj_valid(h)) {
				g_sobj[h].state = k.fence ? SOBJ_PENDING : SOBJ_SIGNALED;
				g_sobj[h].fence = k.fence;
			}
		}
		pthread_cond_broadcast(&g_sobj_cv);
		pthread_mutex_unlock(&g_sobj_lock);
	}
	return 0;
}

/* ---- device enumeration (Vulkan's drmGetDevices2): one platform device whose render node is /dev/null ---- */

#define DRM_NODE_PRIMARY 0
#define DRM_NODE_RENDER  2
#define DRM_NODE_MAX     3
#define DRM_BUS_PLATFORM 2

typedef struct { char fullname[512]; } drmPlatformBusInfo;
typedef struct { char **compatible; } drmPlatformDeviceInfo;
typedef struct _drmDevice {
	char **nodes;
	int available_nodes;
	int bustype;
	union { drmPlatformBusInfo *platform; void *any; } businfo;
	union { drmPlatformDeviceInfo *platform; void *any; } deviceinfo;
} drmDevice, *drmDevicePtr;

static drmDevicePtr
sweet_device(void)
{
	struct blob {
		drmDevice dev;
		char *nodes[DRM_NODE_MAX];
		drmPlatformBusInfo bus;
		drmPlatformDeviceInfo info;
		char *compat[2];
	} *b = calloc(1, sizeof(*b));
	if (!b) {
		return NULL;
	}
	b->nodes[DRM_NODE_PRIMARY] = "";              /* no primary node: stat() fails, no KMS */
	b->nodes[1] = "";
	b->nodes[DRM_NODE_RENDER] = "/dev/null";      /* every /dev/null fd is THE connection (is_ours) */
	b->dev.nodes = b->nodes;
	b->dev.available_nodes = 1 << DRM_NODE_RENDER;
	b->dev.bustype = DRM_BUS_PLATFORM;
	snprintf(b->bus.fullname, sizeof(b->bus.fullname), "/soc/gpu@5000000");
	b->compat[0] = "qcom,adreno-630.2";
	b->info.compatible = b->compat;
	b->dev.businfo.platform = &b->bus;
	b->dev.deviceinfo.platform = &b->info;
	return &b->dev;
}

EXPORT int
drmGetDevices2(uint32_t flags, drmDevicePtr devices[], int max_devices)
{
	(void)flags;
	if (!connect_once()) {
		return 0;
	}
	if (devices == NULL) {
		return 1;
	}
	if (max_devices < 1) {
		return 0;
	}
	devices[0] = sweet_device();
	return devices[0] ? 1 : -ENOMEM;
}

EXPORT int
drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device)
{
	(void)flags;
	if (!is_ours(fd) && !connect_once()) {
		return -ENODEV;
	}
	*device = sweet_device();
	return *device ? 0 : -ENOMEM;
}

EXPORT int
drmGetDevice(int fd, drmDevicePtr *device)
{
	return drmGetDevice2(fd, 0, device);
}

EXPORT void
drmFreeDevice(drmDevicePtr *device)
{
	if (device && *device) {
		free(*device);   /* one allocation (struct blob) */
		*device = NULL;
	}
}

EXPORT void
drmFreeDevices(drmDevicePtr devices[], int count)
{
	for (int i = 0; devices && i < count; i++) {
		drmFreeDevice(&devices[i]);
	}
}

EXPORT int
drmDevicesEqual(drmDevicePtr a, drmDevicePtr b)
{
	return a && b && a->bustype == b->bustype;
}

/* ---- mmap of a BO: offset = BO handle (GEM_INFO GET_OFFSET) ---- */

static void *sweet_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
static int sweet_munmap(void *addr, size_t len);

/* Direct entry points: the Mesa patch (freedreno_bo.c) calls these instead of relying on dyld interposing. */
EXPORT void *
sweet_drm_mmap(int fd, size_t len, uint64_t off)
{
	return sweet_mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)off);
}

static void *
sweet_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	mach_vm_address_t a = 0;
	mach_vm_size_t s = 0;

	if (!is_ours(fd)) {
		return mmap(addr, len, prot, flags, fd, off);
	}
	kern_return_t kr = IOConnectMapMemory64(g_conn, (uint32_t)off, mach_task_self(), &a, &s,
	    kIOMapAnywhere | kIOMapWriteCombineCache);
	if (kr != KERN_SUCCESS || s < len) {
		if (kr == KERN_SUCCESS) {
			IOConnectUnmapMemory64(g_conn, (uint32_t)off, mach_task_self(), a);
		}
		errno = kr == KERN_SUCCESS ? EINVAL : io_errno(kr);
		return MAP_FAILED;
	}
	pthread_mutex_lock(&g_lock);
	if (g_nmaps < sizeof(g_maps) / sizeof(g_maps[0])) {
		g_maps[g_nmaps].addr = (void *)(uintptr_t)a;
		g_maps[g_nmaps].handle = (uint32_t)off;
		g_maps[g_nmaps].len = len;
		g_nmaps++;
	}
	pthread_mutex_unlock(&g_lock);
	return (void *)(uintptr_t)a;
}

static int
sweet_munmap(void *addr, size_t len)
{
	int found = 0;
	uint32_t handle = 0;

	pthread_mutex_lock(&g_lock);
	for (unsigned i = 0; i < g_nmaps; i++) {
		if (g_maps[i].addr == addr) {
			handle = g_maps[i].handle;
			g_maps[i] = g_maps[--g_nmaps];
			found = 1;
			break;
		}
	}
	pthread_mutex_unlock(&g_lock);
	if (found) {
		return IOConnectUnmapMemory64(g_conn, handle, mach_task_self(), (mach_vm_address_t)(uintptr_t)addr) == KERN_SUCCESS ? 0 : -1;
	}
	return munmap(addr, len);
}

EXPORT int
sweet_drm_munmap(void *addr, size_t len)
{
	return sweet_munmap(addr, len);
}

/* Heartwood additions (not msm): IOSurface memory as a BO, cache maintenance, device info. */
EXPORT int
sweet_drm_surface_bo(int fd, struct sweet_gpu_surface_bo *io)
{
	static int minor = -1;   /* INFO.abi_minor: the 112-byte (minor 1) struct only when the kernel has it, the 48-byte V1 struct otherwise */
	(void)fd;
	if (minor < 0) {
		struct sweet_gpu_info inf;
		memset(&inf, 0, sizeof(inf));
		minor = sweet_call(SWEET_GPU_SEL_INFO, &inf, sizeof(inf)) == 0 ? (int)inf.abi_minor : 0;
		if (minor >= 1)
			g_sbo_size = minor >= 2 ? SWEET_GPU_SURFACE_BO_MINOR2_SIZE : SWEET_GPU_SURFACE_BO_MINOR1_SIZE;
	}
	return sweet_call(SWEET_GPU_SEL_SURFACE_BO, io, g_sbo_size);
}

/* Close a BO handle (SURFACE_BO makes one per surface; a writable alias is unmapped by the kernel at this point). */
EXPORT int
sweet_drm_gem_close(int fd, uint32_t handle)
{
	struct sweet_gem_close a = { .handle = handle };

	(void)fd;
	return sweet_call(SWEET_GPU_SEL_GEM_CLOSE, &a, sizeof(a));
}

EXPORT int
sweet_drm_bo_sync(int fd, uint32_t handle, uint64_t offset, uint64_t size)
{
	struct sweet_gpu_bo_sync a = { .handle = handle, .offset = offset, .size = size };

	(void)fd;
	return sweet_call(SWEET_GPU_SEL_BO_SYNC, &a, sizeof(a));
}

EXPORT int
sweet_drm_info(int fd, struct sweet_gpu_info *out)
{
	(void)fd;
	return sweet_call(SWEET_GPU_SEL_INFO, out, sizeof(*out));
}

struct interpose_tuple { const void *replacement, *replacee; };
__attribute__((used)) static const struct interpose_tuple interpose_mmap
    __attribute__((section("__DATA,__interpose"))) = { (const void *)sweet_mmap, (const void *)mmap };
__attribute__((used)) static const struct interpose_tuple interpose_munmap
    __attribute__((section("__DATA,__interpose"))) = { (const void *)sweet_munmap, (const void *)munmap };
