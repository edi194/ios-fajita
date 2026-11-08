/*
 * Just enough flattened-device-tree parsing to find what ABL put in
 * /chosen (initrd location). Big-endian, 4-byte aligned tokens.
 */
#include "fdt.h"

#define FDT_MAGIC	0xd00dfeed
#define FDT_BEGIN_NODE	1
#define FDT_END_NODE	2
#define FDT_PROP	3
#define FDT_NOP		4
#define FDT_END		9

static uint32_t be32(uintptr_t a)
{
	return __builtin_bswap32(*(volatile uint32_t *)a);
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static uintptr_t align4(uintptr_t a)
{
	return (a + 3) & ~3UL;
}

static uintptr_t skip_str(uintptr_t p)
{
	/* byte loads are fine on Device memory as long as they are aligned to 1 */
	while (*(volatile char *)p)
		p++;
	return p + 1;
}

int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out)
{
	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	uintptr_t p = fdt + be32(fdt + 8);		/* off_dt_struct */
	uintptr_t strings = fdt + be32(fdt + 12);	/* off_dt_strings */
	int depth = 0, in_chosen = 0;

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			depth++;
			in_chosen = depth == 2 && streq(name, "chosen");
			p = align4(skip_str(p));
			break;
		}
		case FDT_END_NODE:
			if (in_chosen)
				return 0;
			depth--;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			if (in_chosen && streq((const char *)(strings + nameoff), prop)) {
				if (len == 4)
					*out = be32(val);
				else if (len == 8)
					*out = (uint64_t)be32(val) << 32 | be32(val + 4);
				else
					return 0;
				return 1;
			}
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:	/* FDT_END or garbage */
			return 0;
		}
	}
}

/* Address of a /chosen property's value inside the FDT (e.g. "bootargs"), or 0. */
uintptr_t fdt_chosen_prop(uintptr_t fdt, const char *prop, uint32_t *len)
{
	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	uintptr_t p = fdt + be32(fdt + 8);
	uintptr_t strings = fdt + be32(fdt + 12);
	int depth = 0, in_chosen = 0;

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			depth++;
			in_chosen = depth == 2 && streq(name, "chosen");
			p = align4(skip_str(p));
			break;
		}
		case FDT_END_NODE:
			if (in_chosen)
				return 0;
			depth--;
			break;
		case FDT_PROP: {
			uint32_t l = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			if (in_chosen && streq((const char *)(strings + nameoff), prop)) {
				*len = l;
				return val;
			}
			p = align4(val + l);
			break;
		}
		case FDT_NOP:
			break;
		default:
			return 0;
		}
	}
}

/* ---- bring-up info (needs the console) ---- */
#include "console.h"

static int starts(const char *s, const char *p)
{
	while (*p && *s == *p)
		s++, p++;
	return !*p;
}

static void copy_str(char *d, const char *s, int max)
{
	int i = 0;
	while (i < max - 1 && s[i])
		d[i] = s[i], i++;
	d[i] = 0;
}

/* qcom DTs use #address-cells = #size-cells = 2 at the root and in /reserved-memory. */
static void print_regs(const char *label, uintptr_t val, uint32_t len)
{
	for (uint32_t o = 0; o + 16 <= len; o += 16) {
		uint64_t a = (uint64_t)be32(val + o) << 32 | be32(val + o + 4);
		uint64_t s = (uint64_t)be32(val + o + 8) << 32 | be32(val + o + 12);
		char buf[40];
		static const char hex[] = "0123456789ABCDEF";
		int n = 0;
		for (int i = 32; i >= 0; i -= 4)
			buf[n++] = hex[(a >> i) & 0xf];
		buf[n++] = ' ';
		buf[n++] = '+';
		for (int i = 32; i >= 0; i -= 4)
			buf[n++] = hex[(s >> i) & 0xf];
		buf[n] = 0;
		con_str(label, buf);
	}
}

void fdt_board_info(uintptr_t fdt)
{
	if (!fdt || be32(fdt) != FDT_MAGIC) {
		con_str("FDT", "no live FDT");
		return;
	}
	uintptr_t p = fdt + be32(fdt + 8);
	uintptr_t strings = fdt + be32(fdt + 12);
	int depth = 0, in_mem = 0, in_resv = 0, in_chosen = 0;
	char cur[12] = "";

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			depth++;
			if (depth == 2) {
				in_mem = starts(name, "memory");
				in_resv = streq(name, "reserved-memory");
				in_chosen = streq(name, "chosen");
			}
			if (depth == 3 && in_resv)
				copy_str(cur, name, sizeof cur);
			p = align4(skip_str(p));
			break;
		}
		case FDT_END_NODE:
			depth--;
			if (depth < 2)
				in_mem = in_resv = in_chosen = 0;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			const char *pn = (const char *)(strings + nameoff);
			if (depth == 1 && streq(pn, "model")) {
				char buf[48];
				copy_str(buf, (const char *)val, sizeof buf);
				con_str("MODEL", buf);
			} else if (depth == 2 && in_mem && streq(pn, "reg")) {
				print_regs("MEMORY", val, len);
			} else if (depth == 3 && in_resv && streq(pn, "reg")) {
				print_regs(cur, val, len);
			} else if (depth == 2 && in_chosen && streq(pn, "bootargs")) {
				/* "msm_drm.dsi_display0=dsi_..._display:" names the panel */
				const char *s = (const char *)val;
				for (; *s; s++)
					if (starts(s, "dsi_display0=")) {
						char buf[64];
						copy_str(buf, s + 13, sizeof buf);
						con_str("PANEL", buf);
						break;
					}
			}
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:
			return;
		}
	}
}

/* Value of "key=" as a whole word of /chosen bootargs (pointer into the FDT), or 0. */
const char *fdt_cmdline_opt(uintptr_t fdt, const char *key)
{
	uint32_t len = 0;
	const char *a = (const char *)fdt_chosen_prop(fdt, "bootargs", &len);

	if (!a)
		return 0;
	for (uint32_t i = 0; i < len && a[i]; i++) {
		const char *k = key, *s = a + i;
		if (i && a[i - 1] != ' ')
			continue;
		while (*k && *s == *k)
			s++, k++;
		if (!*k)
			return s;
	}
	return 0;
}
