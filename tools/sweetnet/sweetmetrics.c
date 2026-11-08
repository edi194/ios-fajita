/*
 * sweetmetrics: print ONE JSON object with the phone's live device metrics (CPU per cluster, GPU,
 * renderer, battery, thermal). Read-only: it never writes a sysctl, never opens the GPU user client
 * unless asked (--gpu-info), and takes about 0.3 s (the CPU load window).
 * The JSON contract is docs/BERGAMOTA_METRICS.md (schema 1). Bergamota polls it over SSH every ~2 s.
 *
 * Sources (every one is optional, a missing one gives null/"unknown" and a line in "errors"):
 *   CPU freq   sysctl kern.sweet_cpufreq (xnu patch 0190, cpufreq branch); absent = fixed by the bootloader
 *   CPU load   host_processor_info(PROCESSOR_CPU_LOAD_INFO), two samples 250 ms apart
 *   GPU        sysctl kern.sweet_gpu (GPU DCVS governor, gpu-kernel branch; not there yet), and with
 *              --gpu-info the INFO selector (0x70) of the SweetAdreno630 user client (sweet_adreno_abi.h)
 *   renderer   boot-arg bglrender / marker /private/var/run/bglrender (bgl-launch.c), backboardd's
 *              DYLD_INSERT_LIBRARIES, the IORegistry clients of SweetAdreno630 (IOUserClientCreator),
 *              the last lines of /private/var/tmp/bgl-backboardd.log
 *   battery    IOPSCopyPowerSourcesInfo (as sweetps) + the IOPMPowerSource registry entry (mA, mV)
 *
 * Build: tools/sweetnet/build.sh (arm64e, then `renegade strip --sign`). Usage: sweetmetrics
 * [--gpu-info] [--no-load] [--interval MS]. A test hook for the parsers: --parse-cpufreq STRING and
 * --parse-gpu STRING print the parsed clusters / GPU object (no device access).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

#define SCHEMA 1
#define MAXCPU 16
#define MAXCL 4

/* ---- tiny JSON writer (one growing buffer) ---- */

static char *jb;
static size_t jlen, jcap;

static void
jput(const char *fmt, ...)
{
	va_list ap;
	char tmp[1024];
	va_start(ap, fmt);
	int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	if ((size_t)n >= sizeof(tmp)) {
		n = (int)sizeof(tmp) - 1;
	}
	if (jlen + (size_t)n + 1 > jcap) {
		jcap = (jlen + (size_t)n + 1) * 2;
		jb = realloc(jb, jcap);
		if (jb == NULL) {
			exit(1);
		}
	}
	memcpy(jb + jlen, tmp, (size_t)n);
	jlen += (size_t)n;
	jb[jlen] = 0;
}

static void
jstr(const char *s)
{
	jput("\"");
	for (; s && *s; s++) {
		unsigned char c = (unsigned char)*s;
		if (c == '"' || c == '\\') {
			jput("\\%c", c);
		} else if (c < 0x20 || c == 0x7f) {
			jput("\\u%04x", c);
		} else {
			jput("%c", c);
		}
	}
	jput("\"");
}

/* key + value helpers: first = emit a comma unless this is the first member of the object */
static int jfirst;
#define JOBJ_BEGIN() do { jput("{"); jfirst = 1; } while (0)
static void jkey(const char *k) { if (!jfirst) { jput(","); } jfirst = 0; jstr(k); jput(":"); }
static void jk_str(const char *k, const char *v) { jkey(k); if (v) { jstr(v); } else { jput("null"); } }
static void jk_int(const char *k, long long v) { jkey(k); jput("%lld", v); }
static void jk_num(const char *k, double v, int dec) { jkey(k); jput("%.*f", dec, v); }
static void jk_bool(const char *k, int v) { jkey(k); jput(v ? "true" : "false"); }
static void jk_null(const char *k) { jkey(k); jput("null"); }
/* optional numbers: negative sentinel = null */
static void jk_oint(const char *k, long long v) { if (v < 0) { jk_null(k); } else { jk_int(k, v); } }
static void jk_onum(const char *k, double v, int dec) { if (v < 0) { jk_null(k); } else { jk_num(k, v, dec); } }

static char errs[8][160];
static int nerr;
static void
note(const char *fmt, ...)
{
	va_list ap;
	if (nerr >= 8) {
		return;
	}
	va_start(ap, fmt);
	vsnprintf(errs[nerr++], sizeof(errs[0]), fmt, ap);
	va_end(ap);
}

/* ---- text helpers ---- */

/* number following `key` (word boundary before it; optional = : or spaces between); 1 if found */
static int
kv_num(const char *s, const char *key, double *out)
{
	size_t kl = strlen(key);
	for (const char *p = s; (p = strcasestr(p, key)) != NULL; p += kl) {
		if (p != s && (isalnum((unsigned char)p[-1]) || p[-1] == '_')) {
			continue;
		}
		const char *q = p + kl;
		if (isalnum((unsigned char)*q)) {
			continue;
		}
		while (*q == ' ' || *q == '=' || *q == ':') {
			q++;
		}
		if (*q == '-' || isdigit((unsigned char)*q)) {
			*out = strtod(q, NULL);
			return 1;
		}
	}
	return 0;
}

/* word following `key` (copied, up to 31 chars of [A-Za-z0-9_.-]) */
static int
kv_word(const char *s, const char *key, char *out, size_t n)
{
	size_t kl = strlen(key);
	for (const char *p = s; (p = strcasestr(p, key)) != NULL; p += kl) {
		if (p != s && (isalnum((unsigned char)p[-1]) || p[-1] == '_')) {
			continue;
		}
		const char *q = p + kl;
		if (isalnum((unsigned char)*q)) {
			continue;
		}
		while (*q == ' ' || *q == '=' || *q == ':') {
			q++;
		}
		size_t i = 0;
		while (*q && (isalnum((unsigned char)*q) || *q == '_' || *q == '.' || *q == '-') && i + 1 < n) {
			out[i++] = *q++;
		}
		out[i] = 0;
		if (i > 0) {
			return 1;
		}
	}
	return 0;
}

