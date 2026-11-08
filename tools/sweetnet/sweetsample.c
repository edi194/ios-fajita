/*
 * sweetsample PID|NAME [SECONDS] [HZ]: a CPU profile of one process over SSH (iOS has no sample/spindump here).
 * At HZ ticks per second (default 500) for SECONDS (default 3) every thread of the process that is RUNNING is
 * suspended, its pc and a frame-pointer walk (up to 24 frames) are read, and it is resumed; threads that are waiting
 * are not counted, so the counts are CPU time. Identical stacks are aggregated here (the USB link stalls on replies
 * over ~130 KB). Output, one stack per line, most frequent first:
 *   COUNT THREAD-NAME FRAME...       FRAME = d:0xADDR (unslid shared-cache address, for dsctools/symb.py SLIDE=0)
 *                                    or IMAGE+0xOFF (an image outside the cache) or ?:0xADDR
 * First lines: '# ' header with the totals and the per-thread sample counts.
 * iOS 18, arm64e + pacstrip (tools/sweetnet/build.sh); entitlements: task_for_pid-allow (sample.entitlements).
 */
#include <mach/mach.h>
#include <mach-o/dyld_images.h>
#include <sys/sysctl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

#define MAXF 24
#define MAXIMG 2048
#define ADDR(x) ((uint64_t)(x) & 0x0000000FFFFFFFFFull)

struct img { uint64_t base; char name[64]; };
static struct img imgs[MAXIMG];
static int nimg;
static uint64_t cache_slide, cache_base;

struct stk { uint64_t h; unsigned count; char thread[32]; int n; uint64_t f[MAXF]; struct stk *next; };
#define NB 4096
static struct stk *bucket[NB];
static unsigned total;

struct thr { uint64_t id; char name[32]; unsigned count; };
static struct thr thrs[256];
static int nthr;

static int
rd(task_t t, uint64_t a, void *buf, size_t n)
{
	vm_size_t got = 0;
	return vm_read_overwrite(t, (vm_address_t)a, n, (vm_address_t)buf, &got) == KERN_SUCCESS && got == n ? 0 : -1;
}

static pid_t
find_pid(const char *s)
{
	char *end;
	long v = strtol(s, &end, 10);
	if (*end == 0) return (pid_t)v;
	int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
	size_t len = 0;
	if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0) return -1;
	struct kinfo_proc *kp = malloc(len);
	if (sysctl(mib, 3, kp, &len, NULL, 0) != 0) { free(kp); return -1; }
	pid_t pid = -1;
	for (size_t i = 0; i < len / sizeof(*kp); i++)
		if (strncmp(kp[i].kp_proc.p_comm, s, MAXCOMLEN) == 0) { pid = kp[i].kp_proc.p_pid; break; }
	free(kp);
	return pid;
}

static void
load_images(task_t t)
{
	struct task_dyld_info di;
	mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
	if (task_info(t, TASK_DYLD_INFO, (task_info_t)&di, &cnt) != KERN_SUCCESS) return;
	struct dyld_all_image_infos aii;
	if (rd(t, di.all_image_info_addr, &aii, sizeof(aii))) return;
	cache_slide = aii.sharedCacheSlide;
	cache_base = aii.sharedCacheBaseAddress;
	uint32_t n = aii.infoArrayCount < MAXIMG ? aii.infoArrayCount : MAXIMG;
	struct dyld_image_info *arr = calloc(n, sizeof(*arr));
	if (rd(t, (uint64_t)aii.infoArray, arr, n * sizeof(*arr))) { free(arr); return; }
	for (uint32_t i = 0; i < n; i++) {
		uint64_t base = (uint64_t)arr[i].imageLoadAddress;
		if (cache_base && base >= cache_base && base < cache_base + 0x200000000ull) continue;   /* cache images: by address */
		char path[512] = { 0 };
		rd(t, (uint64_t)arr[i].imageFilePath, path, sizeof(path) - 1);
		const char *b = strrchr(path, '/');
		imgs[nimg].base = base;
		snprintf(imgs[nimg].name, sizeof(imgs[nimg].name), "%s", b ? b + 1 : path);
		nimg++;
	}
	free(arr);
}

static void
fmt_frame(uint64_t a, char *out, size_t n)
{
	if (cache_base && a >= cache_base && a < cache_base + 0x200000000ull) {
		snprintf(out, n, "d:0x%llx", (unsigned long long)(a - cache_slide));
		return;
	}
	int best = -1;
	for (int i = 0; i < nimg; i++)
		if (imgs[i].base <= a && (best < 0 || imgs[i].base > imgs[best].base)) best = i;
	if (best >= 0 && a - imgs[best].base < 0x10000000ull)
		snprintf(out, n, "%s+0x%llx", imgs[best].name, (unsigned long long)(a - imgs[best].base));
	else
		snprintf(out, n, "?:0x%llx", (unsigned long long)a);
}

static void
record(const char *thread, const uint64_t *f, int n)
{
	uint64_t h = 1469598103934665603ull;
	for (const char *c = thread; *c; c++) h = (h ^ (uint8_t)*c) * 1099511628211ull;
	for (int i = 0; i < n; i++) h = (h ^ f[i]) * 1099511628211ull;
	struct stk **b = &bucket[h % NB];
	for (struct stk *s = *b; s; s = s->next)
		if (s->h == h && s->n == n && !memcmp(s->f, f, n * sizeof(*f)) && !strcmp(s->thread, thread)) { s->count++; return; }
	struct stk *s = calloc(1, sizeof(*s));
	s->h = h; s->count = 1; s->n = n;
	memcpy(s->f, f, n * sizeof(*f));
	snprintf(s->thread, sizeof(s->thread), "%s", thread);
	s->next = *b; *b = s;
}

