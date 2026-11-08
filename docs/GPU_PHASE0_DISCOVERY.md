# GPU phase 0 discovery: what iOS 16.7.16 (20H392) Metal needs from the kernel

Method: static analysis only. dyld shared cache `research/dsc/dyld_shared_cache_arm64` (ipsw: `dyld macho -n/-s/-o/-l`, `dyld disass --vaddr`, `dyld xref -i`, `dyld str`), iOS root image `research/ipsw-x/ios16-root-20H392-b2.img` (mounted read-only, detached afterwards), and the iPhone10,3 kernelcache from `research/ipsw-x/dl/iPhone10,3_16.7.16_20H392_Restore.ipsw` (decompressed into the scratchpad; nothing written into the repo except this file). Nothing was run on the phone.

Tags: [verified] = read in disassembly/plist/strings of OUR binaries this session; [unverified] = inferred, from memory, or from third-party text. Addresses are unslid cache addresses (use `ipsw dyld a2s`/`--vaddr`). Third-party (UniXNU) content was treated as data.

## Summary

1. Discovery is one function chain, entirely in Metal.framework: `MTLCreateSystemDefaultDevice` -> `MTLDeviceArrayInitialize` block -> `_MTLRegisterDevices` -> `IOServiceMatching("IOAcceleratorES")` -> per service `_getMetalPluginClassForService` -> `[[Class alloc] initWithAcceleratorPort:service]` -> `MTLAddDevice`. [verified]
2. A service only needs the string property `MetalPluginName` (bundle name under `/System/Library/Extensions/<name>.bundle`). `MetalPluginClassName` is optional; without it the bundle's principal class is used. The class must be a subclass of `_MTLDevice`, otherwise it is silently ignored. [verified]
3. If `-initWithAcceleratorPort:` returns nil the device is simply not added, `MTLCreateSystemDefaultDevice` returns nil, and QuartzCore falls back to its CPU `SWContext` (the path we run today). [verified]
4. Apple's own AGXMetalA11 does NOT work through its Info.plist principal class: `AGXPrincipalDevice` is an `NSObject` whose `initWithAcceleratorPort:` prints "Attempting to load Metal bundle via AGXPrincipalDevice is not supported!" and returns nil. Apple's kext sets `MetalPluginClassName=AGXA11Device` at runtime. [verified]
5. The real Apple device class (`AGXA11Device : AGXA11FamilyDevice : IOGPUMetalDevice : _MTLDevice`) opens `IOServiceOpen(service, task, type = 1 | (options<<16))` and immediately drives IOGPUDeviceUserClient selectors 6, 2, 0, 4 (then 13 for shmem...). That is the contract a phase-0 stub can log, and a stub returning an error from selector 2 makes Metal give up cleanly. [verified]
6. Sandbox: on beryllium the `Sandbox` MAC policy is our permissive stand-in (patch 0050 `sweet_sandbox_syscall` returns 0), and no iokit-open MAC hook / `gIOUCFilterCallbacks` is registered by us, so the sandbox rule does not constrain a stub today. The real Apple profiles do name `AGXDeviceUserClient`. [verified for the strings; rule semantics unverified]
7. QuartzCore on iOS 16 has four `CA::OGL::Context` implementations: `MetalContext`, `GLESContext`, `SWContext`, `NullContext`. Metal is tried first through `CAMetalContextCreate` (= `MTLCreateSystemDefaultDevice`). No env var found that forces software; software is chosen purely when Metal (and GLES) context creation fails. GLES on iOS 16 is Metal-backed. [verified]

## 1. Metal.framework / IOGPU.framework discovery

### 1.1 IOKit class matched [verified]

`_MTLRegisterDevices` at `0x181b144c8` (Metal):
- `IOMasterPort(bootstrap_port, &mp)`; failure -> `NSLog("%s: IOMasterPort failed %x", "MTLRegisterDevices", rc)`.
- `IOServiceMatching("IOAcceleratorES")` (string at `0x181b773ad`), `IOServiceGetMatchingServices`; failure -> `NSLog("%s: IOServiceGetMatchingServices failed %x")`.
- Loop `IOIteratorNext`: for each service `cls = _getMetalPluginClassForService(svc)`; if `cls` -> `dev = [[cls alloc] initWithAcceleratorPort:svc]` (mach port = the io_service_t); if `dev` -> `_MTLAddDevice(dev)`; release; `IOObjectRelease(svc)`.

