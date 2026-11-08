/*
 * sweetwallpaper IMAGE          make IMAGE (PNG/JPEG) the lock and home wallpaper: a Photos poster created by PosterBoard
 *                               itself, selected for the lock screen, the same image on the home screen
 * sweetwallpaper --lock IMAGE   lock screen only
 * sweetwallpaper --home IMAGE   home screen only, for the lock poster that is selected now (after the create succeeded
 *                               in PosterBoard but the reply failed, and sweetposterset --uuid selected the poster)
 *   e.g. sweetwallpaper /var/mobile/Media/Bergamota/wallpaper.png    (tools/identity/mkwallpaper.sh renders the
 *        Bergamota one)
 * Run as root over SSH or via SweetRun. The image is copied first to /var/mobile/Media/Bergamota/ (mobile-owned), where
 * PosterBoard, which runs as mobile, can read it.
 *
 * API (PosterBoardServices, see sweetposter-prs.h): PRSExternalSystemService createLockScreenPhotosPosterWithImageAtURL:
 * selectLockScreenPoster:completion: (completes with (poster, NSError)), then updateHomeScreenImageForLockScreenPoster:
 * withImageAtURL:selectLockPoster:completion: for the home screen. PosterBoard has to have a working data store: with
 * "Data store could not be created" (seen on the first iOS 26 boots) every call fails, and sweetposterset --list shows it.
 * Exit status: 0 set, 1 PosterBoard refused (the NSError is printed), 2 usage/IO, 3 timed out.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "sweetposter-prs.h"

static int
wait_for(dispatch_semaphore_t s, int seconds)
{
	for (int i = 0; i < seconds * 10; i++) {
		if (!dispatch_semaphore_wait(s, DISPATCH_TIME_NOW)) return 0;
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	}
	return -1;
}

static NSString *
describe(id o)
{
	return o ? [o description] : @"(null)";
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		BOOL lock_only = NO, home_only = NO;
		int a = 1;
		if (argc > 1 && !strcmp(argv[1], "--lock")) { lock_only = YES; a = 2; }
		if (argc > 1 && !strcmp(argv[1], "--home")) { home_only = YES; a = 2; }
		if (argc <= a) {
			fprintf(stderr, "usage: sweetwallpaper [--lock|--home] IMAGE\n");
			return 2;
		}

		/* a copy PosterBoard (user mobile) can read */
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *src = @(argv[a]);
		NSString *dir = @"/var/mobile/Media/Bergamota";
		NSString *dst = [dir stringByAppendingPathComponent:[@"wallpaper." stringByAppendingString:[src pathExtension].length ? [src pathExtension] : @"png"]];
		NSError *e = nil;
		[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{ NSFileOwnerAccountName: @"mobile", NSFileGroupOwnerAccountName: @"mobile" } error:nil];
		if (![src isEqualToString:dst]) {
			[fm removeItemAtPath:dst error:nil];
			if (![fm copyItemAtPath:src toPath:dst error:&e]) {
				printf("copy %s -> %s failed: %s\n", src.UTF8String, dst.UTF8String, describe(e).UTF8String);
				return 2;
			}
		}
		[fm setAttributes:@{ NSFileOwnerAccountName: @"mobile", NSFileGroupOwnerAccountName: @"mobile", NSFilePosixPermissions: @0644 } ofItemAtPath:dst error:nil];
		NSURL *url = [NSURL fileURLWithPath:dst];
		printf("image: %s\n", dst.UTF8String);

		if (!dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_NOW)) {
			printf("dlopen PosterBoardServices: %s\n", dlerror());
			return 2;
		}
		PRSExternalSystemService *ext = [[NSClassFromString(@"PRSExternalSystemService") alloc] init];
		if (!ext) {
			printf("no PRSExternalSystemService class\n");
			return 2;
		}

		__block id poster = nil;
		__block NSError *err = nil;
		dispatch_semaphore_t s = dispatch_semaphore_create(0);
		if (home_only)
			[[NSClassFromString(@"PRSService") new] fetchSelectedPosterForRole:@"PRPosterRoleLockScreen" completion:^(id p, id er) {
				poster = p; err = er;
				dispatch_semaphore_signal(s);
			}];
		else
			[ext createLockScreenPhotosPosterWithImageAtURL:url selectLockScreenPoster:YES completion:^(id p, id er) {
				poster = p; err = er;
				dispatch_semaphore_signal(s);
			}];
		if (wait_for(s, 30)) { printf("TIMEOUT %s the lock screen poster\n", home_only ? "fetching" : "creating"); return 3; }
		printf("lock poster: %s\n", describe(poster).UTF8String);
		if (!poster) {
			printf("PosterBoard refused: %s\n", describe(err).UTF8String);
			return 1;
		}
		if (lock_only) return 0;

		s = dispatch_semaphore_create(0);
		__block id home = nil;
		err = nil;
		[ext updateHomeScreenImageForLockScreenPoster:poster withImageAtURL:url selectLockPoster:YES completion:^(id p, id er) {
			home = p; err = er;
			dispatch_semaphore_signal(s);
		}];
		if (wait_for(s, 30)) { printf("TIMEOUT setting the home screen image\n"); return 3; }
		if (err) {
			printf("home screen: PosterBoard refused: %s\n", describe(err).UTF8String);
			return 1;
		}
		printf("home screen: %s\n", describe(home).UTF8String);
		return 0;
	}
}
