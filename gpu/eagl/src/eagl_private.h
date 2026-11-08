// SPDX-License-Identifier: MIT
// Private EAGL SPI that QuartzCore (22H352) calls on EAGLContext. Signatures are the method type encodings
// read from the real OpenGLES.framework in the iOS 18.7.8 dyld cache (names and types only).
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/EAGLIOSurface.h>
#import <IOSurface/IOSurfaceRef.h>
#import <dispatch/dispatch.h>

typedef struct EAGLMacroContext EAGLMacroContext;   // opaque in Apple's binary; see docs/GPU_EAGL.md

@interface EAGLContext (BergamotaPrivate)
- (instancetype)initWithAPI:(EAGLRenderingAPI)api properties:(NSDictionary *)props;
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharedWithCompute:(BOOL)compute;
- (EAGLMacroContext *)getMacroContextPrivate;
+ (EAGLMacroContext *)GetMacroContextPrivate;
- (EAGLMacroContext *)GetMacroContextPrivate;
- (BOOL)attachImage:(NSUInteger)image toCoreSurface:(IOSurfaceRef)surface invertedRender:(BOOL)inverted;
- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane invert:(BOOL)invert;
- (BOOL)setBlockFence:(void (^)(void))block onQueue:(dispatch_queue_t)queue;
- (NSUInteger)setParameter:(uint32_t)param to:(int *)value;
- (NSUInteger)getParameter:(uint32_t)param to:(int *)value;
@end

@interface EAGLSharegroup (BergamotaPrivate)
- (instancetype)initWithAPI:(EAGLRenderingAPI)api;
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharedWithCompute:(BOOL)compute;
- (NSUInteger)APIs;
- (void *)getGLIShared;
@end

// Bergamota test/diagnostic SPI (not in Apple's library).
extern const char *EAGLShimVersionString(void);