So the class is **IOAcceleratorES** (not IOGPU). Apple's AGX personality (kernelcache prelink info, kext `com.apple.AGXG10P`, personalities `AGXG10P_A0/B0`) is: `IOMatchCategory=IOAcceleratorES`, `IOClass=AGXAcceleratorG10P_B0`, `IOProviderClass=AppleARMIODevice`, `IONameMatch=gpu,t8015`, `IOGLESBundleName=AppleMetalGLRenderer`, `MetalPluginName=AGXMetalA11` (A0: `AGXMetalG10A0`). [verified]. `IOAcceleratorES` and `IOGPU` are kernel classes defined in IOGPUFamily (kalloc sites `IOAcceleratorES`, `IOGPU` in the kernelcache), `AGXAcceleratorG10P` is built on them. [verified for strings; inheritance order IOGPU : IOAcceleratorES is from UniXNU docs, unverified]

Whether XNU's `IOServiceMatching` (IOProviderClass key) also matches subclasses of IOAcceleratorES: [unverified] (no xnu source tree in this repo; AGX itself relies on this because the match class is `IOAcceleratorES` while the concrete class is AGXAcceleratorG10P_B0). Safest stub: define an IOService subclass literally named/derived from `IOAcceleratorES`.

Who triggers it: `___MTLDeviceArrayInitialize_block_invoke` (`0x181a34050`), run once (dispatch_once) from `_MTLCreateSystemDefaultDevice` (`0x181a37760`) and `MTLCopyAllDevices`; it also reads `METAL_LOAD_INTERPOSER`, `METAL_CAPTURE_ENABLED`, `MetalCaptureEnabled`/`MetalForceCaptureEnabled`, `MTL_HUD_ENABLED` (debug-layer wrappers; irrelevant) and then calls `_MTLRegisterDevices`. `MTLCreateSystemDefaultDevice` returns the single array element; more than one device -> `MTLReportFailure("doesn't know what to do with more than one device")` (`0x181a37050`). [verified] So the stub must publish exactly ONE IOAcceleratorES service that yields a device.

### 1.2 Properties read [verified]

`_getMetalPluginClassForService` at `0x181a3c7c8`:
1. `IORegistryEntryCreateCFProperty(svc, "MetalPluginName")`; must be a CFString, else nil.
2. Path = `[@"/System/Library/Extensions" stringByAppendingPathComponent:name]` + `".bundle"`; `[NSBundle bundleWithPath:]`; nil -> nil.
3. `IORegistryEntryCreateCFProperty(svc, "MetalPluginClassName")`: if present and CFString -> `[bundle classNamed:]`; if absent/not string/class not found -> `[bundle principalClass]`.
4. Result must satisfy `[cls isSubclassOfClass:[_MTLDevice class]]`, else nil (silently, no log).

IOGPU.framework also embeds the strings `MetalPluginName` / `MetalPluginClassName` (`0x1ece3328e`, `0x1ece332c1`, plus a copy at `0x20d660xxx`) for its own plugin loader. AGXGPURawCounter reads `MetalPluginName` too. [verified strings; their code paths not traced]

Not read on the init path (only by Xcode/Instruments helpers): `MetalStatisticsName`, `GPUConfigurationVariable`, `gpu-core-count`. [verified by string owners: DVTInstrumentsFoundation, MetalPerformanceShadersGraph]. GLES additionally reads `IOGLESBundleName` / `IOGLESMetalBundleName` (libGFXShared, template `/System/Library/Extensions/%s.bundle`). [verified]

### 1.3 Where the bundle is loaded from [verified]

