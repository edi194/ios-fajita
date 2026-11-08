/*
 * sweetfp.dylib: emulate NSURLFileProtectionKey on our HFS+ data volume.
 *
 * The HFS+ root has no data-protection classes, so setResourceValue:forKey:
 * NSURLFileProtectionKey "succeeds" but reading the key back returns nil.
 * iOS 18 PosterBoard validates the protection class of its data store after
 * creating it (pbf_URLIsReachableAndConformToResourceValues:error:), sees nil,
 * fails with "Failed to migrate to Version 61 from 59" and never creates the
 * wallpaper store.
 *
 * This library swizzles the four NSURL resource-value accessors so that the
 * protection class a caller sets is kept in an extended attribute and read
 * back later, which makes such validations consistent. It is linked into
 * /Applications/PosterBoard.app/PosterBoard as an extra LC_LOAD_DYLIB (see
 * addlc.py): dyld ignores DYLD_INSERT_LIBRARIES for platform binaries.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <sys/xattr.h>
#include <unistd.h>

#define XA "com.sweet.fileprotection"

static NSString *
xa_get(NSURL *u)
{
	if (!u.isFileURL)
		return nil;
	char buf[128];
	ssize_t n = getxattr(u.fileSystemRepresentation, XA, buf, sizeof buf - 1, 0, XATTR_NOFOLLOW);
	if (n <= 0)
		return nil;
	return [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
}

static void
xa_set(NSURL *u, id v)
{
	if (!u.isFileURL || ![v isKindOfClass:[NSString class]])
		return;
	const char *s = [(NSString *)v UTF8String];
	setxattr(u.fileSystemRepresentation, XA, s, strlen(s), 0, XATTR_NOFOLLOW);
}

static void
swz(SEL sel, id (^block_factory)(IMP orig))
{
	Method m = class_getInstanceMethod([NSURL class], sel);
	if (!m)
		return;
	IMP orig = method_getImplementation(m);
	method_setImplementation(m, imp_implementationWithBlock(block_factory(orig)));
}

__attribute__((constructor)) static void
sweetfp_init(void)
{
	swz(@selector(setResourceValue:forKey:error:), ^id(IMP orig) {
		return ^BOOL(NSURL *self_, id v, NSURLResourceKey k, NSError **e) {
			BOOL r = ((BOOL(*)(id, SEL, id, id, NSError **))orig)(self_, @selector(setResourceValue:forKey:error:), v, k, e);
			if ([k isEqualToString:NSURLFileProtectionKey])
				xa_set(self_, v);
			return r;
		};
	});
	swz(@selector(setResourceValues:error:), ^id(IMP orig) {
		return ^BOOL(NSURL *self_, NSDictionary *d, NSError **e) {
			BOOL r = ((BOOL(*)(id, SEL, id, NSError **))orig)(self_, @selector(setResourceValues:error:), d, e);
			id v = d[NSURLFileProtectionKey];
			if (v)
				xa_set(self_, v);
			return r;
		};
	});
	swz(@selector(getResourceValue:forKey:error:), ^id(IMP orig) {
		return ^BOOL(NSURL *self_, id *vp, NSURLResourceKey k, NSError **e) {
			BOOL r = ((BOOL(*)(id, SEL, id *, id, NSError **))orig)(self_, @selector(getResourceValue:forKey:error:), vp, k, e);
			if ([k isEqualToString:NSURLFileProtectionKey] && (!r || *vp == nil)) {
				NSString *x = xa_get(self_);
				if (x) {
					if (vp)
						*vp = x;
					if (e)
						*e = nil;
					return YES;
				}
			}
			return r;
		};
	});
	swz(@selector(resourceValuesForKeys:error:), ^id(IMP orig) {
		return ^id(NSURL *self_, NSArray *keys, NSError **e) {
			NSDictionary *d = ((id(*)(id, SEL, id, NSError **))orig)(self_, @selector(resourceValuesForKeys:error:), keys, e);
			if ([keys containsObject:NSURLFileProtectionKey] && d && d[NSURLFileProtectionKey] == nil) {
				NSString *x = xa_get(self_);
				if (x) {
					NSMutableDictionary *m = [d mutableCopy];
					m[NSURLFileProtectionKey] = x;
					return m;
				}
			}
			return d;
		};
	});
}
