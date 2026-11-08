/*
 * cscheck: ask the kernel what it tells other processes about a process's
 * code signature, the way Security.framework / tccd / libxpc do (docs/CSOPS.md).
 *
 *   cscheck [-v] [-k KEY] [-t] [-l] PID|NAME|self ...
 *
 *   -v      print every DER entitlement key (default: count and a few)
 *   -k KEY  also print the value of one entitlement (e.g. com.apple.private.tcc.allow)
 *   -t      also go through an audit token: csops_audittoken() and the real
 *           SecTaskCreateWithAuditToken / SecTaskCopySigningIdentifier /
 *           SecTaskCopyValueForEntitlement (what tccd does for an XPC peer).
 *           The pid version of another process is not available to a plain
 *           process, so it is found by trying csops_audittoken(CS_OPS_STATUS)
 *           until it stops failing with ESRCH (a few seconds worst case).
 *   -l      list pids and names (sysctl KERN_PROC_ALL) and exit
 *   NAME    a process name (kinfo_proc p_comm, first 15 characters, exact
 *           match, else prefix match), resolved with sysctl KERN_PROC
 *
 * Per process: csops (pid-based) CS_OPS_STATUS, IDENTITY, TEAMID, CDHASH,
 * PIDOFFSET, VALIDATION_CATEGORY, ENTITLEMENTS_BLOB (XML) and
 * DER_ENTITLEMENTS_BLOB with result, errno and size. Blob ops are called
 * like SecTaskLoadEntitlements does: 8-byte buffer first, then the length
 * from the ERANGE header.
 *
 * Exit status: 0 if every op that matters (STATUS, IDENTITY, DER) succeeded
 * for every target, 1 otherwise, 2 on usage errors.
 *
 * Build: tools/sweetnet/build.sh -> research/sweetnet/cscheck
 */
#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <errno.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define CS_OPS_STATUS               0
#define CS_OPS_CDHASH               5
#define CS_OPS_PIDOFFSET            6
#define CS_OPS_ENTITLEMENTS_BLOB    7
#define CS_OPS_IDENTITY             11
#define CS_OPS_TEAMID               14
#define CS_OPS_DER_ENTITLEMENTS_BLOB 16
#define CS_OPS_VALIDATION_CATEGORY  17

#define CS_VALID                0x00000001
#define CS_ADHOC                0x00000002
#define CS_GET_TASK_ALLOW       0x00000004
#define CS_HARD                 0x00000100
#define CS_KILL                 0x00000200
#define CS_RESTRICT             0x00000800
#define CS_ENFORCEMENT          0x00001000
#define CS_REQUIRE_LV           0x00002000
#define CS_DEBUGGED             0x10000000
#define CS_SIGNED               0x20000000
#define CS_PLATFORM_BINARY      0x04000000
#define CS_PLATFORM_PATH        0x08000000

/* libproc.h is not in the iOS SDK; libSystem exports this */
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define PROC_PIDPATHINFO_MAXSIZE 4096

int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
int csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize,
    audit_token_t *token);

/* Security.framework SPI (exported on iOS, no public header) */
typedef const struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateWithAuditToken(CFAllocatorRef, audit_token_t);
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef);
extern CFStringRef SecTaskCopySigningIdentifier(SecTaskRef, CFErrorRef *);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef, CFStringRef, CFErrorRef *);

static int verbose;
static const char *want_key;
static int use_token;
static int failures;

static void
describe_flags(uint32_t f)
{
	static const struct { uint32_t bit; const char *name; } names[] = {
		{ CS_VALID, "VALID" }, { CS_ADHOC, "ADHOC" }, { CS_GET_TASK_ALLOW, "GET_TASK_ALLOW" },
		{ CS_HARD, "HARD" }, { CS_KILL, "KILL" }, { CS_RESTRICT, "RESTRICT" },
		{ CS_ENFORCEMENT, "ENFORCEMENT" }, { CS_REQUIRE_LV, "REQUIRE_LV" },
		{ CS_DEBUGGED, "DEBUGGED" }, { CS_SIGNED, "SIGNED" },
		{ CS_PLATFORM_BINARY, "PLATFORM_BINARY" }, { CS_PLATFORM_PATH, "PLATFORM_PATH" },
	};
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		if (f & names[i].bit) {
			printf(" %s", names[i].name);
		}
	}
}