/* first "<digits> kHz" (digits directly before " kHz") */
static long
first_khz(const char *s)
{
	const char *p = strcasestr(s, "khz");
	while (p) {
		const char *e = p;
		while (e > s && e[-1] == ' ') {
			e--;
		}
		const char *b = e;
		while (b > s && isdigit((unsigned char)b[-1])) {
			b--;
		}
		if (b != e) {
			return strtol(b, NULL, 10);
		}
		p = strcasestr(p + 3, "khz");
	}
	return -1;
}

/* kHz value of key (min/max): unit-less numbers below 10000 are taken as MHz */
static long
kv_khz(const char *s, const char *key)
{
	double v;
	if (!kv_num(s, key, &v)) {
		return -1;
	}
	return (long)(v < 10000 ? v * 1000 : v);
}

/* `key=value` word of one line (value up to the next space/newline/NUL, truncated to n-1); 1 if found. The key must start a word. */
static int kvs_multi;       /* 1: kvs_get searches the whole text (kern.sweet_gpu may wrap), 0: only the first line (cpufreq clusters) */

static int
kvs_get(const char *line, const char *key, char *out, size_t n)
{
	size_t kl = strlen(key);
	for (const char *p = line; *p && (kvs_multi || *p != '\n'); p++) {
		if ((p == line || p[-1] == ' ' || p[-1] == '\n') && !strncmp(p, key, kl) && p[kl] == '=') {
			const char *q = p + kl + 1;
			size_t i = 0;
			while (*q && *q != ' ' && *q != '\n' && i + 1 < n) {
				out[i++] = *q++;
			}
			out[i] = 0;
			return 1;
		}
	}
	return 0;
}

static long
kvs_long(const char *line, const char *key, long dflt)
{
	char v[32];
	return kvs_get(line, key, v, sizeof(v)) && (isdigit((unsigned char)v[0]) || v[0] == '-') ? strtol(v, NULL, 10) : dflt;
}

/* sysctl string of any length (the v1 cpufreq string has the whole LUT and time-in-state), malloc'ed; NULL if absent */
static char *
sysctl_text(const char *name)
{
	size_t n = 0;
	if (sysctlbyname(name, NULL, &n, NULL, 0) != 0) {
		note("%s: %s", name, strerror(errno));
		return NULL;
	}
	n += 512;
	char *b = calloc(1, n + 1);
	if (!b || sysctlbyname(name, b, &n, NULL, 0) != 0) {
		note("%s: read failed: %s", name, strerror(errno));
		free(b);
		return NULL;
	}
	b[n] = 0;
	return b;
}

/* ---- CPU ---- */

struct cluster {
	int id;
	char name[16];
	char status[16];        /* the sysctl's word: applied | off | pending | skipped | ... */
	long cur_khz, min_khz, max_khz, req_khz;
	int state, nstates, cap_pct;
	char governor[32];
	int seen;
	double load;            /* mean of the cluster's CPUs, -1 unknown */
	/* v1 string extras (-1 / empty when not reported) */
	int idx, kload, changes;
	long cap_khz;
	char lut[400];          /* "a,b,c" kHz in index order */
};
static struct cluster cl[MAXCL];
static int ncl;
static char *cpu_raw;
static int ncpu_load;
static double cpu_load[MAXCPU];

/*
 * kern.sweet_cpufreq, today (patch 0190): "domain0 A55 applied: state 3/12 1209600 kHz (requested 3, 40%); domain1 A75 ..."
 * (also "domainN NAME off|pending|skipped"). Tolerant: segments split at ';' or newline; a segment starting with
 * domain|cluster|policy N; the first "<n> kHz" is the current frequency; "min"/"max" (kHz or MHz), "gov"/"governor"/"mode" words
 * and "N%" are picked up when a governor build prints them.
 */
static void
parse_cpufreq_legacy(const char *raw)
{
	char buf[512];
	snprintf(buf, sizeof(buf), "%s", raw);
	ncl = 0;
	char *save = NULL;
	for (char *seg = strtok_r(buf, ";\n", &save); seg && ncl < MAXCL; seg = strtok_r(NULL, ";\n", &save)) {
		while (*seg == ' ') {
			seg++;
		}
		unsigned id;
		char name[16] = "", status[16] = "";
		struct cluster *c = &cl[ncl];
		memset(c, 0, sizeof(*c));
		c->cur_khz = c->min_khz = c->max_khz = c->req_khz = -1;
		c->state = c->nstates = c->cap_pct = -1;
		c->idx = c->kload = c->changes = -1;
		c->cap_khz = -1;
		c->load = -1;
		int n = sscanf(seg, "domain%u %15s %15[a-z]", &id, name, status);
		if (n < 1) {
			n = sscanf(seg, "cluster%u %15s %15[a-z]", &id, name, status);
		}
		if (n < 1) {
			n = sscanf(seg, "policy%u %15s %15[a-z]", &id, name, status);
		}
		if (n < 1) {
			continue;
		}
		c->id = (int)id;
		snprintf(c->name, sizeof(c->name), "%s", n >= 2 ? name : (id ? "big" : "little"));
		snprintf(c->status, sizeof(c->status), "%s", n >= 3 ? status : "applied");
		c->seen = 1;
		const char *rest = strchr(seg, ':');
		rest = rest ? rest + 1 : seg;
		unsigned st, of;
		const char *sp = strcasestr(rest, "state ");
		if (sp && sscanf(sp, "state %u/%u", &st, &of) == 2) {
			c->state = (int)st;
			c->nstates = (int)of;
		}
		c->cur_khz = first_khz(rest);
		double v;
		const char *rq = strcasestr(rest, "requested ");
		if (rq && sscanf(rq, "requested %u", &st) == 1) {
			(void)st;       /* a LUT index, not a frequency: kept out of the contract */
		}
		const char *pc = strchr(rest, '%');
		if (pc) {
			const char *b = pc;
			while (b > rest && isdigit((unsigned char)b[-1])) {
				b--;
			}
			if (b != pc) {
				c->cap_pct = atoi(b);
			}
		}
		c->min_khz = kv_khz(rest, "min");
		c->max_khz = kv_khz(rest, "max");
		if (!kv_word(rest, "governor", c->governor, sizeof(c->governor)) &&
		    !kv_word(rest, "gov", c->governor, sizeof(c->governor))) {
			c->governor[0] = 0;
		}
		if (kv_num(rest, "cur", &v) && c->cur_khz < 0) {
			c->cur_khz = (long)(v < 10000 ? v * 1000 : v);
		}
		ncl++;
	}
}

