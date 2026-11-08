/*
 * sweeticonstyle default|auto|dark|light|R,G,B : set the home-screen icon style through SBSHomeScreenService
 * (`default` = not tinted). Run as mobile via SweetRun. Needs com.apple.sharesheet.allow-custom-view
 * (iconstyle.entitlements). Prints the current and the new configuration.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
@interface SBSHomeScreenIconStyleConfiguration : NSObject
+ (id)tintedStyleConfigurationWithTintColor:(id)c;
+ (id)darkStyleConfiguration; + (id)lightStyleConfiguration; + (id)automaticStyleConfiguration; + (id)defaultStyleConfiguration;
@end
@interface SBSHomeScreenService : NSObject
- (id)homeScreenIconStyleConfiguration;
- (void)setHomeScreenIconStyleConfiguration:(id)c;
- (id)iconTintColor;
@end
int main(int argc,char**argv){@autoreleasepool{ setvbuf(stdout,0,_IOLBF,0);
 dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",RTLD_NOW);
 SBSHomeScreenService*s=[[NSClassFromString(@"SBSHomeScreenService") alloc] init];
 printf("cur: %s tint=%s\n",[[[s homeScreenIconStyleConfiguration] description] UTF8String],[[[s iconTintColor] description] UTF8String]);
 if(argc>1){ double r,g,b; id cfg;
   if(!strcmp(argv[1],"default")) cfg=[NSClassFromString(@"SBSHomeScreenIconStyleConfiguration") defaultStyleConfiguration];
   else if(!strcmp(argv[1],"auto")) cfg=[NSClassFromString(@"SBSHomeScreenIconStyleConfiguration") automaticStyleConfiguration];
   else if(!strcmp(argv[1],"dark")) cfg=[NSClassFromString(@"SBSHomeScreenIconStyleConfiguration") darkStyleConfiguration];
   else if(!strcmp(argv[1],"light")) cfg=[NSClassFromString(@"SBSHomeScreenIconStyleConfiguration") lightStyleConfiguration];
   else { sscanf(argv[1],"%lf,%lf,%lf",&r,&g,&b); UIColor*c=[UIColor colorWithRed:r green:g blue:b alpha:1];
     cfg=[NSClassFromString(@"SBSHomeScreenIconStyleConfiguration") tintedStyleConfigurationWithTintColor:c]; }
   [s setHomeScreenIconStyleConfiguration:cfg];
   [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
   printf("new: %s\n",[[[s homeScreenIconStyleConfiguration] description] UTF8String]);
 }
}return 0;}
