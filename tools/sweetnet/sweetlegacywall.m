/*
 * sweetlegacywall IMAGE   make IMAGE (PNG/JPEG) the legacy lock and home wallpaper, the one PosterBoard's LegacyPoster
 *                         extension (com.apple.PaperBoard.LegacyPoster) draws as a plain picture
 * Run as root over SSH: it switches to mobile first, because the wallpaper lives in mobile's store
 * (~mobile/Library/SpringBoard/ ...Background files, com.apple.springboard defaults) that PaperBoardUI's default
 * PBUIWallpaperConfigurationManager reads in the extension.
 *
 * Why not sweetwallpaper's Photos poster: on this phone it needs subject segmentation saved as HEIC (no HEVC encoder here)
 * and CoreImage compute kernels, so PosterBoard rejects its home screen. A legacy poster only shows the picture.
 * Then select a LegacyPoster configuration with sweetposterset (sweetposterset com.apple.PaperBoard.LegacyPoster LegacyPoster).
 * Exit status: 0 set, 1 PaperBoardUI refused, 2 usage/IO.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

@interface PBUIWallpaperConfigurationManager : NSObject
- (BOOL)setWallpaperImage:(UIImage *)image originalImage:(UIImage *)original forVariants:(long long)variants options:(unsigned long long)options;
@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		if (argc != 2) {
			fprintf(stderr, "usage: sweetlegacywall IMAGE\n");
			return 2;
		}
		NSData *d = [NSData dataWithContentsOfFile:@(argv[1])];
		if (!d) { printf("cannot read %s\n", argv[1]); return 2; }
		if (getuid() == 0) {
			/* mobile's preferences and home, before anything touches CFPreferences */
			setenv("HOME", "/var/mobile", 1);
			setenv("CFFIXED_USER_HOME", "/var/mobile", 1);
			if (setgid(501) || setuid(501)) { perror("setuid mobile"); return 2; }
		}
		UIImage *img = [UIImage imageWithData:d];
		if (!img) { printf("not an image: %s\n", argv[1]); return 2; }
		printf("image %.0fx%.0f scale %.0f\n", img.size.width, img.size.height, img.scale);
		/* PaperBoardUI calls UIImage categories of PosterUIFoundation (-pui_CGImageBackedImage) it does not link itself */
		dlopen("/System/Library/PrivateFrameworks/PosterUIFoundation.framework/PosterUIFoundation", RTLD_NOW);
		if (!dlopen("/System/Library/PrivateFrameworks/PaperBoardUI.framework/PaperBoardUI", RTLD_NOW)) {
			printf("dlopen PaperBoardUI: %s\n", dlerror());
			return 2;
		}
		PBUIWallpaperConfigurationManager *m = [[NSClassFromString(@"PBUIWallpaperConfigurationManager") alloc] init];
		if (!m) { printf("no PBUIWallpaperConfigurationManager\n"); return 2; }
		/* variants: a bit per variant, 1 lock and 2 home */
		BOOL ok = [m setWallpaperImage:img originalImage:img forVariants:3 options:0];
		printf("setWallpaperImage (lock+home): %s\n", ok ? "ok" : "refused");
		CFPreferencesAppSynchronize(CFSTR("com.apple.springboard"));
		return ok ? 0 : 1;
	}
}