static int
by_count(const void *a, const void *b)
{
	const struct stk *x = *(struct stk *const *)a, *y = *(struct stk *const *)b;
	return x->count < y->count ? 1 : x->count > y->count ? -1 : 0;
}

static int all_threads;

int
main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: sweetsample PID|NAME [SECONDS] [HZ]\n"); return 2; }
	pid_t pid = find_pid(argv[1]);
	double secs = argc > 2 ? atof(argv[2]) : 3;
	int hz = argc > 3 ? atoi(argv[3]) : 500;
	all_threads = getenv("SWEETSAMPLE_ALL") && getenv("SWEETSAMPLE_ALL")[0] == '1';
	if (pid <= 0) { fprintf(stderr, "sweetsample: no process %s\n", argv[1]); return 1; }
	task_t task;
	kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
	if (kr != KERN_SUCCESS) { fprintf(stderr, "sweetsample: task_for_pid(%d): %s\n", pid, mach_error_string(kr)); return 1; }
	load_images(task);

	struct timespec t0, now;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	unsigned ticks = 0;
	useconds_t period = (useconds_t)(1000000 / (hz > 0 ? hz : 500));
	for (;;) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		if ((now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9 >= secs) break;
		ticks++;
		thread_act_array_t th;
		mach_msg_type_number_t nth;
		if (task_threads(task, &th, &nth) != KERN_SUCCESS) break;
		for (mach_msg_type_number_t i = 0; i < nth; i++) {
			thread_basic_info_data_t bi;
			mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
			/* SWEETSAMPLE_ALL=1: every thread, waiting ones too (where a hung process is blocked) */
			if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c) != KERN_SUCCESS ||
			    (!all_threads && bi.run_state != TH_STATE_RUNNING)) {
				mach_port_deallocate(mach_task_self(), th[i]);
				continue;
			}
			thread_identifier_info_data_t ii;
			c = THREAD_IDENTIFIER_INFO_COUNT;
			uint64_t tid = thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c) == KERN_SUCCESS ? ii.thread_id : 0;
			char name[32] = "?";
			thread_extended_info_data_t ei;
			c = THREAD_EXTENDED_INFO_COUNT;
			if (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &c) == KERN_SUCCESS && ei.pth_name[0])
				snprintf(name, sizeof(name), "%s", ei.pth_name);
			else
				snprintf(name, sizeof(name), "t%llx", (unsigned long long)tid);
			for (char *p = name; *p; p++) if (*p == ' ') *p = '_';
			uint64_t f[MAXF];
			int n = 0;
			if (thread_suspend(th[i]) == KERN_SUCCESS) {
				arm_thread_state64_t st;
				c = ARM_THREAD_STATE64_COUNT;
				if (thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &c) == KERN_SUCCESS) {
					f[n++] = ADDR(arm_thread_state64_get_pc(st));
					uint64_t lr = ADDR(arm_thread_state64_get_lr(st));
					uint64_t fp = ADDR(arm_thread_state64_get_fp(st));
					if (lr) f[n++] = lr;     /* a leaf without a frame yet: its caller is only in lr */
					while (fp && n < MAXF) {
						uint64_t rec[2];
						if (rd(task, fp, rec, sizeof(rec))) break;
						uint64_t ret = ADDR(rec[1]);
						if (!ret) break;
						if (ret != f[n - 1]) f[n++] = ret;
						if (ADDR(rec[0]) <= fp) break;
						fp = ADDR(rec[0]);
					}
				}
				thread_resume(th[i]);
			}
			mach_port_deallocate(mach_task_self(), th[i]);
			if (!n) continue;
			record(name, f, n);
			total++;
			int k;
			for (k = 0; k < nthr && strcmp(thrs[k].name, name); k++) {}
			if (k == nthr && nthr < 256) { snprintf(thrs[nthr].name, sizeof(thrs[nthr].name), "%s", name); nthr++; }
			if (k < 256) thrs[k].count++;
		}
		vm_deallocate(mach_task_self(), (vm_address_t)th, nth * sizeof(*th));
		usleep(period);
	}

	printf("# pid %d ticks %u running-samples %u (%.1f%% of one CPU) cache_slide 0x%llx\n", pid, ticks, total,
	       ticks ? 100.0 * total / ticks : 0, (unsigned long long)cache_slide);
	for (int k = 0; k < nthr; k++) printf("# thread %s %u\n", thrs[k].name, thrs[k].count);
	unsigned ns = 0;
	for (int b = 0; b < NB; b++) for (struct stk *s = bucket[b]; s; s = s->next) ns++;
	struct stk **all = malloc(ns * sizeof(*all));
	ns = 0;
	for (int b = 0; b < NB; b++) for (struct stk *s = bucket[b]; s; s = s->next) all[ns++] = s;
	qsort(all, ns, sizeof(*all), by_count);
	for (unsigned i = 0; i < ns; i++) {
		printf("%u %s", all[i]->count, all[i]->thread);
		for (int j = 0; j < all[i]->n; j++) {
			char fb[96];
			fmt_frame(all[i]->f[j], fb, sizeof(fb));
			printf(" %s", fb);
		}
		putchar('\n');
	}
	return 0;
}