/*
 * kern.sweet_cpufreq v1 (patch 0190, governor): lines separated by '\n', each a sequence of key=value words:
 *   sweet_cpufreq v1 mode=<gov|fixed|off> period_ms=N
 *   cluster0 name=A55 cpus=0-3 state=<applied|off|skipped|pending> mode=<gov|fixed|off> idx=I cur_khz=K min_khz=K max_khz=K
 *            cap_khz=K lut_n=N load=P changes=N lut_khz=a,b,.. tis_ms=khz:ms,..
 *   cluster1 ... (A75, cpus=4-7)
 * cur_khz/idx are 0 unless state=applied (then curKhz is null). The older "domainN NAME applied: state 3/12 1209600 kHz ..."
 * string (first 0190 version) goes through parse_cpufreq_legacy().
 */
static void
parse_cpufreq(const char *raw)
{
	if (strncmp(raw, "sweet_cpufreq", 13) != 0) {
		parse_cpufreq_legacy(raw);
		return;
	}
	ncl = 0;
	for (const char *ln = strchr(raw, '\n'); ln && ncl < MAXCL; ln = strchr(ln, '\n')) {
		ln++;
		unsigned id;
		if (sscanf(ln, "cluster%u ", &id) != 1) {
			continue;
		}
		struct cluster *c = &cl[ncl];
		memset(c, 0, sizeof(*c));
		char v[48];
		c->id = (int)id;
		snprintf(c->name, sizeof(c->name), "%s", kvs_get(ln, "name", v, sizeof(v)) ? v : (id ? "A75" : "A55"));
		snprintf(c->status, sizeof(c->status), "%s", kvs_get(ln, "state", v, sizeof(v)) ? v : "unknown");
		char kmode[16] = "";
		kvs_get(ln, "mode", kmode, sizeof(kmode));
		int applied = !strcmp(c->status, "applied");
		c->cur_khz = applied ? kvs_long(ln, "cur_khz", -1) : -1;
		c->idx = applied ? (int)kvs_long(ln, "idx", -1) : -1;
		c->min_khz = kvs_long(ln, "min_khz", -1);
		c->max_khz = kvs_long(ln, "max_khz", -1);
		c->cap_khz = kvs_long(ln, "cap_khz", -1);
		c->nstates = (int)kvs_long(ln, "lut_n", -1);
		c->state = c->idx;
		c->kload = (int)kvs_long(ln, "load", -1);
		c->changes = (int)kvs_long(ln, "changes", -1);
		c->req_khz = -1;
		c->load = -1;
		c->cap_pct = -1;
		if (c->cap_khz > 0 && c->max_khz > 0) {
			c->cap_pct = (int)((c->cap_khz * 100 + c->max_khz / 2) / c->max_khz);
		}
		if (!kvs_get(ln, "lut_khz", c->lut, sizeof(c->lut))) {
			c->lut[0] = 0;
		}
		/* mode: the cluster's own mode word wins: gov -> governor (named "gov"), fixed -> static, off -> off */
		if (applied && !strcmp(kmode, "gov")) {
			snprintf(c->governor, sizeof(c->governor), "gov");
		} else if (applied && !strcmp(kmode, "fixed")) {
			snprintf(c->status, sizeof(c->status), "applied");      /* mode "static" below */
		} else if (!applied && !strcmp(kmode, "off") && !strcmp(c->status, "unknown")) {
			snprintf(c->status, sizeof(c->status), "off");
		}
		c->seen = 1;
		ncl++;
	}
}

static void
read_cpufreq(void)
{
	cpu_raw = sysctl_text("kern.sweet_cpufreq");
	if (!cpu_raw) {
		ncl = 0;
		return;
	}
	parse_cpufreq(cpu_raw);
	if (ncl == 0) {
		note("kern.sweet_cpufreq: unparsed: %.100s", cpu_raw);
	}
}

static int
sample_ticks(natural_t *ncpus, unsigned long long (*t)[4])
{
	processor_info_array_t info;
	mach_msg_type_number_t cnt;
	natural_t n;
	if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) != KERN_SUCCESS) {
		return -1;
	}
	if (n > MAXCPU) {
		n = MAXCPU;
	}
	for (natural_t i = 0; i < n; i++) {
		processor_cpu_load_info_data_t *l = (processor_cpu_load_info_data_t *)info + i;
		for (int s = 0; s < 4; s++) {
			t[i][s] = l->cpu_ticks[s];
		}
	}
	vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
	*ncpus = n;
	return 0;
}

