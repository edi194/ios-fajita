/*
 * GlassTest.app (com.bergamota.glasstest): iOS 26 Liquid Glass bring-up on Chlorophyll. Coloured stripes with a UIGlassEffect
 * view over them, so what backboardd draws for real glass is on screen (sweetshot), and 2 s after launch the glass view's layer
 * tree -- classes, filters, SDF effects -- is written to /var/mobile/tmp/glasstest.txt: the recipe the offscreen
 * bgmtl_carenderer_probe rebuilds without a window. Launch: sweetopen com.bergamota.glasstest
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <sys/stat.h>

static void
dump(FILE *f, CALayer *l, int depth)
{
	fprintf(f, "%*s%s %.0fx%.0f at %.0f,%.0f%s opacity %.2f", depth * 2, "", class_getName([l class]), l.bounds.size.width,
	        l.bounds.size.height, l.position.x, l.position.y, l.hidden ? " hidden" : "", l.opacity);
	if (l.compositingFilter) fprintf(f, " compositing=%s", [[l.compositingFilter description] UTF8String]);
	fprintf(f, "\n");
	for (id flt in l.filters) fprintf(f, "%*s  filter %s\n", depth * 2, "", [[flt description] UTF8String]);
	for (id flt in l.backgroundFilters) fprintf(f, "%*s  backgroundFilter %s\n", depth * 2, "", [[flt description] UTF8String]);
	/* the SDF layers keep their recipe in properties of their own; their description names them */
	if (strstr(class_getName([l class]), "SDF") || strstr(class_getName([l class]), "Backdrop")) {
		for (NSString *k in @[ @"effect", @"effects", @"elements", @"shape", @"cornerRadius", @"groupName", @"scale" ]) {
			id v = nil;
			@try { v = [l valueForKey:k]; } @catch (id e) { continue; }
			if (v) fprintf(f, "%*s  %s = %s\n", depth * 2, "", k.UTF8String, [[v description] UTF8String]);
		}
	}
	for (CALayer *c in l.sublayers) dump(f, c, depth + 1);
}

@interface GTDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation GTDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts
{
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	UIViewController *vc = [UIViewController new];
	UIView *root = vc.view;
	CGRect b = root.bounds;
	for (int i = 0; i < 12; i++) {
		UIView *s = [[UIView alloc] initWithFrame:CGRectMake(i * b.size.width / 12, 0, b.size.width / 24, b.size.height)];
		s.backgroundColor = [UIColor colorWithHue:i / 12.0 saturation:0.9 brightness:0.95 alpha:1];
		[root addSubview:s];
	}
	root.backgroundColor = UIColor.whiteColor;
	UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
	glass.frame = CGRectMake(40, b.size.height / 2 - 100, b.size.width - 80, 200);
	glass.layer.cornerRadius = 50;
	[root addSubview:glass];
	UILabel *t = [[UILabel alloc] initWithFrame:glass.contentView.bounds];
	t.text = @"Liquid Glass";
	t.textAlignment = NSTextAlignmentCenter;
	t.font = [UIFont boldSystemFontOfSize:34];
	t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[glass.contentView addSubview:t];
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		mkdir("/var/mobile/tmp", 0755);
		FILE *f = fopen("/var/mobile/tmp/glasstest.txt", "w");
		if (!f) return;
		fprintf(f, "glass view %s, effect %s\n", class_getName([glass class]), [[glass.effect description] UTF8String]);
		dump(f, glass.layer, 0);
		fclose(f);
	});
	return YES;
}
@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([GTDelegate class]));
	}
}
