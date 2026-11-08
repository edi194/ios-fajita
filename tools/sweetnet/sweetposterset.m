/*
 * sweetposterset PROVIDER DESCRIPTOR_ID           make the poster PROVIDER/DESCRIPTOR_ID the selected lock poster (the
 *                                                 home screen follows its poster); idempotent
 * sweetposterset --cleanup PROVIDER DESCRIPTOR_ID delete the other configurations of that provider/descriptor, keeping
 *                                                 the selected one (or, if none is selected, the first)
 *   e.g. sweetposterset com.apple.GradientPoster.GradientPosterExtension darkBlue.preset1
 * Run via SweetRun (mobile launchd domain).
 *
 * Steps: fetch the lock-screen configurations and the selected poster; if the selected one already is PROVIDER/DESCRIPTOR
 * -> done (0). Otherwise reuse an existing configuration of that provider/descriptor, or create one only if there is
 * none, select it, and decide success by fetching the selected poster again (not by the completion).
 * Completion signatures (read from the 22H352 dyld cache, see sweetposter-prs.h): create and fetch calls complete with
 * (result, NSError), update-to-selected and delete with the NSError alone.
 * Exit status: 0 selected, 1 create failed (e.g. -2203 while PosterBoard's data store has an empty lock role, or the
 * service is not up: retry), 2 usage/fetch failed, 3 select failed or not confirmed by the fetch.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>
#include "sweetposter-prs.h"
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
@interface NSObject (SweetU) - (id)serverUUID; - (id)providerIdentifier; - (id)descriptorIdentifier; - (id)uuid; @end

static NSString *role = @"PRPosterRoleLockScreen";
static PRSService *svc;
static NSString *prov, *desc;

static void wt(dispatch_semaphore_t s) {
	for (int i = 0; i < 300; i++) {
		if (!dispatch_semaphore_wait(s, DISPATCH_TIME_NOW)) return;
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	}
	printf("TIMEOUT\n");
}
static NSString *D(id o) { return o ? [o description] : @"(null)"; }

static id try_sel(id o, SEL s) { return [o respondsToSelector:s] ? [o performSelector:s] : nil; }
static NSString *uuid_of(id o) {
	id u = try_sel(o, @selector(serverUUID)) ?: try_sel(o, @selector(uuid));
	if (!u) { id p = try_sel(o, NSSelectorFromString(@"_path")); u = try_sel(p, @selector(serverUUID)) ?: try_sel(p, @selector(uuid)); }
	return u ? [u description] : nil;
}
/* provider + descriptor of a configuration: the accessors if the object has them (on itself or its _path), else its description */
static BOOL matches(id o) {
	if (!o) return NO;
	for (id t in @[o, try_sel(o, NSSelectorFromString(@"_path")) ?: [NSNull null]]) {
		if (t == [NSNull null]) continue;
		id p = try_sel(t, @selector(providerIdentifier)), d = try_sel(t, @selector(descriptorIdentifier));
		if (p && d) return [[p description] isEqualToString:prov] && [[d description] isEqualToString:desc];
	}
	NSString *s = [o description];
	return [s containsString:prov] && [s containsString:desc];
}

static NSArray *fetch_all_role(NSString *r, int *err) {
	__block NSArray *res = nil; __block id e = nil;
	dispatch_semaphore_t s = dispatch_semaphore_create(0);
	[svc fetchPosterConfigurationsForRole:r completion:^(id a, id b) { res = [a isKindOfClass:[NSArray class]] ? a : nil; e = b; dispatch_semaphore_signal(s); }];
	wt(s);
	if (!res) { printf("fetch configurations failed: %s\n", D(e).UTF8String); *err = 1; }
	return res;
}
static NSArray *fetch_all(int *err) { return fetch_all_role(role, err); }