static void
read_load(unsigned interval_ms)
{
	unsigned long long a[MAXCPU][4], b[MAXCPU][4];
	natural_t n1 = 0, n2 = 0;
	if (sample_ticks(&n1, a) != 0) {
		note("host_processor_info failed");
		return;
	}
	usleep(interval_ms * 1000);
	if (sample_ticks(&n2, b) != 0) {
		note("host_processor_info failed (2nd sample)");
		return;
	}
	ncpu_load = (int)(n1 < n2 ? n1 : n2);
	for (int i = 0; i < ncpu_load; i++) {
		unsigned long long tot = 0, idle = b[i][CPU_STATE_IDLE] - a[i][CPU_STATE_IDLE];
		for (int s = 0; s < 4; s++) {
			tot += b[i][s] - a[i][s];
		}
		cpu_load[i] = tot ? 100.0 * (double)(tot - idle) / (double)tot : 0.0;
	}
}

/* Cluster layout of the SDM845: A55 = CPU 0-3 (cluster 0), A75 = CPU 4-7 (cluster 1). */
static void
emit_cpu(void)
{
	jkey("cpu");
	JOBJ_BEGIN();
	jk_str("source", ncl ? "sysctl kern.sweet_cpufreq" : "none");
	int known = 0;
	for (int j = 0; j < ncl; j++) {
		known |= cl[j].cur_khz >= 0;
	}
	jk_bool("freqKnown", known);
	jkey("loadPct");
	jput("[");
	for (int i = 0; i < ncpu_load; i++) {
		jput("%s%.0f", i ? "," : "", cpu_load[i]);
	}
	jput("]");
	jkey("clusters");
	jput("[");
	int ids = ncl ? ncl : (ncpu_load > 4 ? 2 : 1);
	for (int k = 0; k < ids; k++) {
		struct cluster *c = NULL;
		for (int j = 0; j < ncl; j++) {
			if (cl[j].id == k) {
				c = &cl[j];
			}
		}
		jput("%s", k ? "," : "");
		int first = k * 4;
		double sum = 0;
		int cnt = 0;
		for (int i = first; i < first + 4 && i < ncpu_load; i++) {
			sum += cpu_load[i];
			cnt++;
		}
		JOBJ_BEGIN();
		jk_int("id", k);
		jk_str("name", c ? c->name : (k ? "A75" : "A55"));
		jkey("cpus");
		jput("[");
		for (int i = first, w = 0; i < first + 4; i++) {
			if (ncpu_load && i >= ncpu_load) {
				break;
			}
			jput("%s%d", w++ ? "," : "", i);
		}
		jput("]");
		jk_oint("curKhz", c ? c->cur_khz : -1);
		jk_oint("minKhz", c ? c->min_khz : -1);
		jk_oint("maxKhz", c ? c->max_khz : -1);
		/* mode: unknown (sysctl absent) | off | pending | skipped | static (a fixed cap) | governor (a named governor) */
		const char *mode = "unknown";
		if (c) {
			if (c->governor[0]) {
				mode = "governor";
			} else if (!strcmp(c->status, "applied")) {
				mode = "static";
			} else if (!strcmp(c->status, "off") || !strcmp(c->status, "pending") || !strcmp(c->status, "skipped")) {
				mode = c->status;
			} else {
				mode = "unknown";
			}
		}
		jk_str("mode", mode);
		jk_str("governor", c && c->governor[0] ? c->governor : NULL);
		jk_oint("capPercent", c ? c->cap_pct : -1);
		jk_oint("perfState", c ? c->state : -1);
		jk_oint("perfStates", c ? c->nstates : -1);
		jk_oint("capKhz", c ? c->cap_khz : -1);
		jk_oint("kernelLoadPct", c ? c->kload : -1);
		jk_oint("changes", c ? c->changes : -1);
		jkey("lutKhz");
		if (c && c->lut[0]) {
			jput("[%s]", c->lut);
		} else {
			jput("null");
		}
		jk_onum("loadPct", cnt ? sum / cnt : -1, 0);
		jput("}");
	}
	jput("]");
	jput("}");
}

/* ---- GPU ---- */

struct gpu {
	int have_sysctl;
	int level, nlevels;
	double mhz, min_mhz, max_mhz, busy;
	char state[16];
	int abi_ok, info_ready, info_lost;
	int service_present;
	int info_tried;
	char freq_mode[8];
	char pids[100];
	long suspends, recoveries, hangs;
};
static struct gpu gpu = { .level = -1, .nlevels = -1, .mhz = -1, .min_mhz = -1, .max_mhz = -1, .busy = -1, .suspends = -1, .recoveries = -1, .hangs = -1 };

/*
 * kern.sweet_gpu (not shipped yet): tolerant "key value" text, e.g.
 *   "state on level 3/8 freq 427 MHz busy 41% min 257 max 710"
 * level N or N/M, freq|mhz|clock N, busy|load|util N, min/max N (MHz), and a state word:
 * on | active | slumber | idle | off | lost.
 */
static void parse_gpu_legacy(const char *raw);

/*
 * kern.sweet_gpu (patch 0186, docs/GPU_KERNEL.md section 11): key=value words, e.g.
 *   state=on level=3 mhz=414 max_level=7 freq=gov busy_pct=42 clients=2 pids=123,456 submitted=1030 completed=1030
 *   suspends=2 resumes=2 recoveries=0 hangs=0 idle_ms=2000 hwcg=1 total_ms=.. res_ms=slumber:61000,L1:0,..
 * (one or two lines). level/mhz are 0 in slumber; levels run 1..max_level (1 = 257 MHz, 7 = 710 MHz), so `levels` = max_level.
 * Anything without `state=` goes through the older tolerant parser.
 */