/* pid-based or audit-token based csops, depending on token */
static int
do_csops(pid_t pid, unsigned int op, void *buf, size_t len, audit_token_t *token)
{
	return token ? csops_audittoken(pid, op, buf, len, token) : csops(pid, op, buf, len);
}

/*
 * Blob op the way SecTaskLoadEntitlements does it: 8 bytes first; ERANGE
 * carries the big-endian length at +4; then the whole blob. Returns the
 * malloc'd blob (header included) or NULL; *err is the errno of the failing
 * call (0: success without data), *len the blob length.
 */
static uint8_t *
fetch_blob(pid_t pid, unsigned int op, audit_token_t *token, int *err, size_t *len)
{
	uint8_t head[8];
	memset(head, 0xaa, sizeof(head));
	*err = 0;
	*len = 0;
	errno = 0;
	if (do_csops(pid, op, head, sizeof(head), token) == 0) {
		/* success with an 8-byte buffer: an empty (zero) header, or a blob that fits */
		uint32_t l = (uint32_t)head[4] << 24 | head[5] << 16 | head[6] << 8 | head[7];
		if (l <= 8) {
			return NULL;
		}
	} else if (errno != ERANGE) {
		*err = errno;
		return NULL;
	}
	uint32_t total = (uint32_t)head[4] << 24 | head[5] << 16 | head[6] << 8 | head[7];
	if (total <= 8 || total > (1u << 20)) {
		*err = EBADMSG;
		return NULL;
	}
	uint8_t *buf = calloc(1, total);
	if (buf == NULL) {
		*err = ENOMEM;
		return NULL;
	}
	errno = 0;
	if (do_csops(pid, op, buf, total, token) != 0) {
		*err = errno;
		free(buf);
		return NULL;
	}
	*len = total;
	return buf;
}

/* ---- tiny DER walker for the CoreEntitlements layout ---- */

static int
der_tlv(const uint8_t *p, const uint8_t *end, uint8_t *tag, const uint8_t **val, size_t *vlen,
    const uint8_t **next)
{
	if (end - p < 2) {
		return -1;
	}
	*tag = p[0];
	size_t l = p[1];
	p += 2;
	if (l & 0x80) {
		unsigned n = l & 0x7f;
		if (n == 0 || n > 3 || (size_t)(end - p) < n) {
			return -1;
		}
		l = 0;
		while (n--) {
			l = l << 8 | *p++;
		}
	}
	if ((size_t)(end - p) < l) {
		return -1;
	}
	*val = p;
	*vlen = l;
	*next = p + l;
	return 0;
}

static void
der_print_value(const uint8_t *p, size_t n, int depth)
{
	uint8_t tag;
	const uint8_t *v, *next;
	size_t vl;
	if (der_tlv(p, p + n, &tag, &v, &vl, &next) != 0) {
		printf("<bad DER>");
		return;
	}
	switch (tag) {
	case 0x01:
		printf("%s", vl == 1 && v[0] ? "true" : "false");
		break;
	case 0x0c:
		printf("\"%.*s\"", (int)vl, (const char *)v);
		break;
	case 0x02: {
		long long x = vl && (v[0] & 0x80) ? -1 : 0;
		for (size_t i = 0; i < vl && i < 8; i++) {
			x = x << 8 | v[i];
		}
		printf("%lld", x);
		break;
	}
	case 0x30: {
		printf("[");
		const uint8_t *q = v, *e = v + vl;
		for (int first = 1; q < e; first = 0) {
			uint8_t t2;
			const uint8_t *v2, *n2;
			size_t l2;
			if (der_tlv(q, e, &t2, &v2, &l2, &n2) != 0) {
				break;
			}
			printf("%s", first ? "" : ", ");
			der_print_value(q, (size_t)(n2 - q), depth + 1);
			q = n2;
		}
		printf("]");
		break;
	}
	case 0xb0: {
		printf("{");
		const uint8_t *q = v, *e = v + vl;
		for (int first = 1; q < e; first = 0) {
			uint8_t t2;
			const uint8_t *v2, *n2;
			size_t l2;
			if (der_tlv(q, e, &t2, &v2, &l2, &n2) != 0 || t2 != 0x30) {
				break;
			}
			uint8_t t3;
			const uint8_t *k, *kn;
			size_t kl;
			if (der_tlv(v2, v2 + l2, &t3, &k, &kl, &kn) != 0) {
				break;
			}
			printf("%s%.*s=", first ? "" : ", ", (int)kl, (const char *)k);
			der_print_value(kn, (size_t)(v2 + l2 - kn), depth + 1);
			q = n2;
		}
		printf("}");
		break;
	}
	default:
		printf("<tag 0x%02x, %zu bytes>", tag, vl);
	}
}