/* fetch-only dump of one configuration or descriptor: the identifiers the accessors give, then the description */
static void dump(const char *tag, id o) {
	id p = try_sel(o, @selector(providerIdentifier)), d = try_sel(o, @selector(descriptorIdentifier));
	id pa = try_sel(o, NSSelectorFromString(@"_path"));
	if (!p && pa) p = try_sel(pa, @selector(providerIdentifier));
	if (!d && pa) d = try_sel(pa, @selector(descriptorIdentifier));
	NSString *desc_ = [o description];
	if (desc_.length > 700) desc_ = [desc_ substringToIndex:700];
	printf("%s uuid=%s provider=%s descriptor=%s\n    %s\n", tag, D(uuid_of(o)).UTF8String, D(p).UTF8String, D(d).UTF8String,
	       [desc_ stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
}
static id fetch_selected(BOOL *ok) {
	__block id res = nil, e = nil; __block BOOL done = NO;
	dispatch_semaphore_t s = dispatch_semaphore_create(0);
	[svc fetchSelectedPosterForRole:role completion:^(id a, id b) { res = a; e = b; done = YES; dispatch_semaphore_signal(s); }];
	wt(s);
	*ok = done && !(res == nil && e != nil);
	if (!*ok) printf("fetch selected failed: %s\n", D(e).UTF8String);
	return res;
}

int main(int argc, char **argv) {
	@autoreleasepool {
		setvbuf(stdout, 0, _IOLBF, 0);
		if (argc >= 2 && (!strcmp(argv[1], "--list") || !strcmp(argv[1], "--descriptors"))) {
			/* FETCH ONLY. --list: every configuration of the lock and home roles and the selected ones. --descriptors PROVIDER: what the provider offers. */
			dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_NOW);
			svc = [[NSClassFromString(@"PRSService") alloc] init];
			if (!strcmp(argv[1], "--descriptors")) {
				if (argc < 3) return 2;
				__block id res = nil, e = nil;
				dispatch_semaphore_t s0 = dispatch_semaphore_create(0);
				[svc fetchPosterDescriptorsForExtension:[NSString stringWithUTF8String:argv[2]] completion:^(id a, id b) { res = a; e = b; dispatch_semaphore_signal(s0); }];
				wt(s0);
				printf("descriptors for %s: %s (error %s)\n", argv[2], res ? [NSString stringWithFormat:@"%lu", (unsigned long)[res count]].UTF8String : "none", D(e).UTF8String);
				for (id d in (res ?: @[])) dump("  descriptor", d);
				return res ? 0 : 1;
			}
			for (NSString *r in @[ @"PRPosterRoleLockScreen", @"PRPosterRoleHomeScreen" ]) {
				int er = 0;
				NSArray *a = fetch_all_role(r, &er);
				printf("role %s: %lu configuration(s)\n", r.UTF8String, (unsigned long)a.count);
				for (id c in a) dump("  config", c);
				role = r;
				BOOL ok;
				id sel = fetch_selected(&ok);
				printf("role %s selected (fetch %s):\n", r.UTF8String, ok ? "ok" : "failed");
				if (sel) dump("  SELECTED", sel);
			}
			for (NSString *sn in @[ @"fetchSelectedConfiguration:", @"fetchActivePosterConfiguration:" ]) {
				__block id res = nil, e = nil;
				dispatch_semaphore_t s1 = dispatch_semaphore_create(0);
				SEL sl = NSSelectorFromString(sn);
				if (![svc respondsToSelector:sl]) continue;
				void (^blk)(id, id) = ^(id a, id b) { res = a; e = b; dispatch_semaphore_signal(s1); };
				((void (*)(id, SEL, id))objc_msgSend)(svc, sl, blk);
				wt(s1);
				printf("%s -> %s\n", sn.UTF8String, res ? "" : D(e).UTF8String);
				if (res) dump("  ", res);
			}
			return 0;
		}
		if (argc == 3 && !strcmp(argv[1], "--delete")) {
			/* --delete UUID: delete one configuration. Emptying the lock role makes PosterBoard set up its default poster again:
			 * a LegacyPoster of the legacy wallpaper once that is an image (sweetlegacywall) */
			dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_NOW);
			svc = [[NSClassFromString(@"PRSService") alloc] init];
			__block id e = nil;
			dispatch_semaphore_t s3 = dispatch_semaphore_create(0);
			[svc deletePosterConfigurationsMatchingUUID:[[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[2]]]
			                                 completion:^(id a) { e = a; dispatch_semaphore_signal(s3); }];
			wt(s3);
			printf("delete %s: %s\n", argv[2], e ? D(e).UTF8String : "ok");
			return e ? 3 : 0;
		}
		if (argc == 3 && !strcmp(argv[1], "--uuid")) {
			/* --uuid UUID: select an existing lock configuration by its UUID (from --list), e.g. a Photos poster that
			 * sweetwallpaper created but PosterBoard did not select because its snapshot step failed */
			dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_NOW);
			svc = [[NSClassFromString(@"PRSService") alloc] init];
			NSString *want = [NSString stringWithUTF8String:argv[2]];
			dispatch_semaphore_t s2 = dispatch_semaphore_create(0);
			[svc updateToSelectedConfigurationMatchingUUID:[[NSUUID alloc] initWithUUIDString:want] role:role completion:^(id e) {
				printf("select error=%s\n", D(e).UTF8String); dispatch_semaphore_signal(s2); }];
			wt(s2);
			BOOL ok;
			id sel = fetch_selected(&ok);
			if (ok && sel && [uuid_of(sel) caseInsensitiveCompare:want] == NSOrderedSame) { printf("selected %s\n", want.UTF8String); return 0; }
			printf("not selected after the update: %s\n", D(sel).UTF8String);
			return 3;
		}
		BOOL cleanup = argc > 1 && !strcmp(argv[1], "--cleanup");
		if (argc - cleanup != 3) { fprintf(stderr, "usage: sweetposterset [--cleanup] PROVIDER DESCRIPTOR_ID\n"); return 2; }
		prov = [NSString stringWithUTF8String:argv[1 + cleanup]];
		desc = [NSString stringWithUTF8String:argv[2 + cleanup]];
		dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_NOW);
		svc = [[NSClassFromString(@"PRSService") alloc] init];
		dispatch_semaphore_t s = dispatch_semaphore_create(0);

		int err = 0;
		NSArray *all = fetch_all(&err);
		if (!all) return 2;
		BOOL okSel;
		id sel = fetch_selected(&okSel);
		if (!okSel) return 2;
		NSString *selUUID = uuid_of(sel);
		NSMutableArray *mine = [NSMutableArray array];
		for (id c in all) if (matches(c)) [mine addObject:c];
		printf("%lu configuration(s) for the lock role, %lu of %s/%s, selected %s (%s)\n", (unsigned long)all.count,
		       (unsigned long)mine.count, argv[1 + cleanup], argv[2 + cleanup], D(selUUID).UTF8String, matches(sel) ? "match" : "other");

		if (cleanup) {
			id keep = nil;
			for (id c in mine) if (selUUID && [uuid_of(c) isEqualToString:selUUID]) keep = c;
			if (!keep) keep = mine.firstObject;
			int del = 0, bad = 0;
			for (id c in mine) {
				if (c == keep) continue;
				id u = try_sel(c, @selector(serverUUID)) ?: try_sel(c, @selector(uuid));
				if (!u) { bad++; continue; }
				__block id e = nil;
				[svc deletePosterConfigurationsMatchingUUID:u completion:^(id a) { e = a; dispatch_semaphore_signal(s); }];
				wt(s);
				if (e) { printf("delete %s: %s\n", D(u).UTF8String, D(e).UTF8String); bad++; } else del++;
			}
			printf("cleanup: kept %s, deleted %d, failed %d\n", D(keep ? uuid_of(keep) : nil).UTF8String, del, bad);
			return bad ? 3 : 0;
		}

		if (sel && matches(sel)) { printf("already selected\n"); return 0; }
		__block id cfg = mine.firstObject;                  // reuse: never create a second configuration
		if (!cfg) {
			__block id e = nil;
			[svc createPosterConfigurationForProviderIdentifier:prov posterDescriptorIdentifier:desc role:role completion:^(id a, id b) {
				printf("create a=%s b=%s\n", D(a).UTF8String, D(b).UTF8String); cfg = a; e = b; dispatch_semaphore_signal(s); }];
			wt(s);
			if (!cfg) return 1;
		} else printf("reusing %s\n", D(uuid_of(cfg)).UTF8String);
		id uuid = try_sel(cfg, @selector(serverUUID)) ?: try_sel(cfg, @selector(uuid));
		[svc updateToSelectedConfigurationMatchingUUID:uuid role:role completion:^(id e) {
			printf("select error=%s\n", D(e).UTF8String); dispatch_semaphore_signal(s); }];
		wt(s);
		sel = fetch_selected(&okSel);
		if (okSel && sel && (matches(sel) || [uuid_of(sel) isEqualToString:uuid_of(cfg)])) { printf("selected %s\n", D(uuid_of(sel)).UTF8String); return 0; }
		printf("not selected after the update: %s\n", D(sel).UTF8String);
		return 3;
	}
}
