#import <Foundation/Foundation.h>
#include <dlfcn.h>
extern int SBSLaunchApplicationWithIdentifier(CFStringRef, Boolean);
int main(int c,char**v){ dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",RTLD_NOW);
 int (*f)(CFStringRef,Boolean)=dlsym(RTLD_DEFAULT,"SBSLaunchApplicationWithIdentifier");
 int r=f((__bridge CFStringRef)[NSString stringWithUTF8String:v[1]],0); printf("launch %s -> %d\n",v[1],r); return r;}
