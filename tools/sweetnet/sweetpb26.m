// sweetpb26.dylib: PosterBoard on iOS 26 over Heartwood (the iOS 26 counterpart of sweetfp.m), linked into a re-signed
// /Applications/PosterBoard.app/PosterBoard as a weak LC_LOAD_DYLIB. The root is HFS without data protection (no SEP) and
// without APFS, and PosterBoard treats what that cannot do as fatal: no data store, then no poster could be created. Each
// swizzle below drops only the part this filesystem cannot carry. Inert in every other process.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>

/* No URL ever reports the NSURLFileProtectionKey PosterBoard expects ([PBFPosterModelStoreCoordinator
 * expectedURLResourceValuesForDirectories]): _PBFDetermineDataStoreViabilityForVersionWithinBaseURL finds every data store
 * "not viable", the 59 -> 61 migration fails and PosterBoard has no data store ("Data store could not be created"). The
 * check keeps every other resource value. */
static IMP orig_conforms, orig_reachable;
static NSDictionary *
without_protection(NSDictionary *expected)
{
	if (![expected objectForKey:NSURLFileProtectionKey]) return expected;
	NSMutableDictionary *m = [expected mutableCopy];
	[m removeObjectForKey:NSURLFileProtectionKey];
	return m;
}
static BOOL
pb_conforms(id self, SEL _cmd, NSDictionary *expected, NSError **error)
{
	return ((BOOL (*)(id, SEL, NSDictionary *, NSError **))orig_conforms)(self, _cmd, without_protection(expected), error);
}
static BOOL
pb_reachable(id self, SEL _cmd, NSDictionary *expected, NSError **error)
{
	return ((BOOL (*)(id, SEL, NSDictionary *, NSError **))orig_reachable)(self, _cmd, without_protection(expected), error);
}

/* NSData writes with a protection class (the NSDataWritingFileProtection* bits, 0xF0000000) are refused here: PosterBoard's
 * +createNewStoreCoordinatorWithPath:error: writes its identifier files with NSDataWritingAtomic | ...FileProtectionNone. The
 * atomic write is kept. */
static IMP orig_wurl, orig_wfile;
static BOOL
pb_write_url(id self, SEL _cmd, NSURL *url, NSDataWritingOptions opts, NSError **error)
{
	return ((BOOL (*)(id, SEL, NSURL *, NSDataWritingOptions, NSError **))orig_wurl)(self, _cmd, url, opts & ~(NSDataWritingOptions)0xF0000000, error);
}
static BOOL
pb_write_file(id self, SEL _cmd, NSString *path, NSDataWritingOptions opts, NSError **error)
{
	return ((BOOL (*)(id, SEL, NSString *, NSDataWritingOptions, NSError **))orig_wfile)(self, _cmd, path, opts & ~(NSDataWritingOptions)0xF0000000, error);
}

/* -[NSURL pbf_setPurgable:error:] uses the APFS purgeable fsctl, which fails (-1) on HFS, and PosterBoard turned that into
 * generalErrorDomain errno=-1 for every new poster. Purgeability is only a hint to the cache delete service. */
static BOOL
pb_set_purgable(id self, SEL _cmd, BOOL purgable, NSError **error)
{
	return YES;
}

/* -[PBFPosterRoleCoordinator finalizeChangesWithChangeHandler:outEvents:error:] runs for every role at the end of each
 * data-store transaction. StandBy's empty PRPosterRoleAmbient has no default poster here (the Infograph extension is
 * missing, -2220), returns NO, and that rolled back every transaction (SQLite error 4), a new lock-screen poster included.
 * Only that role is forgiven. The storage and outEvents (an out pointer) arguments pass through untouched. */
static IMP orig_finalize;
static BOOL
pb_finalize(id self, SEL _cmd, void *handler, void *outEvents, NSError **error)
{
	BOOL ok = ((BOOL (*)(id, SEL, void *, void *, NSError **))orig_finalize)(self, _cmd, handler, outEvents, error);
	if (!ok && [[self valueForKey:@"role"] isEqual:@"PRPosterRoleAmbient"]) {
		if (error) *error = nil;
		return YES;
	}
	return ok;
}

static IMP
swap(Class c, NSString *sel, IMP imp)
{
	Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(sel)) : NULL;
	return m ? method_setImplementation(m, imp) : NULL;
}

__attribute__((constructor)) static void
sweetpb26_init(void)
{
	if (strcmp(getprogname(), "PosterBoard")) return;
	orig_conforms = swap([NSURL class], @"pbf_URLConformsToExpectedResourceValues:error:", (IMP)pb_conforms);
	orig_reachable = swap([NSURL class], @"pbf_URLIsReachableAndConformToResourceValues:error:", (IMP)pb_reachable);
	orig_wurl = swap([NSData class], @"writeToURL:options:error:", (IMP)pb_write_url);
	orig_wfile = swap([NSData class], @"writeToFile:options:error:", (IMP)pb_write_file);
	swap([NSURL class], @"pbf_setPurgable:error:", (IMP)pb_set_purgable);
	orig_finalize = swap(NSClassFromString(@"PBFPosterRoleCoordinator"), @"finalizeChangesWithChangeHandler:outEvents:error:", (IMP)pb_finalize);
}