static const int gpu_mhz_tab[8] = { 0, 257, 342, 414, 520, 596, 675, 710 };

static void
parse_gpu(const char *raw)
{
	char w[64];
	if (!strstr(raw, "state=") || !strstr(raw, "max_level=")) {
		parse_gpu_legacy(raw);
		return;
	}
	gpu.have_sysctl = 1;
	kvs_multi = 1;
	if (kvs_get(raw, "state", w, sizeof(w))) {
		snprintf(gpu.state, sizeof(gpu.state), "%s", w);
	}
	gpu.level = (int)kvs_long(raw, "level", -1);
	long ml = kvs_long(raw, "max_level", -1);
	gpu.nlevels = (int)ml;
	long mhz = kvs_long(raw, "mhz", -1);
	gpu.mhz = mhz < 0 ? -1 : (double)mhz;
	gpu.min_mhz = gpu_mhz_tab[1];
	gpu.max_mhz = ml >= 1 && ml <= 7 ? gpu_mhz_tab[ml] : gpu_mhz_tab[7];
	long busy = kvs_long(raw, "busy_pct", -1);
	/* busy_pct is stale while slumbering and 0 unless freq=gov: report what the governor measured, 0 in slumber */
	gpu.busy = !strcmp(gpu.state, "slumber") ? 0 : (busy < 0 ? -1 : (double)busy);
	gpu.freq_mode[0] = 0;
	if (kvs_get(raw, "freq", w, sizeof(w))) {
		snprintf(gpu.freq_mode, sizeof(gpu.freq_mode), "%s", w);
	}
	gpu.pids[0] = 0;
	if (kvs_get(raw, "pids", w, sizeof(w)) && strcmp(w, "-") != 0) {
		size_t k = 0;
		for (const char *q = w; *q && k + 1 < sizeof(gpu.pids); q++) {      /* digits and commas only; the kernel cuts the list at 96 bytes */
			if (isdigit((unsigned char)*q) || (*q == ',' && k > 0)) {
				gpu.pids[k++] = *q;
			}
		}
		while (k > 0 && gpu.pids[k - 1] == ',') {
			k--;
		}
		gpu.pids[k] = 0;
	}
	gpu.suspends = kvs_long(raw, "suspends", -1);
	gpu.recoveries = kvs_long(raw, "recoveries", -1);
	gpu.hangs = kvs_long(raw, "hangs", -1);
	kvs_multi = 0;
}

static void
parse_gpu_legacy(const char *raw)
{
	double v;
	char w[32];
	gpu.have_sysctl = 1;
	const char *lv = strcasestr(raw, "level");
	if (lv) {
		unsigned a, b;
		const char *q = lv + 5;
		while (*q == ' ' || *q == '=' || *q == ':') {
			q++;
		}
		int n = sscanf(q, "%u/%u", &a, &b);
		if (n >= 1) {
			gpu.level = (int)a;
		}
		if (n == 2) {
			gpu.nlevels = (int)b;
		}
	}
	if (kv_num(raw, "freq", &v) || kv_num(raw, "mhz", &v) || kv_num(raw, "clock", &v)) {
		gpu.mhz = v > 100000 ? v / 1e6 : (v > 5000 ? v / 1e3 : v);       /* Hz | kHz | MHz */
	}
	if (kv_num(raw, "busy", &v) || kv_num(raw, "load", &v) || kv_num(raw, "util", &v)) {
		gpu.busy = v;
	}
	if (kv_num(raw, "min", &v)) {
		gpu.min_mhz = v > 5000 ? v / 1e3 : v;
	}
	if (kv_num(raw, "max", &v)) {
		gpu.max_mhz = v > 5000 ? v / 1e3 : v;
	}
	if (kv_word(raw, "state", w, sizeof(w))) {
		const char *s = !strcasecmp(w, "active") ? "on" : (!strcasecmp(w, "idle") ? "slumber" : w);
		if (!strcasecmp(s, "on") || !strcasecmp(s, "slumber") || !strcasecmp(s, "off") || !strcasecmp(s, "lost")) {
			snprintf(gpu.state, sizeof(gpu.state), "%s", s);
			for (char *p = gpu.state; *p; p++) {
				*p = (char)tolower((unsigned char)*p);
			}
		}
	}
}

struct client {
	int pid;
	char name[48];
};
static struct client clients[16];
static int nclients;
static int registry_ok;     /* the SweetAdreno630 service was found and its children read */

/* SweetAdreno630's open user clients: children of the service in the service plane, each with IOUserClientCreator = "pid N, name". */
static void
read_gpu_registry(int want_info)
{
	io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("SweetAdreno630"));
	if (svc == 0) {
		return;
	}
	gpu.service_present = 1;
	registry_ok = 1;
	io_iterator_t it = 0;
	if (IORegistryEntryGetChildIterator(svc, kIOServicePlane, &it) == KERN_SUCCESS) {
		io_object_t ch;
		while ((ch = IOIteratorNext(it)) != 0) {
			io_name_t cls = "";
			IOObjectGetClass(ch, cls);
			if (strstr(cls, "UserClient") != NULL && nclients < 16) {
				CFTypeRef c = IORegistryEntryCreateCFProperty(ch, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
				struct client *cc = &clients[nclients++];
				cc->pid = -1;
				snprintf(cc->name, sizeof(cc->name), "?");
				if (c && CFGetTypeID(c) == CFStringGetTypeID()) {
					char s[160];
					if (CFStringGetCString(c, s, sizeof(s), kCFStringEncodingUTF8)) {
						int pid;
						char nm[48] = "?";
						if (sscanf(s, "pid %d, %47[^\n]", &pid, nm) >= 1) {
							cc->pid = pid;
							snprintf(cc->name, sizeof(cc->name), "%s", nm);
						}
					}
				}
				if (c) {
					CFRelease(c);
				}
			}
			IOObjectRelease(ch);
		}
		IOObjectRelease(it);
	}
	if (want_info) {
		/* SWEET_GPU_SEL_INFO 0x70, struct sweet_gpu_info (xnu/gpu-abi/sweet_adreno_abi.h, ABI v1, 48 bytes) */
		struct { uint32_t abi, flags, gpu_id, chip_id; uint64_t va_start, va_size; uint32_t last_fence, reserved; } info;
		memset(&info, 0, sizeof(info));
		size_t sz = sizeof(info);
		io_connect_t conn = 0;
		gpu.info_tried = 1;
		kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
		if (kr == KERN_SUCCESS) {
			kr = IOConnectCallStructMethod(conn, 0x70, NULL, 0, &info, &sz);
			if (kr == KERN_SUCCESS) {
				gpu.abi_ok = info.abi == 1;
				gpu.info_ready = info.flags & 1;
				gpu.info_lost = (info.flags >> 1) & 1;
			} else {
				note("SweetAdreno630 INFO: 0x%x", kr);
			}
			IOServiceClose(conn);
		} else {
			note("SweetAdreno630 open: 0x%x", kr);
		}
	}
	IOObjectRelease(svc);
}