/* print the DER entitlements blob (header included) */
static void
der_summary(const uint8_t *blob, size_t len)
{
	const uint8_t *end = blob + len;
	uint8_t tag;
	const uint8_t *v, *next;
	size_t vl;
	if (len < 8 || der_tlv(blob + 8, end, &tag, &v, &vl, &next) != 0 || tag != 0x70) {
		printf("      (not a CoreEntitlements DER blob)\n");
		return;
	}
	const uint8_t *e = v + vl;
	const uint8_t *dict = NULL;
	size_t dl = 0;
	const uint8_t *q = v;
	while (q < e) {
		const uint8_t *v2, *n2;
		size_t l2;
		uint8_t t2;
		if (der_tlv(q, e, &t2, &v2, &l2, &n2) != 0) {
			break;
		}
		if (t2 == 0xb0) {
			dict = v2;
			dl = l2;
		}
		q = n2;
	}
	if (dict == NULL) {
		printf("      (no dictionary)\n");
		return;
	}
	unsigned count = 0, shown = 0;
	const uint8_t *de = dict + dl;
	for (q = dict; q < de;) {
		uint8_t t2, t3;
		const uint8_t *v2, *n2, *k, *kn;
		size_t l2, kl;
		if (der_tlv(q, de, &t2, &v2, &l2, &n2) != 0 || t2 != 0x30 ||
		    der_tlv(v2, v2 + l2, &t3, &k, &kl, &kn) != 0) {
			break;
		}
		count++;
		int match = want_key && strlen(want_key) == kl && memcmp(want_key, k, kl) == 0;
		if (verbose || shown < 5 || match) {
			printf("      %.*s = ", (int)kl, (const char *)k);
			der_print_value(kn, (size_t)(v2 + l2 - kn), 0);
			printf("\n");
			shown++;
		}
		q = n2;
	}
	printf("      %u entitlement%s%s\n", count, count == 1 ? "" : "s",
	    (verbose || count <= shown) ? "" : " (use -v for all)");
}

static void
cfstr_print(CFTypeRef v)
{
	if (v == NULL) {
		printf("(null)");
		return;
	}
	if (CFGetTypeID(v) == CFStringGetTypeID()) {
		char b[512];
		if (CFStringGetCString(v, b, sizeof(b), kCFStringEncodingUTF8)) {
			printf("\"%s\"", b);
			return;
		}
	}
	CFStringRef d = CFCopyDescription(v);
	char b[1024];
	if (d && CFStringGetCString(d, b, sizeof(b), kCFStringEncodingUTF8)) {
		for (char *c = b; *c; c++) {
			if (*c == '\n' || *c == '\t') {
				*c = ' ';
			}
		}
		printf("%s", b);
	}
	if (d) {
		CFRelease(d);
	}
}

static void
secTaskReport(SecTaskRef task, const char *how)
{
	if (task == NULL) {
		printf("  SecTask (%s): SecTaskCreate failed\n", how);
		failures++;
		return;
	}
	CFErrorRef err = NULL;
	CFStringRef ident = SecTaskCopySigningIdentifier(task, &err);
	printf("  SecTask (%s): SecTaskCopySigningIdentifier = ", how);
	cfstr_print(ident);
	if (err) {
		printf("  error: ");
		cfstr_print(err);
		CFRelease(err);
		err = NULL;
	}
	printf("\n");
	if (ident == NULL) {
		failures++;
	} else {
		CFRelease(ident);
	}
	static const char *keys[] = { "application-identifier", "platform-application",
		                      "com.apple.private.tcc.allow" };
	for (size_t i = 0; i < 4; i++) {
		const char *k = i < 3 ? keys[i] : want_key;
		if (k == NULL || (i == 3 && (strcmp(k, keys[0]) == 0 || strcmp(k, keys[1]) == 0 || strcmp(k, keys[2]) == 0))) {
			continue;
		}
		CFStringRef ck = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
		CFTypeRef v = SecTaskCopyValueForEntitlement(task, ck, &err);
		printf("  SecTask (%s): SecTaskCopyValueForEntitlement(%s) = ", how, k);
		cfstr_print(v);
		if (err) {
			printf("  error: ");
			cfstr_print(err);
			CFRelease(err);
			err = NULL;
		}
		printf("\n");
		if (v) {
			CFRelease(v);
		}
		CFRelease(ck);
	}
}

