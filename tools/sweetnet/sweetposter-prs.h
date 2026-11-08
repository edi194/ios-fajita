@interface PRSService : NSObject
- (void)fetchPosterConfigurationsForRole:(id)role completion:(void(^)(id,id))c;
- (void)fetchPosterConfigurations:(void(^)(id,id))c;
- (void)fetchExtensionIdentifiersWithCompletion:(void(^)(id,id))c;
- (void)fetchSelectedPosterForRole:(id)role completion:(void(^)(id,id))c;
- (void)fetchActivePosterConfiguration:(void(^)(id,id))c;
- (void)fetchSelectedConfiguration:(void(^)(id,id))c;
- (void)fetchGallery:(void(^)(id,id))c;
- (void)createPosterConfigurationForProviderIdentifier:(id)p posterDescriptorIdentifier:(id)d role:(id)r completion:(void(^)(id,id))c;
- (void)fetchPosterDescriptorsForExtension:(id)e completion:(void(^)(id,id))c;
/* Block signatures read from the 22H352 dyld cache (the -[PRSService ...] implementations call the completion with
 * exactly these arguments): the update and delete completions take ONE argument, the NSError; the fetch/create ones
 * take (result, NSError). Declaring a second parameter reads a stale register (it printed an os_log object). */
- (void)updateToSelectedConfigurationMatchingUUID:(id)u role:(id)r completion:(void(^)(id))c;
- (void)updateToSelectedConfigurationMatchingUUID:(id)u completion:(void(^)(id))c;
- (void)deletePosterConfigurationsMatchingUUID:(id)u completion:(void(^)(id))c;
- (void)updatePosterConfiguration:(id)p update:(id)u completion:(void(^)(id,id))c;
- (void)updatePosterConfigurationMatchingUUID:(id)u updates:(id)up completion:(void(^)(id,id))c;
@end
@interface PRSPosterUpdate : NSObject
+ (id)posterUpdateHomeScreenTintForColor:(id)c;
+ (id)posterUpdateHomeScreenAppearance:(unsigned long)a;
+ (id)posterUpdateHomeScreenSuggestedTintColor:(id)c;
+ (id)posterUpdateHomeScreenColor:(id)c;
@end
@interface PRSExternalSystemService : NSObject
- (id)service;
- (void)createLockScreenPhotosPosterWithImageAtURL:(id)u selectLockScreenPoster:(BOOL)s completion:(void(^)(id,id))c;
- (void)updateHomeScreenImageForLockScreenPoster:(id)p withImageAtURL:(id)u selectLockPoster:(BOOL)s completion:(void(^)(id,id))c;
@end