static void
read_gpu(int want_info)
{
	char *raw = sysctl_text("kern.sweet_gpu");
	if (raw) {
		parse_gpu(raw);
		free(raw);
	}
	read_gpu_registry(want_info);
	if (!gpu.state[0] && gpu.info_tried && gpu.abi_ok) {
		/* INFO only knows ready / lost: "on" cannot be told from "slumber" without the DCVS interface */
		snprintf(gpu.state, sizeof(gpu.state), "%s", gpu.info_lost ? "lost" : (gpu.info_ready ? "on" : "off"));
	}
	if (!gpu.have_sysctl) {
		note("kern.sweet_gpu: absent (GPU DCVS interface not in this kernel)");
	}
}

static void
emit_gpu(void)
{
	jkey("gpu");
	JOBJ_BEGIN();
	jk_bool("present", gpu.service_present);
	jk_str("source", gpu.have_sysctl ? "sysctl kern.sweet_gpu" : (gpu.info_tried && gpu.abi_ok ? "SweetAdreno630 INFO" : "none"));
	/* state: on | slumber | off | lost | unknown (no source says) | absent (no SweetAdreno630 service: kernel without the GPU driver) */
	jk_str("state", gpu.state[0] ? gpu.state : (gpu.service_present || gpu.have_sysctl ? "unknown" : "absent"));
	jk_oint("level", gpu.level);
	jk_oint("levels", gpu.nlevels);
	jk_onum("mhz", gpu.mhz, 0);
	jk_onum("minMhz", gpu.min_mhz, 0);
	jk_onum("maxMhz", gpu.max_mhz, 0);
	jk_onum("busyPct", gpu.busy, 0);
	jk_int("clients", nclients);
	jk_str("freqMode", gpu.freq_mode[0] ? gpu.freq_mode : NULL);
	jkey("pids");
	if (gpu.pids[0]) {
		jput("[%s]", gpu.pids);
	} else {
		jput("null");
	}
	jk_oint("suspends", gpu.suspends);
	jk_oint("recoveries", gpu.recoveries);
	jk_oint("hangs", gpu.hangs);
	jput("}");
}

/* ---- renderer ---- */

static int
bglrender_arg(char *out, size_t n)
{
	char args[1024] = "";
	size_t len = sizeof(args) - 1;
	if (sysctlbyname("kern.bootargs", args, &len, NULL, 0) != 0) {
		return 0;
	}
	for (const char *p = args; *p;) {
		while (*p == ' ') {
			p++;
		}
		const char *e = p;
		while (*e && *e != ' ') {
			e++;
		}
		if ((size_t)(e - p) > 10 && !strncmp(p, "bglrender=", 10)) {
			size_t l = (size_t)(e - p) - 10;
			if (l >= n) {
				l = n - 1;
			}
			memcpy(out, p + 10, l);
			out[l] = 0;
			return 1;
		}
		p = e;
	}
	return 0;
}

/* marker "MODE UUID [debug]", honoured only when UUID is this boot's kern.bootsessionuuid (as bgl-launch) */
static int
bglrender_marker(char *out, size_t n)
{
	char cur[64] = "", line[256];
	size_t len = sizeof(cur) - 1;
	if (sysctlbyname("kern.bootsessionuuid", cur, &len, NULL, 0) != 0 || !cur[0]) {
		return 0;
	}
	FILE *f = fopen("/private/var/run/bglrender", "r");
	if (!f) {
		return 0;
	}
	char *r = fgets(line, sizeof(line), f);
	fclose(f);
	if (!r) {
		return 0;
	}
	char *save = NULL, *mode = strtok_r(line, " \r\n", &save), *uuid = strtok_r(NULL, " \r\n", &save);
	if (!mode || !uuid || strcmp(uuid, cur) != 0) {
		return 0;
	}
	snprintf(out, n, "%s", mode);
	return 1;
}

/* pid of backboardd / backboardd.real (p_comm), -1 if none */
static int
find_backboardd(void)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t sz = 0;
	if (sysctl(mib, 3, NULL, &sz, NULL, 0) != 0 || sz == 0) {
		return -1;
	}
	sz += sz / 8;
	struct kinfo_proc *kp = malloc(sz);
	if (!kp) {
		return -1;
	}
	int pid = -1;
	if (sysctl(mib, 3, kp, &sz, NULL, 0) == 0) {
		size_t cnt = sz / sizeof(*kp);
		for (size_t i = 0; i < cnt; i++) {
			if (!strncmp(kp[i].kp_proc.p_comm, "backboardd", 10)) {
				pid = kp[i].kp_proc.p_pid;
				break;
			}
		}
	}
	free(kp);
	return pid;
}