/* all the ops for one pid, optionally through an audit token */
static void
check(pid_t pid, audit_token_t *token)
{
	const char *via = token ? "csops_audittoken" : "csops";
	uint32_t status = 0;
	errno = 0;
	int r = do_csops(pid, CS_OPS_STATUS, &status, sizeof(status), token);
	printf("  %s STATUS: ret %d errno %d (%s)", via, r, r ? errno : 0, r ? strerror(errno) : "ok");
	if (r == 0) {
		printf(" flags 0x%08x:", status);
		describe_flags(status);
	} else {
		failures++;
	}
	printf("\n");

	uint8_t id[512];
	memset(id, 0, sizeof(id));
	errno = 0;
	r = do_csops(pid, CS_OPS_IDENTITY, id, sizeof(id), token);
	printf("  %s IDENTITY: ret %d errno %d (%s)", via, r, r ? errno : 0, r ? strerror(errno) : "ok");
	if (r == 0) {
		printf(" '%s'", (const char *)id + 8);
	} else {
		failures++;
	}
	printf("\n");

	memset(id, 0, sizeof(id));
	errno = 0;
	r = do_csops(pid, CS_OPS_TEAMID, id, sizeof(id), token);
	printf("  %s TEAMID: ret %d errno %d (%s)", via, r, r ? errno : 0, r ? strerror(errno) : "ok");
	if (r == 0) {
		printf(" '%s'", (const char *)id + 8);
	}
	printf("\n");

	if (token == NULL) {
		uint8_t cdhash[20];
		errno = 0;
		r = csops(pid, CS_OPS_CDHASH, cdhash, sizeof(cdhash));
		printf("  csops CDHASH: ret %d errno %d (%s)", r, r ? errno : 0, r ? strerror(errno) : "ok");
		if (r == 0) {
			printf(" ");
			for (int i = 0; i < 20; i++) {
				printf("%02x", cdhash[i]);
			}
		}
		printf("\n");
		long long off = 0;
		errno = 0;
		r = csops(pid, CS_OPS_PIDOFFSET, &off, sizeof(off));
		printf("  csops PIDOFFSET: ret %d errno %d (%s) offset %lld\n", r, r ? errno : 0,
		    r ? strerror(errno) : "ok", off);
		uint32_t cat = 0;
		errno = 0;
		r = csops(pid, CS_OPS_VALIDATION_CATEGORY, &cat, sizeof(cat));
		printf("  csops VALIDATION_CATEGORY: ret %d errno %d (%s) category %u\n", r,
		    r ? errno : 0, r ? strerror(errno) : "ok", cat);
	}

	int err;
	size_t len;
	uint8_t *blob = fetch_blob(pid, CS_OPS_ENTITLEMENTS_BLOB, token, &err, &len);
	printf("  %s ENTITLEMENTS_BLOB (XML): %s, errno %d (%s), %zu bytes\n", via,
	    blob ? "data" : (err ? "FAILED" : "success, no data"), err, err ? strerror(err) : "ok", len);
	if (blob) {
		size_t shown = len - 8 > 160 ? 160 : len - 8;
		printf("      %.*s%s\n", (int)shown, (const char *)blob + 8, shown < len - 8 ? "..." : "");
		free(blob);
	}

	blob = fetch_blob(pid, CS_OPS_DER_ENTITLEMENTS_BLOB, token, &err, &len);
	printf("  %s DER_ENTITLEMENTS_BLOB: %s, errno %d (%s), %zu bytes\n", via,
	    blob ? "data" : (err ? "FAILED" : "success, no data (SecTask sees NO entitlements)"), err,
	    err ? strerror(err) : "ok", len);
	if (blob) {
		der_summary(blob, len);
		free(blob);
	} else {
		failures++;
	}
}

