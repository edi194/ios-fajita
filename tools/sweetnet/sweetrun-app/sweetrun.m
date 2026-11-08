/*
 * SweetRun: tiny app that runs /private/var/tmp/sweetrun.sh inside the
 * mobile user's launchd domain (an app launched by FrontBoard lives there,
 * unlike the root SSH session) so private per-user XPC services such as
 * PosterBoard's com.apple.posterboardservices.services can be reached.
 * Output: /private/var/tmp/sweetrun.log
 */
#import <UIKit/UIKit.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
@interface D : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow *window;
@end
@implementation D
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.backgroundColor = UIColor.blackColor;
	self.window.rootViewController = [UIViewController new];
	[self.window makeKeyAndVisible];
	dispatch_async(dispatch_get_global_queue(0, 0), ^{
		pid_t pid;
		char *argv[] = {"sh", "-c", "/bin/sh /private/var/tmp/sweetrun.sh > /private/var/tmp/sweetrun.log 2>&1", NULL};
		if (posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ) == 0) {
			int st; waitpid(pid, &st, 0);
		}
		dispatch_async(dispatch_get_main_queue(), ^{ exit(0); });
	});
	return YES;
}
@end
int main(int argc, char **argv) {
	@autoreleasepool { return UIApplicationMain(argc, argv, nil, @"D"); }
}