/* 1 if the process's environment has DYLD_INSERT_LIBRARIES with bergamota-gl, 0 if not, -1 unreadable */
static int
env_injected(int pid)
{
	int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
	size_t sz = 0;
	if (sysctl(mib, 3, NULL, &sz, NULL, 0) != 0 || sz < 8) {
		return -1;
	}
	char *buf = malloc(sz);
	if (!buf) {
		return -1;
	}
	int res = -1;
	if (sysctl(mib, 3, buf, &sz, NULL, 0) == 0 && sz > sizeof(int)) {
		int argc;
		memcpy(&argc, buf, sizeof(argc));
		char *p = buf + sizeof(int), *end = buf + sz;
		while (p < end && *p) {
			p++;                    /* exec path */
		}
		while (p < end && !*p) {
			p++;
		}
		for (int i = 0; i < argc && p < end; i++) {
			p += strnlen(p, (size_t)(end - p)) + 1;
		}
		res = 0;
		while (p < end && *p) {
			size_t l = strnlen(p, (size_t)(end - p));
			if (!strncmp(p, "DYLD_INSERT_LIBRARIES=", 22) && strstr(p, "bergamota-gl")) {
				res = 1;
			}
			p += l + 1;
		}
	}
	free(buf);
	return res;
}

static char log_last[200];
static int log_softpipe;

static void
read_bgl_log(void)
{
	FILE *f = fopen("/private/var/tmp/bgl-backboardd.log", "r");
	if (!f) {
		return;
	}
	char tail[4096];
	fseek(f, 0, SEEK_END);
	long end = ftell(f);
	long from = end > (long)sizeof(tail) - 1 ? end - ((long)sizeof(tail) - 1) : 0;
	fseek(f, from, SEEK_SET);
	size_t n = fread(tail, 1, sizeof(tail) - 1, f);
	fclose(f);
	tail[n] = 0;
	log_softpipe = strcasestr(tail, "softpipe") != NULL;
	char *last = NULL;
	for (char *p = strtok(tail, "\n"); p; p = strtok(NULL, "\n")) {
		if (*p) {
			last = p;
		}
	}
	if (last) {
		snprintf(log_last, sizeof(log_last), "%s", last);
	}
}

static void
emit_renderer(void)
{
	char val[16] = "";
	const char *src = "none", *req = "off";
	if (bglrender_arg(val, sizeof(val))) {
		src = "bootarg";
	} else if (bglrender_marker(val, sizeof(val))) {
		src = "marker";
	}
	if (!strcmp(val, "1") || !strcmp(val, "soft")) {
		req = val;
	} else {
		src = "none";
	}
	int bbd = find_backboardd();
	int inj = bbd > 0 ? env_injected(bbd) : -1;
	read_bgl_log();
	int has_client = 0;
	for (int i = 0; i < nclients; i++) {
		if (bbd > 0 && clients[i].pid == bbd) {
			has_client = 1;
		}
	}
	/*
	 * Truth, not intent: FD630 only when backboardd itself holds a SweetAdrenoUserClient; softpipe only when it was
	 * injected and the shim's log shows softpipe; otherwise the render server draws with CoreAnimation's software renderer
	 * (QuartzCore's render server never creates an EAGLContext, so the injected shim is loaded but unused).
	 */
	const char *mode = "cpu", *label = "CPU (CoreAnimation software)";
	if (has_client) {
		mode = "fd630";
		label = "FD630 (GPU)";
	} else if (strcmp(req, "off") && inj == 1 && log_softpipe) {
		mode = "softpipe";
		label = "softpipe";
	}
	jkey("renderer");
	JOBJ_BEGIN();
	jk_str("mode", mode);
	jk_str("label", label);
	jk_str("requested", req);
	jk_str("requestedBy", src);
	if (bbd > 0) { jk_int("backboarddPid", bbd); } else { jk_null("backboarddPid"); }
	if (inj >= 0) { jk_bool("injected", inj); } else { jk_null("injected"); }
	jk_bool("gpuClientOpen", has_client);
	jkey("gpuClients");
	jput("[");
	for (int i = 0; i < nclients; i++) {
		jput("%s", i ? "," : "");
		JOBJ_BEGIN();
		jk_int("pid", clients[i].pid);
		jk_str("name", clients[i].name);
		jput("}");
	}
	jput("]");
	jk_bool("registryRead", registry_ok);
	jk_str("logLast", log_last[0] ? log_last : NULL);
	jput("}");
}

/* ---- battery (the sweetps IOPS path + the IOPMPowerSource registry entry) ---- */

static int
cf_dbl(CFTypeRef v, double *out)
{
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
		return CFNumberGetValue(v, kCFNumberDoubleType, out);
	}
	if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
		*out = CFBooleanGetValue(v);
		return 1;
	}
	return 0;
}

static int
dict_dbl(CFDictionaryRef d, const char *key, double *out)
{
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFTypeRef v = CFDictionaryGetValue(d, k);
	CFRelease(k);
	return cf_dbl(v, out);
}

static int
dict_str(CFDictionaryRef d, const char *key, char *out, size_t n)
{
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFTypeRef v = CFDictionaryGetValue(d, k);
	CFRelease(k);
	return v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString(v, out, (CFIndex)n, kCFStringEncodingUTF8);
}