/* find a pid version that csops_audittoken accepts (see usage) */
static int
make_token(pid_t pid, audit_token_t *token)
{
	uid_t uid = 0, gid = 0;
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
	struct kinfo_proc ki;
	size_t kl = sizeof(ki);
	if (sysctl(mib, 4, &ki, &kl, NULL, 0) == 0 && kl == sizeof(ki)) {
		uid = ki.kp_eproc.e_ucred.cr_uid;
		gid = ki.kp_eproc.e_ucred.cr_groups[0];
	}
	if (pid == getpid()) {
		mach_msg_type_number_t cnt = TASK_AUDIT_TOKEN_COUNT;
		if (task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)token, &cnt) == KERN_SUCCESS) {
			return 0;
		}
	}
	memset(token, 0, sizeof(*token));
	token->val[0] = (unsigned)-1;       /* auid */
	token->val[1] = uid;
	token->val[2] = gid;
	token->val[3] = uid;
	token->val[4] = gid;
	token->val[5] = (unsigned)pid;
	for (unsigned v = 0; v < (1u << 26); v++) {     /* ~seconds; fresh boots are in the hundreds */
		uint32_t st;
		token->val[7] = v;
		errno = 0;
		if (csops_audittoken(pid, CS_OPS_STATUS, &st, sizeof(st), token) == 0) {
			return 0;
		}
		if (errno != ESRCH) {
			return -1;      /* some other failure: the token is not the problem */
		}
	}
	return -1;
}

static pid_t
find_pid(const char *name)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t size = 0;
	if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
		perror("sysctl KERN_PROC size");
		return -1;
	}
	size += size / 8 + sizeof(struct kinfo_proc) * 8;
	struct kinfo_proc *procs = malloc(size);
	if (procs == NULL || sysctl(mib, 3, procs, &size, NULL, 0) != 0) {
		perror("sysctl KERN_PROC");
		free(procs);
		return -1;
	}
	size_t n = size / sizeof(struct kinfo_proc);
	pid_t exact = -1, prefix = -1;
	for (size_t i = 0; i < n; i++) {
		const char *comm = procs[i].kp_proc.p_comm;
		if (strcmp(comm, name) == 0) {
			exact = procs[i].kp_proc.p_pid;
		} else if (prefix < 0 && strncmp(comm, name, strlen(name)) == 0) {
			prefix = procs[i].kp_proc.p_pid;
		}
	}
	free(procs);
	return exact >= 0 ? exact : prefix;
}

static int
list_procs(void)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t size = 0;
	if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
		perror("sysctl");
		return 1;
	}
	size += sizeof(struct kinfo_proc) * 8;
	struct kinfo_proc *procs = malloc(size);
	if (procs == NULL || sysctl(mib, 3, procs, &size, NULL, 0) != 0) {
		perror("sysctl");
		return 1;
	}
	for (size_t i = 0; i < size / sizeof(struct kinfo_proc); i++) {
		printf("%6d  %s\n", procs[i].kp_proc.p_pid, procs[i].kp_proc.p_comm);
	}
	free(procs);
	return 0;
}

static void
usage(void)
{
	fprintf(stderr, "usage: cscheck [-v] [-t] [-k ENTITLEMENT] [-l] PID|NAME|self ...\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	int ch;
	int list = 0;
	while ((ch = getopt(argc, argv, "vtk:l")) != -1) {
		switch (ch) {
		case 'v': verbose = 1; break;
		case 't': use_token = 1; break;
		case 'k': want_key = optarg; break;
		case 'l': list = 1; break;
		default: usage();
		}
	}
	if (list) {
		return list_procs();
	}
	if (optind >= argc) {
		usage();
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	for (int i = optind; i < argc; i++) {
		const char *arg = argv[i];
		pid_t pid;
		if (strcmp(arg, "self") == 0) {
			pid = getpid();
		} else if (isdigit((unsigned char)arg[0])) {
			pid = atoi(arg);
		} else {
			pid = find_pid(arg);
			if (pid < 0) {
				fprintf(stderr, "cscheck: no process named '%s'\n", arg);
				failures++;
				continue;
			}
		}
		char path[PROC_PIDPATHINFO_MAXSIZE] = "?";
		proc_pidpath(pid, path, sizeof(path));
		printf("== %s -> pid %d  %s\n", arg, pid, path);
		check(pid, NULL);
		if (use_token) {
			audit_token_t token;
			if (make_token(pid, &token) != 0) {
				printf("  could not build an audit token for pid %d (csops_audittoken never accepted a pid version)\n", pid);
				failures++;
			} else {
				printf("  audit token pid %u pidversion %u\n", token.val[5], token.val[7]);
				check(pid, &token);
				secTaskReport(SecTaskCreateWithAuditToken(NULL, token), "audit token");
			}
		}
		if (pid == getpid()) {
			secTaskReport(SecTaskCreateFromSelf(NULL), "from self");
		}
	}
	return failures ? 1 : 0;
}