`/System/Library/Extensions/<MetalPluginName>.bundle` on the root volume, via NSBundle. On the image: `/System/Library/Extensions/AGXMetalA11.bundle` (contents: Info.plist, ~32 `N_M.bin` firmware/shader blobs, `default`-style metallibs `metal_rt*.metallib`, `ds.g10p`, counter plists, `_CodeSignature`). The executable `AGXMetalA11` is NOT a file in the bundle: it lives inside the dyld shared cache as `/System/Library/Extensions/AGXMetalA11.bundle/AGXMetalA11`. NSBundle/dlopen therefore resolves it from the cache. A custom bundle for our plugin must exist as a real file on disk (a normal Mach-O in the bundle directory, or a cache-less dylib). [verified for AGX; our bundle's loadability under AMFI/trust cache is [unverified] (our AMFI stand-in `sweet_amfi_vnode_check_signature` is permissive per NOTES)]

### 1.4 Principal-class contract [verified]

- Must be an ObjC subclass of `_MTLDevice` (Metal private base).
- Must override `-initWithAcceleratorPort:(io_service_t)port`. The base `-[_MTLDevice initWithAcceleratorPort:]` (`0x181aab968`) is `[self doesNotRecognizeSelector:_cmd]; return nil;`, i.e. it RAISES an NSException. A plugin class that forgets the override aborts the host process (SpringBoard/backboardd). 
- Ownership: Metal does `objc_alloc`, `initWithAcceleratorPort:`, `MTLAddDevice` (which retains), `objc_release`. Metal releases the io_service_t itself right after (`IOObjectRelease`); a plugin that wants to keep using the service must `IOObjectRetain` it (the code in `-[MTLIOAccelDevice initWithAcceleratorPort:]` does).
- Nil return: Metal skips `MTLAddDevice`; if no service yields a device `_deviceArray` stays empty and `MTLCreateSystemDefaultDevice` returns nil (block at `0x181a37050`: `count==0` -> leaves result NULL). No logging, no retry (dispatch_once). So nil is a clean "no GPU". [verified]
- Superclass chain Metal expects for Apple devices (for reference): `AGXA11Device : AGXA11FamilyDevice : IOGPUMetalDevice : _MTLDevice` ([verified] via `ipsw dyld macho AGXMetalA11 -o` and `IOGPU -o`); `MTLIOAccelDevice : _MTLDevice` is the older IOAccelerator-based class in Metal itself.

### 1.5 What the real device init does with the kernel [verified]

`-[AGXA11Device initWithAcceleratorPort:]` (`0x209e0b2f8`) -> `-[AGXA11FamilyDevice initWithAcceleratorPort:simultaneousInstances:0x800]` (`0x209e13d40`) -> `-[IOGPUMetalDevice initWithAcceleratorPort:options:]` (`0x1ece185dc`) -> `IOGPUDeviceCreateWithAPIProperty(port, "Metal", options)` (`0x1ece1ce38`):

```
IOServiceOpen(service, mach_task_self(), type = 1 | (options << 16), &conn)   // options < 0x1000, 0x800 for AGX
IOConnectCallStructMethod(conn, sel 6, in 16B "Metal", no out)               // result ignored
IOConnectCallStructMethod(conn, sel 2, no in, out 0x218B)                    // MUST succeed, else device = NULL
IOConnectCallStructMethod(conn, sel 0, no in, out 0x40B  -> device+0xa0)     // must succeed, else device = NULL
IOConnectCallStructMethod(conn, sel 4, no in, out 0x20B)                     // optional (result ignored)
```
- sel 0 output `IOGPUDeviceConfigData` (64 B) as consumed by `IOGPUDeviceGetConfig64` (`0x1ece1a98c`): u32 configBits @0, u32 deviceBits @4, u64 textureRam @8, u64 videoRam @0x10, u32 accelID @0x18.
- sel 2 output (0x218 B): u64 base address @0 (userland VA of a kernel-created mapping), u32 @0x14 = region count N, u32 offsets from @0x18 (region 0 = base+off0, region i = base+off[i]); more fields @8..@0x13 copied into the device ref. The kernel (IOGPUDeviceUserClient) has to create a task mapping of its shared RO data and return the address in-band; no IOConnectMapMemory is involved. [verified for use; field meaning beyond this unverified]
- sel 4: u64 @0 (and @0x10 if size >= 4 words?) used for `___globalGPUCommPage`; failure tolerated.
- Then `IOGPUDeviceGetSharedMemorySize`, `IOGPUDeviceGetGlobalTraceObjectID`, and four IOGPUMetalDeviceShmem pools (`IOGPUDeviceCreateDeviceShmem` = selector 13, 2 scalars in, 16 B struct out, then `IOConnectMapMemory`), suballocator, command buffer storage pool; any failure -> device nil. Then AGXA11Device `setupCompiler:` dlopens `/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore` (+ XPC AGXCompilerService); failure -> nil.

Older Metal-internal path (`-[MTLIOAccelDevice initWithAcceleratorPort:]` `0x181abd76c`, IOAccelerator.framework `IOAccelDeviceCreateWithAPIProperty` `0x1b301440c`) opens type 1, uses selectors 7/2(0x258 B)/0(0x40 B)/5 and `IOAccelSharedCreate` opens type 2 ; it is NOT used by A11 (the kernelcache has no IOAcceleratorFamily user clients: no `IOAccelDevice`/`IOAccelSharedUserClient` strings). [verified]. For `IOAccelDeviceCreateWithAPIProperty` the kernel also returns a symbol NAME in the sel-2 struct that userland resolves with `dlsym(RTLD_SELF, name)`; failure -> NULL device. Only relevant if you write a MTLIOAccelDevice subclass.

### 1.6 External-method table of IOGPUDeviceUserClient [verified table decode, names partly unverified]

Decoded from IOGPUFamily `__DATA_CONST` in the kernelcache: IOExternalMethodDispatch table at kernel VA `0xfffffff006fc6a90`, 50 live entries (`in_scalar,in_struct,out_scalar,out_struct`): 0:(0,0,0,64) 1:(0,0,0,64) 2:(0,0,0,536) 3:(0,0,0,8) 4:(0,0,0,32) 5:(0,0,0,16) 6:(0,16,0,any) 7:(0,1032,0,16) 8:(1,0,0,0) 9:(0,any,0,any) 10:(1,0,0,0) 11:(2,0,0,0) 12:(2,0,1,0) 13:(2,0,0,16) 14:(1,0,0,0) 15:(2,0,0,16) 16:(1,0,0,0) 17:(0,0,0,8) 18:(0,0,0,4) 19:(1,0,0,0) 20:(0,0,2,0) 21:(1,0,0,0) 22:(0,0,0,48) 23:(0,0,0,any) 24:(0,0,1,0) 25:(2,0,0,0) 26:(4,any,0,0) 27:(1,12,1,0) 28:(1,4,0,0) 29..49 smaller scalar-only methods. A second 50-entry block follows (entries 50..99, same shape but many replaced by the common stub `0x...2ebcc`), probably the table AGXDeviceUserClient layers on top; unverified. The sizes of selectors 0,2,4,6,13 match the userland calls above exactly, which validates the decode. Kernel handlers by name (strings): `s_new_command_queue`, `s_delete_command_queue`, `s_new_resource`, `s_submit_command_buffers`, `s_create_vniodesc`, `s_create_io_command_queue`, `s_async_signal_mtlLateEvalevent`, `s_query_mtlLateEvalevent`, `s_submit_io_commands`, ... [verified strings; selector index to name mapping unverified]. AGXG10P's own table at `0xfffffff006fcfec0` has 2 entries ((0,0,0,0) and (2,0,0,0)).

## 2. AGXMetalA11.bundle [verified]

`System/Library/Extensions/AGXMetalA11.bundle/Info.plist`: `CFBundleIdentifier=com.apple.AGXMetalA11`, `CFBundleExecutable=AGXMetalA11`, `CFBundlePackageType=BNDL`, `CFBundleVersion=227.6.5`, `MinimumOSVersion=16.7`, `CFBundleSupportedPlatforms=[iPhoneOS]`, `UIDeviceFamily=[1]`, `UIRequiredDeviceCapabilities=[arm64]`, **`NSPrincipalClass=AGXPrincipalDevice`**. No `MetalPluginName`/`MetalPluginClassName` keys inside the bundle (those live on the IOKit service).
- `AGXPrincipalDevice : NSObject` (not `_MTLDevice`), only method `-initWithAcceleratorPort:` at `0x209e5e4d8` -> `fwrite` "Attempting to load Metal bundle via AGXPrincipalDevice is not supported!" + os_log, returns nil. So it is a guard against loading via principal class.
- The effective class comes from the kernel: AGXG10P writes `MetalPluginClassName = "AGXA11Device"` (string pair `MetalPluginClassName`/`AGXA11Device`/`MetalStatisticsName`/`AGXMetalStatisticsExternalA11` in the decompressed iPhone10,3 kernelcache at file offset `0x1108010`, next to the string `AGXG10P_B0`; presumably set from AGXAcceleratorG10P_B0 code, unverified). [verified]
- Chain: `AGXA11Device : AGXA11FamilyDevice : IOGPUMetalDevice : _MTLDevice` [verified].
- User client type opened: IOServiceOpen type `1 | (0x800<<16)`, kernel class **AGXDeviceUserClient** (kernelcache string with kalloc site `site.AGXDeviceUserClient`; derives IOGPUDeviceUserClient). No second IOServiceOpen is performed by IOGPU/AGXMetalA11/Metal on this path (`IOServiceOpen` imported once, in IOGPU). Command queues/resources are created via selectors on this connection (kernel names `AGXCommandQueue`, `IOGPUCommandQueue`, `IOGPUIOCommandQueue`, `AGXShared*` exist as kernel classes; whether userland opens separate connections for them is [unverified]).

## 3. Sandbox

Findings [verified unless noted]:
- iOS profiles are not files in the root image: no `/System/Library/Sandbox` and no compiled profile there (searched the whole mounted root). They are in the sandbox kext (`com.apple.security.sandbox 300.0`) inside the kernelcache. libsandbox in the cache has op names `iokit-open*`, `iokit-open-user-client`, `iokit-open-service`, `iokit-get-properties`, `iokit-set-properties`, `iokit-external-method`, `iokit-async-external-method`, `iokit-external-trap` (sandbox kext strings at kernelcache offsets ~`0xF2E7AF`/`0xF2F2F0`) plus entitlement filters `com.apple.security.iokit-user-client-class` and `com.apple.security.exception.iokit-user-client-class`. The literal `iokit-method-number` does NOT occur in the kernelcache nor in the cache's libsandbox; selector restriction exists only as ops/filters inside the compiled bundle, which I could not decompile (no sandbox decompiler here). The exact allowed selector lists are therefore [unverified].
- The compiled profile collection contains the class name literal `AGXDeviceUserClient` at least five times, in iokit-user-client-class allow lists next to `IOSurfaceRootUserClient`, `IOMobileFramebufferUserClient`, `AppleJPEGDriverUserClient`, `IOSurfaceAcceleratorClient`, `H11ANEInDirectPathClient`, and the prefix-compressed fragments `AGX|Device|CommandQueue|SharedUserClient` (suggesting AGXDeviceUserClient, AGXCommandQueue, AGXSharedUserClient are all admitted for some profiles). The sandbox checks the user-client CLASS NAME of the object returned by `newUserClient`, so a stub whose client class is named `AGXDeviceUserClient` passes the class filter of the real profiles. Entitlement forms exist as an alternative. [verified for strings; mapping to specific processes unverified]
- A property allow-list for `IOAcceleratorES` appears in a profile: `AGXParameterBufferMaxSize, OGLES, InternalStatistics, Accm..., MetalStatisticsName, PerformanceStatisticsAccum` (iokit-get-properties). `MetalPluginName` is not in that neighbouring list; where it is allowed is [unverified].
- On beryllium: the sandbox is `xnu/patches/0050-sweet-sandbox-policy.patch` (permissive policy "Sandbox": `mpo_policy_syscall` returns 0 except ENOENT for ops 4,5,6,0x43). No `mpo_iokit_check_open`, no `mpo_iokit_check_get_property`, no `gIOUCFilterCallbacks` are installed by us, so IOServiceOpen of any user-client class and every external method are allowed. [verified from the patch text and NOTES; XNU's `is_io_service_open_extended` behaviour with no hooks is [unverified] here (no xnu source in this repo)]. Practical consequence: naming the class `AGXDeviceUserClient` is not needed now, but is free and keeps the stub valid if a real sandbox is ever added.

## 4. QuartzCore

[verified] unless marked.
- `CA::OGL::Context` has four implementations: `MetalContext` (`new_metal_context` `0x188487e28`), `GLESContext` (`GLESContext::GLESContext(void*)` `0x18840960c`), `SWContext` (`sw_new_context` `0x1884409d0`), `NullContext`.
- Display path (backboardd): `CA::WindowServer::IOMFBDisplay::get_ctx` block (`0x18853bff0`): `dev = CAMetalContextCreate()`; if non-nil -> `new_metal_context(dev, ..., "com.apple.coreanimation.IOMFBDisplay")`, else context stays NULL. `CAMetalContextCreate` (`0x18838421c`) is literally `MTLCreateSystemDefaultDevice()` inside an autorelease pool. Other callers of `CAMetalContextCreate`: `EAGLServer::renderer`, `VirtualServer::renderer`, `AsynchronousDispatcher::renderer`, `CA::CG::AccelRenderer::acquire`, `create_cgimage_from_iosurface`.
- Fallback: `CA::WindowServer::Server::render_update` and `render_surface` call `Server::sw_renderer()` (`0x1884f4c54`) when `renderer()` is NULL; `sw_renderer` mallocs an `SWContext`, builds `CA::OGL::Renderer` on it and logs `"CoreAnimation: Software renderer! Simulating crash!"` and `"CoreAnimation: Failed to initialize Metal or OpenGLES contexts!"`. That is our current CPU path. `EAGLServer::renderer` (`0x1882eaf3c`) tries Metal first, then GLES only if `CA::WindowServer::enable_ogl` (set from env `CA_ENABLE_OGL`, read in `EAGLServer::EAGLServer` `0x1883da11c`), else NULL -> software.
- No env var/default that forces software exists in the CA_* list (full list extracted: CA_NO_ACCEL is read only by `CA::CG::AccelQueue` to disable CG accelerated backing; CA_DISABLE_RENDER disables rendering altogether; CA_FORCE_LOCAL_SERVER, CA_ACCEL_BACKING, CA_DISABLE_PRECOMPILED_PIPELINES, CA_ENABLE_OGL are tuning/debug). Software is chosen only by failing device creation. So "make Metal fail" == status quo and "make Metal succeed" switches CA to MetalContext with no further opt-in. [verified]
- GLES on iOS 16 is Metal-backed: `GLEngine.bundle/GLEngine` links no Metal and no IOAccelerator, but the renderer plug-in `/System/Library/Extensions/AppleMetalGLRenderer.bundle/AppleMetalGLRenderer` (selected by the `IOGLESBundleName=AppleMetalGLRenderer` service property read in libGFXShared) links `Metal.framework` and `libGLImage` and ships `default.metallib`. So GLES also needs `MTLCreateSystemDefaultDevice`. [verified]

## 5. Comparison with UniXNU NativeMetal/NativeAdreno (data, fetched 2026-10-19)

- UniXNU stage-1 plugin (`drivers/NativeMetal/NativeAdrenoMetalPlugin.mm`) states the same discovery chain: IOAcceleratorES -> MetalPluginName -> NSBundle -> principal class -> `initWithAcceleratorPort:`; its principal class `NativeAdrenoMetalDevice : _MTLDevice` overrides the init and returns nil (so it uses the principal-class branch of step 3, matching our verified `getMetalPluginClassForService`). It runs its GPU test on a separate thread and keeps an extra port reference because Metal releases the port when init returns. Consistent with the Metal code above.
- UniXNU names its user-client class `AGXDeviceUserClient` for the sandbox class filter (matches strings in our kernelcache sandbox data) and serves only its own private open type (`0x4147<<16 | x`), refusing IOGPU's `type 1 | api<<16` with kIOReturnUnsupported, then tunnels its ABI through whichever selectors the profile admits. Our finding: selectors 0/2/4/6/13 are what Apple's userland actually calls, so a stub that emulates IOGPUDeviceUserClient does not need a private open type nor tunnelling; but a private plugin (our own `_MTLDevice` subclass) is still the practical route for phases 1-3 because Apple's AGXMetalA11 binary generates A11 GPU ISA and cannot drive Adreno.
- Differences: UniXNU's kernel side is a custom driver on SM8550; ours must additionally provide the `IOAcceleratorES` service (UniXNU's Info.plist personalities are GPU/SMMU/GMU only; its `IOAcceleratorES` class comes from its own `OriginalAcceleratorABI.h` shim). Not re-verified.

## 6. Phase-0 kernel stub checklist (what Metal needs in order to try our bundle)

Goal of phase 0: make Metal reach `-initWithAcceleratorPort:` in our own plugin and observe every IOKit touch, while still returning nil (CPU rendering unchanged).

Kernel (XNU, IOKit):
1. [ ] One IOService instance that `IOServiceMatching("IOAcceleratorES")` returns (class named `IOAcceleratorES` or derived from it; prefer `IOMatchCategory=IOAcceleratorES` property too). Call `registerService()`. Exactly one such service (Metal asserts on two devices).
2. [ ] Property `MetalPluginName` (OSString) = bundle directory name, e.g. `BerylliumMetal` -> `/System/Library/Extensions/BerylliumMetal.bundle`. Log every `copyProperty/getProperty` of it with `proc_selfname` (the reader is SpringBoard/backboardd/any Metal process).
3. [ ] Optional property `MetalPluginClassName` (OSString) if the bundle's NSPrincipalClass is not the device class (needed only to mimic Apple; AGX's principal class is a deliberate dead end).
4. [ ] Optional: `IOGLESBundleName` (e.g. `AppleMetalGLRenderer` only when a real Metal device exists; omit in phase 0 so GLES stays off).
5. [ ] `newUserClient(task, secID, type, props, handler)` override: log `type` (expect `1 | (0x800<<16)` = `0x08000001` if Apple's `IOGPUMetalDevice` were driven), `proc_selfname`; client class named `AGXDeviceUserClient` (subclass of IOUserClient; `clientClose`/`free` implemented).
6. [ ] `externalMethod(selector, args)` on it: log selector, input struct size, scalar counts, output struct size, in call order. For phase 0 return `kIOReturnUnsupported` for everything (selector 2 failing makes IOGPU's `IOGPUDeviceCreateWithAPIProperty` return NULL -> clean nil device). Expected observed order only if Apple's IOGPUMetalDevice is entered: 6 (16 B in), 2 (0x218 B out), 0 (0x40 B out), 4 (0x20 B out), 13 (2 scalars in, 16 B out). Sizes must match the dispatch table above if you later answer them.
7. [ ] No sandbox work needed (stand-in policy 0050 allows IOServiceOpen and all selectors); keep the class name anyway.
8. [ ] No `IOGPUDeviceUserClient` memory mappings in phase 0 (`clientMemoryForType` not needed until selector 2/13 are answered).

Userland (rootfs, `/System/Library/Extensions/BerylliumMetal.bundle`):
9. [ ] Bundle dir + Info.plist (`CFBundleExecutable`, `CFBundleIdentifier`, `NSPrincipalClass=BerylliumMetalDevice`, `CFBundlePackageType=BNDL`).
10. [ ] Mach-O arm64 executable linked against Metal.framework with ObjC class `BerylliumMetalDevice : _MTLDevice` overriding `-initWithAcceleratorPort:(unsigned)port`: log (os_log/NSLog + write to a file), `IOObjectRetain(port)` if kept, then `return nil` in phase 0. MUST override (base implementation raises an exception). Class must not be `final`-hidden: `[cls isSubclassOfClass:_MTLDevice]` must be true.
11. [ ] File must be loadable under our AMFI stand-in (unsigned/ad-hoc; verify dlopen from SpringBoard/backboardd) [unverified].
12. [ ] Expected trigger: any process calling `MTLCreateSystemDefaultDevice` (backboardd's `CAMetalContextCreate` from IOMFBDisplay/EAGLServer). Verify with the kernel log of step 2 and the plugin log.

Success criteria: kernel shows `MetalPluginName` read by backboardd, plugin log shows `initWithAcceleratorPort:` called once with a valid port; backboardd still renders through `SWContext`. Next gate (phase 0.5): return a non-nil device only after implementing a full `_MTLDevice` subclass (UniXNU's frontend as a template); otherwise Metal-using processes crash on unimplemented MTLDevice SPI.

## Open questions / unverified

- `iokit-method-number`/selector allow-lists of real profiles (needs a compiled-profile decompiler on the kernelcache sandbox kext).
- Whether XNU `IOServiceMatching("IOAcceleratorES")` matches a subclass instance without extra properties (no xnu source in repo; AGX relies on it).
- Selector index -> handler name mapping in IOGPUDeviceUserClient (table decoded, names only from strings).
- Whether an unsigned plugin bundle can be dlopen'ed in SpringBoard/backboardd on our trust setup.
- Layout of the sel-2 output beyond base/count/offsets, and of the sel-4 output.