static void
emit_battery(void)
{
	double percent = -1, charging = -1, external = -1, ma = -1e9, mv = -1, tempc = -1e9, full = -1;
	int have_ma = 0, temp_est = 1;
	char source[48] = "";
	int got = 0;

	void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
	if (h) {
		CFTypeRef (*info)(void) = dlsym(h, "IOPSCopyPowerSourcesInfo");
		CFArrayRef (*list)(CFTypeRef) = dlsym(h, "IOPSCopyPowerSourcesList");
		CFDictionaryRef (*desc)(CFTypeRef, CFTypeRef) = dlsym(h, "IOPSGetPowerSourceDescription");
		if (info && list && desc) {
			CFTypeRef blob = info();
			CFArrayRef l = blob ? list(blob) : NULL;
			if (l && CFArrayGetCount(l) > 0) {
				CFDictionaryRef d = desc(blob, CFArrayGetValueAtIndex(l, 0));
				if (d) {
					got = 1;
					dict_dbl(d, "Current Capacity", &percent);
					dict_dbl(d, "Is Charging", &charging);
					dict_str(d, "Power Source State", source, sizeof(source));
					if (dict_dbl(d, "Current", &ma)) {
						have_ma = 1;
					}
					dict_dbl(d, "Voltage", &mv);
				}
			}
			if (l) {
				CFRelease(l);
			}
			if (blob) {
				CFRelease(blob);
			}
		}
	}
	/* The registry entry has the electrical values (kernel SweetBattery: mA positive while charging, mV). */
	io_service_t ps = IOServiceGetMatchingService(0, IOServiceMatching("IOPMPowerSource"));
	if (ps) {
		CFMutableDictionaryRef p = NULL;
		if (IORegistryEntryCreateCFProperties(ps, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS && p) {
			got = 1;
			double v;
			if (dict_dbl(p, "InstantAmperage", &v) || dict_dbl(p, "Amperage", &v)) {
				ma = v;
				have_ma = 1;
			}
			if (dict_dbl(p, "Voltage", &v) || dict_dbl(p, "AppleRawBatteryVoltage", &v)) {
				mv = v;
			}
			if (percent < 0 && dict_dbl(p, "CurrentCapacity", &v)) {
				percent = v;
			}
			if (charging < 0 && dict_dbl(p, "IsCharging", &v)) {
				charging = v;
			}
			if (dict_dbl(p, "ExternalConnected", &v)) {
				external = v;
			}
			if (dict_dbl(p, "FullyCharged", &v)) {
				full = v;
			}
			if (dict_dbl(p, "SweetBatteryTemperatureEstimated", &v)) {
				temp_est = v != 0;
			} else {
				temp_est = 0;
			}
			if (dict_dbl(p, "Temperature", &v)) {
				tempc = v / 100.0;       /* IOPMPowerSource: 0.01 degC */
			}
			CFRelease(p);
		}
		IOObjectRelease(ps);
	}
	if (!got) {
		note("battery: no power source");
	}
	if (ma > 20000 || ma < -20000) {          /* a unit slip must not poison the sparkline */
		have_ma = 0;
	}
	jkey("battery");
	JOBJ_BEGIN();
	jk_bool("present", got);
	jk_onum("percent", percent, 0);
	if (charging >= 0) { jk_bool("charging", charging != 0); } else { jk_null("charging"); }
	if (external >= 0) { jk_bool("external", external != 0); } else { jk_null("external"); }
	if (full >= 0) { jk_bool("full", full != 0); } else { jk_null("full"); }
	jk_str("source", source[0] ? source : NULL);
	if (have_ma) { jk_num("currentMa", ma, 0); } else { jk_null("currentMa"); }
	jk_onum("voltageMv", mv, 0);
	jput("}");
	/* thermal: the SoC temperature is not exposed by the kernel; a battery temperature only when it is measured */
	if (tempc > -1e8 && !temp_est) {
		jkey("thermal");
		JOBJ_BEGIN();
		jk_num("batteryC", tempc, 1);
		jput("}");
	}
}

/* ---- main ---- */

int
main(int argc, char **argv)
{
	int want_info = 0, want_load = 1;
	unsigned interval = 250;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--gpu-info")) {
			want_info = 1;
		} else if (!strcmp(argv[i], "--no-load")) {
			want_load = 0;
		} else if (!strcmp(argv[i], "--interval") && i + 1 < argc) {
			interval = (unsigned)atoi(argv[++i]);
			if (interval < 20) {
				interval = 20;
			}
			if (interval > 5000) {
				interval = 5000;
			}
		} else if (!strcmp(argv[i], "--parse-cpufreq") && i + 1 < argc) {
			parse_cpufreq(argv[++i]);
			ncpu_load = 0;
			JOBJ_BEGIN();
			emit_cpu();
			jput("}");
			printf("%s\n", jb);
			return 0;
		} else if (!strcmp(argv[i], "--parse-gpu") && i + 1 < argc) {
			parse_gpu(argv[++i]);
			JOBJ_BEGIN();
			emit_gpu();
			jput("}");
			printf("%s\n", jb);
			return 0;
		} else {
			fprintf(stderr, "usage: sweetmetrics [--gpu-info] [--no-load] [--interval MS]\n");
			return 2;
		}
	}
	read_cpufreq();
	if (want_load) {
		read_load(interval);
	}
	read_gpu(want_info);

	struct timeval tv;
	gettimeofday(&tv, NULL);
	JOBJ_BEGIN();
	jk_int("schema", SCHEMA);
	jk_num("t", (double)tv.tv_sec + tv.tv_usec / 1e6, 3);
	emit_cpu();
	emit_gpu();
	emit_renderer();
	emit_battery();
	jkey("errors");
	jput("[");
	for (int i = 0; i < nerr; i++) {
		jput("%s", i ? "," : "");
		jstr(errs[i]);
	}
	jput("]");
	jput("}");
	printf("%s\n", jb);
	return 0;
}
