# GPU_EAGL: replacement OpenGLES.framework over Mesa (phases A + B of `METAL_ADRENO630.md`; phase E software side at the end)

Status 2026-10-23, branch `gpu-eagl`. Everything below marked **[phone]** was run on the Poco F1 (iOS 18.7.8 22H352 on Heartwood xnu-11215) with the test tool only;
the system OpenGLES.framework was not touched and nothing runs inside backboardd yet.

## What this is

`gpu/eagl/` is our own implementation of the userland half of the GLES route:

```
app / QuartzCore (later)            gpu/eagl/src/eagl.m   EAGLContext, EAGLSharegroup, drawable + IOSurface glue (ObjC, MIT)
  gl* C entry points  ----------->  gpu/eagl/src/gl_stubs.c  457 generated trampolines, one per export of the real framework
                                    gpu/eagl/src/gl_resolve.c  fills the trampoline table from Mesa's glapi dispatcher
                                    gpu/eagl/src/osm.c         the only file that includes <GL/osmesa.h>
                                         |
                                    libOSMesa.8.dylib  (Mesa 25.0.7, gallium softpipe, OSMesa frontend, no LLVM)
                                         |   phase E: the same frontend over gallium freedreno (a6xx) + an msm-DRM user client
                                    IOSurface (BGRA) handed to CoreAnimation / IOMobileFramebuffer
```

* **Exports match the real library exactly.** `nm -gU` of the shim equals the export trie of `OpenGLES.framework` in the 22H352 dyld cache: 491 symbols = 457
  `gl*` functions (ES1 + ES2 + ES3 + extensions incl. the `*OES`/`*EXT`/`*APPLE` aliases), `EAGLGetVersion`, `EAGLGetCurrentMacroContextPrivate`,
  `EAGLMemoryNotificationRecycling`, `GLIContextFromEAGLContext`, 9 `GLC*` dispatch functions, 21 `kEAGL*` string constants, `EAGLContext`/`EAGLSharegroup` classes
  (+ `_OBJC_IVAR_$_EAGLContext._private`). The shim has one extra export, `EAGLShimVersionString` (ours). The name list comes from the public SDK `OpenGLES.tbd`
  (`tools/gen_gl_stubs.py`), the comparison with the cache from `tools/dsc_oglinfo.py exports` (names only, nothing from Apple's binary is stored in git).
* **ObjC surface = the real class's method list** (types read from the cache with `tools/dsc_oglinfo.py objc`): `initWithAPI:`, `initWithAPI:sharegroup:`,
  `initWithAPI:properties:`, `initWithAPI:sharedWithCompute:`, `+setCurrentContext:`, `+currentContext`, `renderbufferStorage:fromDrawable:`,
  `presentRenderbuffer:` (+ `atTime:`, `afterMinimumDuration:`), the IOSurface selectors QuartzCore calls
  (`attachImage:toCoreSurface:invertedRender:` is `B36@0:8 Q16 ^{__IOSurface=}24 B32`, `texImageIOSurface:target:internalFormat:width:height:format:type:plane:[invert:]`),
  `getMacroContextPrivate`/`GetMacroContextPrivate`, `setBlockFence:onQueue:`, `setParameter:to:`/`getParameter:to:`, `multiThreaded`, `debugLabel`;
  `EAGLSharegroup` `initWithAPI:`, `APIs`, `getGLIShared`, `debugLabel`.

## How the drawing path works

* Each `EAGLContext` is one OSMesa context created as an **OpenGL ES** context (ES1: API_OPENGLES, ES2/ES3: API_OPENGLES2; Mesa gives the highest ES it supports, softpipe: ES 3.1)
  with a 16x16 dummy default framebuffer (GLES clients never render to it). This needs the one-hunk patch `gpu/eagl/mesa/0001-osmesa-es-profile.patch` (new OSMesa
  profile `0x36`); stock OSMesa can only create desktop GL contexts. Sharegroups map to OSMesa share lists.
* `renderbufferStorage:fromDrawable:` reads `bounds` and `contentsScale` of the drawable (a `CAEAGLLayer`, or anything that answers them) and the colour format
  property, and calls `glRenderbufferStorage` at that pixel size.
* `presentRenderbuffer:` reads the bound renderbuffer back (own scratch FBO, GL state restored), converts RGBA to BGRA, flips to top-down, copies into the next
  IOSurface of a 3-surface pool and sets `drawable.contents = surface` (alpha forced to 255 when `isOpaque`).
* `attachImage:toCoreSurface:invertedRender:` records (renderbuffer-or-texture name, IOSurface, inverted); our `glFlush`/`glFinish` wrappers (installed over the
  Mesa entries of the trampoline table) copy every attached image into its IOSurface. This is the sync point CoreAnimation's GLES renderer needs before it swaps the surface to the display.
* `texImageIOSurface:...` copies the surface pixels (BGRA or RGBA 8888, plane 0) into the bound texture via `glTexImage2D`, optionally flipped (`invert:`).
* Unmapped/unsupported entry points log once (`OpenGLES(shim): glFoo is not implemented`, stderr) and return 0. Debug markers/labels and `glDiscardFramebufferEXT` are no-ops.
  Vendor-suffix aliases (`glBindVertexArrayOES` -> `glBindVertexArray`, `glVertexAttrib4f` -> `...ARB`, ...) are resolved at load time.
* `EAGL_SHIM_DEBUG=1` prints context/drawable/attach events and the list of unresolved entry points.

Copies are CPU copies (softpipe renders in system memory anyway); the IOSurface is never shared with the GPU in this phase.

## Build

Needs Xcode (iphoneos SDK), `brew install meson bison` (meson also in the venv), network for the Mesa clone. Build trees live outside the repo.

```
export GPU_EAGL_WORK=/some/scratch/dir               # ~1.6 GB for Mesa, <200 MB for the rest
gpu/eagl/mesa/build-mesa.sh                          # clone mesa-25.0.7, apply the patch, meson cross build (arm64e), ~4 min on M-series
gpu/eagl/build.sh                                    # shim + tests -> $GPU_EAGL_WORK/out-arm64e/
```

Mesa options (see `build-mesa.sh`): `-Dgallium-drivers=softpipe -Dllvm=disabled -Dosmesa=true -Dgles1=enabled -Dgles2=enabled -Dshared-glapi=enabled
-Dglx/egl/gbm=disabled -Dplatforms=` (EGL cannot be built without a platform; OSMesa is the minimal frontend, it was removed upstream in 25.1, hence the pinned 25.0.7).
llvmpipe was not attempted (needs an LLVM cross build; not practical here).

Binaries are built `-arch arm64e -miphoneos-version-min=18.0` and then rewritten for the A-series-less SDM845:

```
python3 tools/renegade/pacstrip.py --sign FILE       # = renegade strip --sign ; ad-hoc signature is accepted by our kernel
```

Every file needed it (the shim had 457 `braaz` from the trampolines, libOSMesa ~40k PAC instructions). Pushing: `scp -O` to `/var/root/gpu-eagl/` (layout:
`eagl_test`, `libOSMesa.8.dylib`, `OpenGLES.framework/OpenGLES`; the shim's rpath is `@loader_path/..`, the test's `@executable_path`).

`SHIM_INSTALL_NAME=/System/Library/Frameworks/OpenGLES.framework/OpenGLES gpu/eagl/build.sh` produces a shim with the system install name for a future root image; by default
the install name is `@rpath/...` so a test can never accidentally load the system framework.

Sizes (arm64e, after `strip -x`): shim `OpenGLES` 154 KB, `libOSMesa.8.dylib` 13.5 MB (softpipe + GLSL compiler + glapi), `eagl_test` 77 KB.

## Test

`gpu/eagl/test/eagl_test.m` links the shim by path and runs 38 checks (exit status = failures; `--bench`, `--dump FILE.ppm`):

* ES2 and ES3 contexts: create, make current, FBO + `renderbufferStorage:fromDrawable:` (fake `CAEAGLLayer` stand-in), shader compile/link (GLSL ES 1.00 and 3.00),
  clear + triangle, `presentRenderbuffer:` delivers a 128x128 BGRA IOSurface; apex pixel red at the **top**, below the triangle blue, corner blue (orientation, swizzle, alpha).
* `attachImage:toCoreSurface:invertedRender:` + `glFinish` fills the IOSurface top-down; `texImageIOSurface:` (BGRA to RGBA, `invert:YES` flips); sharegroup visibility
  of textures (shared and unrelated context); ES1 context + fixed-function call.

**[phone, 2026-10-23]** `RESULT: 38 passed, 0 failed` (34 before the macro-context checks); GL_VERSION `OpenGL ES 3.1 Mesa 25.0.7`, GL_RENDERER `softpipe`; IOSurface creation/locking works from an arm64e tool. Rendered frame
checked visually (red triangle on blue). Speed on one SDM845 core: 128x128 triangle + readback + present about 1 ms/frame; **750x1334 full-screen textured quad + present
about 560 ms/frame** (softpipe is a reference rasteriser: usable for correctness, not for compositing a UI; that is what phase E is for).

## What is NOT done / known gaps

0. The phone test ran once (two pushes of about 14 MB to `/var/root/gpu-eagl/`) before the coordinator paused phone writes (xnu-11215 hangs and corrupts userdata). Treat that directory as untrusted and delete it when the phone is usable again; no further device tests were done.

1. **Not injected anywhere.** The system framework is unchanged; QuartzCore/backboardd still use their own (Metal-backed, no device) OpenGLES. Whether QuartzCore's GLES renderer is
   enabled without `CA_ENABLE_OGL` on 22H352 is still unverified (see `METAL_ADRENO630.md` b3).
2. ~~`getMacroContextPrivate` zeroed block~~ **done 2026-10-23**: the macro context is populated (section "Macro context" below); QuartzCore's `CARenderer` renders through it on the phone.
3. `attachImage:` takes a GL object name (`Q`): the shim guesses renderbuffer vs texture with `glIsTexture/glIsRenderbuffer`; the real semantics (e.g. mipmap level, MSAA) are unverified.
4. ES2 contexts report GL_VERSION ES 3.1 (Mesa gives the highest); Apple reports 2.0 for ES2 contexts. `MESA_GLES_VERSION_OVERRIDE` could cap it per process.
5. Not implemented (forward to a logging stub), computed statically against Mesa's glapi table (the on-phone `EAGL_SHIM_DEBUG=1` listing could not be run, the phone went offline again): 17 of 457, namely the Apple fence extension (`glGenFencesAPPLE`, `glSetFenceAPPLE`, `glTestFenceAPPLE`, `glFinishFenceAPPLE`, `glDeleteFencesAPPLE`, `glIsFenceAPPLE`), `glFinishObjectAPPLE`, `glTestObjectAPPLE`, `glResolveMultisampleFramebufferAPPLE`, `glGetFramebufferParameteriAPPLE` and the matrix-palette OES set (4). Note `GL_APPLE_fence` is one of the extensions QuartzCore probes (section below).
6. Only 8-bit 4-byte IOSurfaces (BGRA/RGBA, plane 0) for `texImageIOSurface:`; no XR10/wide-colour formats, no YUV planes.
7. `GLC*` dispatch-selection functions are no-ops (they swap the real GLEngine's function tables).
8. Single-threaded softpipe; no `multiThreaded` fast path; `setBlockFence:onQueue:` finishes synchronously.
9. arm64 (non-e) build not produced; the kernel's `sweetarm64e=1` path loads the arm64e slices (this is what the tool ran as).

## Next steps

1. **Freedreno instead of softpipe (phase E), once the kernel msm-DRM user client exists.** Only `libOSMesa` changes: build Mesa with `-Dgallium-drivers=freedreno`
   (a6xx, chip id 0x06030001 for the Adreno 630) and a winsys that talks to the user client instead of `/dev/dri` (the kernel-backend interface of `src/freedreno/drm/` is
   small: bo new/info/cpu_prep, submit, wait-fence, submit-queues, GET_PARAM), keeping the OSMesa-style frontend or moving to a surfaceless `pipe_screen` + `st_api`
   frontend of our own. Our shim keeps working unchanged; the readback copy then becomes a blit/`resource_get_handle` into the IOSurface (UBWC off, linear), which removes
   the CPU copy. Prerequisites: stage 6/7 of `GPU_A630_BRINGUP.md` (zap shader, CP), BO manager + IOVA/SMMU mapping, fences.
2. Decode `EAGLMacroContext` use in QuartzCore 22H352, then inject the shim into a detached test process first, then backboardd (DYLD interpose of the framework path
   or a root-image replacement with `SHIM_INSTALL_NAME`).
3. Confirm the unresolved-entry-point list on the phone and add the missing Apple extensions that apps use (fences).

## How QuartzCore reaches GL (static analysis of 22H352, 2026-10-23)

Method: `tools/renegade/dsctools` + a capstone scan of QuartzCore `__text` (addresses are unslid cache addresses; QuartzCore = 0x18470f000).

1. **CoreAnimation does not call the `gl*` exports; it uses the macro context.** The only caller of `-[EAGLContext getMacroContextPrivate]` is at 0x1848f9728
   (the OGL context constructor, 0x1848f968c). It stores the result at `this+0x840` and then calls `glGetString`-like functions as `(*(ctx+0x3b0))(*(ctx+0), name)`,
   i.e. the CGL macro convention: **`EAGLMacroContext` == `struct _CGLContextObject { GLIContext rend; GLIFunctionDispatch disp; ... }`** (macOS `OpenGL/CGLContext.h`, `gliDispatch.h`):
   `rend` at +0 is passed as the first argument of every call, function pointers start at +8 (slot i at 8+8*i), signature `fn(rend, args...)`.
   Check: slot 117 = `get_string` in the public macOS header = offset 0x3b0, exactly what QuartzCore loads. It then probes `GL_APPLE_fence`, `GL_APPLE_texture_filter_cubic`,
   `GL_APPLE_texture_ycbcr_*`, `GL_APPLE_texture_xr`, `GL_APPLE_tile_order_rot`, `GL_EXT_shader_framebuffer_fetch`, `GL_EXT_texture_filter_anisotropic`, `GL_EXT_texture_lod_bias`,
   `GL_OES_standard_derivatives`, `GL_OES_texture_[half_]float[_linear]`, `GL_IMG_texture_compression_pvrtc`, `GL_KHR_texture_compression_astc_ldr` (strings at 0x184a6a0d7..) through the
   EXTENSIONS string, and honours `CA_DISABLE_WORKAROUNDS`, `CA_MAX_TEXTURE_UNITS`, `CA_MAX_TEXTURE_SIZE`.
2. **Slot map is only partly public.** A scan of all `ldr x8,[ctx,#off]; ldr x0,[ctx]; blr x8` sites finds 49 offsets. The low ones fit the public macOS order and are what a GLES
   renderer needs first (bind_texture, clear, delete/gen_textures, disable/enable, draw_arrays, finish, get_integerv, get_string, pixel_storei, scissor, tex_parameteri/f, viewport,
   active_texture, blend_equation: offsets 0x30..0xab8). Offsets above about 0xbd0 do **not** match the macOS names (e.g. `draw_elements_base_vertex` x28, `program_env_parameter4f_ARB` x10), and
   no slot for `glTexImage2D`, `glUseProgram`, `glUniform*`, framebuffer calls shows up where the public order would put them: Apple's ES extension of the dispatch struct is ordered
   differently (shader/uniform/FBO/VAO functions). **The ES half of the slot map must be decoded from the real GLEngine's table** (the function-pointer array it copies into `disp`),
   or from the call-site argument shapes; it is not in any public header. The shim still returns a zeroed block (`getMacroContextPrivate`), so injected CA would crash on the first call.
   Plan: generate `disp[]` thunks (`fn(rend, a...)` -> `glFoo(a...)`) from `gliDispatch.h` + `CGLMacro.h` for the public part and a decoded table for the rest.
3. **`CA_ENABLE_OGL`:** the single reference (0x1848cf69c, in a CA::OGL object constructor) calls `getenv("CA_ENABLE_OGL")` once and **discards the result** (guard byte only). It does not gate GL
   at that site; no other reference exists. Other switches found: `CA_NO_ACCEL`, `CA_ACCEL_BACKING`, `CA_DISABLE_RENDER`, `CA_PRINT_SHADERS`, `CA_FORCE_GENERIC_SHADERS`, `CA_EMPTY_SHADERS`.
4. **Where the server creates its `EAGLContext` is not found.** QuartzCore has no selector reference to `initWithAPI*`/`sharegroup`, only `getMacroContextPrivate`, `attachImage:...`,
   `texImageIOSurface:...invert:`, `setCurrentContext:`, `API`, `nativeWindow`, `presentRenderbuffer:atTime:`; the renderer-selection code at 0x1849d1140..0x1849d1400 logs
   `Failed to initialize Metal or OpenGLES contexts!` and falls back to the software server. The context is probably created in another image (class refs go through the binding
   tables) or by the public `CARenderer rendererWithEAGLContext:options:` path (`_initWithEAGLContext:options:` at 0x184abdec0 is the callee used by it).

## Proposal: testing the shim under CoreAnimation without touching backboardd/SpringBoard

* **Step 1 (safe, separate process):** a test tool that creates our `EAGLContext`, builds a small CALayer tree and drives `+[CARenderer rendererWithEAGLContext:options:]`
  (`beginFrameAtTime:timeStamp:`, `addUpdateRect:`, `render`, `endFrame`) into an FBO backed by `attachImage:toCoreSurface:invertedRender:`. This exercises exactly `CA::OGL` through the macro
  context (everything in finding 1) with no render server involved, writes only to its own IOSurface, and a crash only kills the tool. Needs QuartzCore in the process
  (library load only) and the macro-context thunks from finding 2. Success criterion: the IOSurface contains the layer colours/image.
* **Step 2 (still isolated):** a tiny app/daemon with a `CAEAGLLayer` in its own `CAContext` is not useful without the live render server, so skip it; instead run a second, private render
  server only if needed (`CA_FORCE_LOCAL_SERVER` exists as a string in QuartzCore: a CA server inside the test process).
* **Step 3 (only after 1-2):** inject into backboardd by a launchd job override, not by replacing files: a copy of the `backboardd` plist in `/Library/LaunchDaemons` (or the existing
  job) with `EnvironmentVariables: DYLD_INSERT_LIBRARIES=/var/root/gpu-eagl/...` plus `DYLD_FRAMEWORK_PATH`; revert = delete the override file (and `launchctl bootout`/reboot). Fallback is
  automatic in CA (Metal -> GLES -> software), so a failing GLES init should land on the software path, but a crash loop must be assumed possible: keep an SSH session and a
  timed revert (`sleep 120; rm override; launchctl ...`) running before the first try. Do not do this until the on-device test of step 1 passes.

## Macro context and CoreAnimation step 1 (done on the phone, 2026-10-23, xnu-8796 ufsdmasync=1)

**Slot map: complete.** Every `gl*` export of the real OpenGLES.framework is a stub `mrs x8,tpidrro_el0; ldr ctx,[x8,#0xf0]` (current GLI context), then
`ldr fn,[ctx,#SLOT]` with the renderer at `[ctx,#0x20]`, argument shift, jump. QuartzCore's pointer is `ctx+0x20`, so macro offset = SLOT - 0x20 (checked against the offsets
QuartzCore uses: bind_texture 0x30, get_string 0x3b0, active_texture 0xab8, tex_parameteri 0x988 ...). `tools/dsc_slotmap.py` reads the 457 slot numbers from the cache and writes
`src/macro_slots.c` (names and numbers only). The earlier doubt about "ES half not in the public order" is resolved this way: Apple's ES functions simply sit at other offsets of
the same struct, and the stubs give them all. `src/macro_ctx.c` builds the block per context (`rend` = our private block, ~0x2200 bytes of slots), each slot a generated forwarder
`ms_glFoo` (drops `rend` by shifting x1..x7 down and tail-calls the Mesa entry); the 11 entry points with 8+ arguments (`glTexImage2D`, `glTexSubImage2D`, `glCopyTexImage2D`,
`glCopyTexSubImage2D`, `glCompressedTexSubImage2D`, the 3D variants, `glBlitFramebuffer`) have C wrappers because their arguments spill to the stack.
`eagl_test` checks it: slot 0x3b0 is glGetString, float arguments after `rend` (`glClearColor`), and a 9-argument `glTexImage2D` through the macro block.

**Injection mechanism (works in a single process).** The system OpenGLES lives in the dyld shared cache; `DYLD_FRAMEWORK_PATH` does not override it (tried: the system library
was loaded). Instead `EAGL_DEFS=-DEAGL_INJECT gpu/eagl/build.sh OUT` builds the shim with classes `BGEAGLContext`/`BGEAGLSharegroup`; its load-time constructor copies every method
(instance and class) into the REAL `EAGLContext`/`EAGLSharegroup` classes with `class_replaceMethod` (both have the single `_private` ivar). Anything that talks to those classes
(QuartzCore included) then reaches our code. The C `gl*` symbols of an app still bind to the system library (they use the thread's own TLS context, which is empty): a client of
the injected shim must reach GL through the macro context (CoreAnimation does) or through the shim's own exports (`dlsym`), as `eagl_ca_test` does.

**Step 1 result [phone].** `test/eagl_ca_test.m` (separate tool, nothing else touched): our context (ES3) + IOSurface-backed FBO (`attachImage:toCoreSurface:`), `+[CARenderer
rendererWithEAGLContext:options:]` on a layer tree (red root, green 128x128 sublayer), `beginFrame/addUpdateRect/render/endFrame`, `glFinish`. Result: `GL error 0`, IOSurface pixel (10,10) =
red and (128,128) = green, no "unmapped slot"/"not implemented" message, `RESULT: 0 failed`. So **CoreAnimation's GLES renderer (CA::OGL) runs on Mesa softpipe through this shim**, including
its extension probing (`GL_APPLE_*` strings are absent from Mesa and CA copes) and shader compilation. Run:

```
EAGL_DEFS=-DEAGL_INJECT gpu/eagl/build.sh $GPU_EAGL_WORK/out-inj      # also builds eagl_ca_test
(strip with pacstrip --sign; push eagl_ca_test, libOSMesa.8.dylib and OpenGLES.framework/OpenGLES keeping the layout; verify sha256 on the phone)
EAGL_INJECT_LIB=/var/root/gpu-eagl-inj/fw/OpenGLES.framework/OpenGLES ./eagl_ca_test
```

Operational notes: (1) delete a binary on the phone before pushing a new build of it: the kernel keeps the old code-signature limits per vnode and dyld then reports "code signature does not
cover entire file"; (2) unresolved entry points are now 14 of 457 (measured on the phone with `EAGL_SHIM_DEBUG=1`): the Apple fence set (6), `glFinishObjectAPPLE`, `glTestObjectAPPLE`,
`glResolveMultisampleFramebufferAPPLE`, `glGetFramebufferParameteriAPPLE`, and the four matrix-palette OES functions; (3) the injection build is for a process we control; backboardd injection stays
a separate, later, reversible step (launchd environment override, see the proposal above).

Not yet exercised by step 1: layers with image contents (`texImageIOSurface:`), shadows/blur/vibrancy shaders, many layers (the 560 ms/frame softpipe cost applies), `CAEAGLLayer` drawables, and the render
server's own use (`CA::WindowServer`, display-link, IOMFB swap). The remaining unknown from the static analysis is where the render server creates its `EAGLContext`.

## CARenderer scenes: results and frame times (256x256 target, softpipe, one SDM845 core; phone, 2026-10-23)

`test/eagl_ca_test.m` renders six scenes through real CA::OGL (separate tool). Checked on the phone with the build before the last two shim changes below:

| scene | result | ms/frame (3-5 frames, noisy) |
|---|---|---|
| 2 solid layers | red + green correct | 50-80 |
| CGImage layer (CA converts it to an IOSurface and calls `texImageIOSurface:...invert:`) | drawn, see orientation below | 31-40 |
| IOSurface as `layer.contents` | drawn | 30 |
| shadow (radius 12) | darkens the neighbourhood, far background untouched | 37-80 |
| `CAFilter gaussianBlur` backgroundFilter (radius 8, 192x192) | blurs the checker edge | 170-240 |
| `CAFilter colorSaturate 0` | desaturates | 260-450 |
| 300 translucent layers, half with corner radius | drawn | 320-540 |

Per-layer cost is a few ms, blur/saturate filters 200-400 ms at 256x256 (full-screen 750x1334 would be about 13x the pixels): softpipe is far from interactive; the numbers are the baseline for phase E.

Findings that changed the shim:
* **Orientation contract.** CA renders with a vertically flipped projection when it calls `attachImage:toCoreSurface:invertedRender:YES`, so the GL framebuffer rows already are the surface rows: the sync must copy WITHOUT flipping for `inverted=YES` (that is what the shim does) and flip for NO. The test therefore passes YES (with NO the whole scene came out mirrored).
* **Texture uploads.** CA calls `texImageIOSurface:...plane:invert:` with `invert:NO` while rendering inverted, and the pictures came out upside down with a plain row copy: the private variant now flips on upload when `invert` is NO (and not when YES); the public variant without `invert` keeps the rows as stored. **These two changes are built and the unit test is updated, but NOT yet run on the phone** (the phone went to fastboot for the xnu-11215 storage test right after the build; no files were left half-pushed: the push script failed at its first SSH command, before any copy). Expected on the next run: `eagl_test` 41 checks pass, `eagl_ca_test` image/IOSurface scenes pass with top green/bottom blue and top red/bottom green.
* Tracing aids added: `EAGL_TRACE=1` (macro-slot calls logged through trace thunks; `EAGLShimSetTrace(1)` toggles printing, `EAGL_TRACE_SHADERS=1` prints shader sources), `EAGL_DUMP=/dir` in `eagl_ca_test` writes each scene as PPM. Shader seen so far: CA's textured fragment shader is plain `texture2D(texture0, texcoord0_0)`; programs are compiled lazily per layer type.
* `texImageIOSurface` now sets complete default texture parameters (LINEAR, CLAMP_TO_EDGE); CA overrides them right after the call.
* Operational: the kernel caches code signatures per vnode, so always `rm` a binary on the phone before pushing a new build (the push scripts do).

## Plan for the backboardd experiment (NOT executed; needs the user's approval)

Goal: let the live render server (backboardd, which draws SpringBoard) load the injected shim, so CoreAnimation's GLES path runs on Mesa. Nothing below has been done.

1. **Files written on the phone** (all new, nothing existing edited or replaced):
   * `/var/root/gpu-eagl-inj/fw/OpenGLES.framework/OpenGLES` and `/var/root/gpu-eagl-inj/fw/libOSMesa.8.dylib` (pacstrip'd, ad-hoc signed, sha256-verified; already the layout used by the tests);
   * `/var/root/gpu-eagl-inj/revert.sh` (the undo, below);
   * the launchd override: a copy of the backboardd job plist with `EnvironmentVariables: DYLD_INSERT_LIBRARIES=/var/root/gpu-eagl-inj/fw/OpenGLES.framework/OpenGLES` (exact file/mechanism depends on how this image launches backboardd: the original plist stays untouched and its sha256 is recorded first; if the only way is editing the original, a `.orig` copy is made before and `revert.sh` copies it back).
2. **What must hold before the first try:** the CoreAnimation scenes above pass on the phone with the flip fixes; an SSH session stays open; the kernel is the stable one (xnu-8796, ufsdmasync=1) and the user has said when the phone can be used.
3. **Auto-revert (dead-man switch):** before touching launchd, start on the phone a detached `sh -c 'sleep 180; /var/root/gpu-eagl-inj/revert.sh'` (nohup, survives the SSH session; cancelled by killing it once the experiment is judged good). `revert.sh` removes the override (or restores the `.orig`), then restarts backboardd (`launchctl kickstart -k` / kill, which launchd respawns) so the next start has no injection. If backboardd crash-loops, the switch still fires; if the whole phone hangs, a power-cycle boots with the override still present, so the override is designed to be useless after a reboot unless re-armed: `DYLD_INSERT_LIBRARIES` points into `/var/root/gpu-eagl-inj` and `revert.sh` is also run once from `/etc` rc-style start? (to be decided with the coordinator; the safest variant is that the override file lives in `/tmp`-like volatile storage or carries a boot-id check so a reboot ignores it).
4. **What the user will see:** at the moment of the restart the screen goes black/blank for a few seconds while backboardd and SpringBoard restart (same as a respring). Then either (a) the normal UI, drawn by softpipe: slow (hundreds of ms per frame, so visibly laggy animations), or (b) a black/frozen screen or a respring loop if CA's GLES path misbehaves; then after at most 3 minutes the dead-man switch restarts backboardd without injection and the software renderer UI returns. SSH is expected to keep working throughout (backboardd is not on the SSH path).
5. **Undo by hand:** `ssh root@192.168.7.2 /var/root/gpu-eagl-inj/revert.sh` (or: delete the override plist / restore `<plist>.orig`, then `killall backboardd`); full cleanup: `rm -rf /var/root/gpu-eagl-inj`. If SSH is unavailable, a normal reboot loads the unmodified system (see item 3 for the volatile-override design).
6. **Success criteria / data collected:** backboardd log lines with `EAGL(shim)` messages (`EAGL_SHIM_DEBUG=1` in the override), whether `Failed to initialize Metal or OpenGLES contexts!` disappears, whether the display shows content, frame time from the swap path. Abort criteria: respring loop, panic, or SSH loss.

## CARenderer scenes after the orientation fixes (softpipe, phone, 2026-10-23, kernel stage 8)

With the two shim fixes (no flip on sync for `invertedRender:YES`, flip on `texImageIOSurface:...invert:NO` upload) `eagl_ca_test` is **0 failed**: solid layers, CGImage layer (top green/bottom blue), IOSurface contents
(top red/bottom green), shadow, gaussianBlur backdrop, colorSaturate, 300 layers. `eagl_test` 41/41. Frame times on a busy phone (other agents run on it), 256x256: solid 97 ms, image 108, IOSurface 42, shadow 117,
blur 326, saturate 471, 300 layers 390 ms. These are the softpipe baseline for phase E.

## Phase E, software side: freedreno (Adreno 630) under the same shim

Status 2026-10-23: **builds on the Mac; screen creation and rendering on the GPU NOT yet run** (the kernel's user submissions did not execute when this was written: fence timeout; a hung submit marks the GPU lost and needs a reboot, so no
freedreno run was made on the shared phone). The softpipe path with the new libOSMesa was re-tested on the phone (below).

**Design (smallest working option):** no new frontend. The OSMesa frontend stays (it already drives `st_api` with our GLES context profile); only its screen changes.
`osmesa_create_screen()` (targets/osmesa) first asks `sweet_hw_create_screen()` (new `targets/osmesa/sweet_hw.c`): unless `SWEET_GPU=0`, it opens the libdrm stand-in (`drmOpenWithType`) and creates the
freedreno pipe_screen with `fd_drm_screen_create_renderonly(fd, NULL, config)`; any failure (no `SweetAdreno630`, screen creation failed) falls back to softpipe, so one libOSMesa serves both. `SWEET_GPU_DEBUG=1` prints the
screen name or the fallback reason. The EAGL shim above is unchanged in structure.

Pieces (all in git):
* `gpu/freedreno-sweet/sweet_drm.c`: libdrm stand-in (cherry-picked from `origin/gpu-kernel` 5ee7615, then extended): msm requests -> `IOConnectCallStructMethod`; new direct entry points `sweet_drm_mmap/munmap` (the Mesa
  patch calls them, so no dependency on dyld interposing, which is kept as well), `sweet_drm_surface_bo` (SURFACE_BO), `sweet_drm_bo_sync` (BO_SYNC), `sweet_drm_info`; syncobj stubs; install name `@rpath/libdrm.2.dylib`.
  It reports msm 1.3 (no softpin): freedreno asks `GEM_INFO(GET_IOVA)` and patches relocations, as the kernel supports.
* `gpu/eagl/mesa/bergamota-mesa-25.0.7.patch` (9 files, applied by `build-mesa.sh`): (a) OSMesa ES profile (phase A/B); (b) `meson.build`: iOS counts as a DRM-capable system when freedreno is built, so freedreno's msm backend and
  `libdrm` are used; computerator/libarchive are skipped; (c) `freedreno_bo.c`: BO map/unmap through the stand-in's direct calls; (d) `freedreno_screen.c`: `sysctl hw.memsize` instead of `sysinfo`, and the KMS handle import
  keeps the BO size; (e) `ir3_disk_cache.c`: no disk cache on Mach-O (no ELF build-id); (f) `targets/osmesa`: hardware screen with fallback (`sweet_hw.c`), freedreno/libdrm dependencies; (g) `frontends/osmesa/osmesa.c`:
  `OSMesaSweetActive()`, `OSMesaSweetBlit()`, `OSMesaSweetForgetSurface()`.
* Build: `GPU_EAGL_WORK=... gpu/eagl/mesa/build-mesa.sh` (default `GPU_EAGL_HW=1`: clone mesa 25.0.7 and libdrm-2.4.124 headers, build the stand-in, `meson ... -Dgallium-drivers=softpipe,freedreno -Dfreedreno-kmds=msm -Dgallium-xa=disabled`), then
  `MESA_BLD=$GPU_EAGL_WORK/build-hw gpu/eagl/build.sh $GPU_EAGL_WORK/out-hw` (the shim, `libOSMesa.8.dylib` 15.3 MB stripped, `libdrm.2.dylib` 87 KB; libOSMesa carries rpath `@loader_path` so libdrm sits next to it).
  Mesa needed `pkgconf`, python `lxml`. Build tree 146 MB.

**Render targets are IOSurfaces, no CPU copy:** `presentRenderbuffer:` and `attachImage:` sync call `OSMesaSweetBlit(name, is_texture, IOSurfaceGetID(surface), flip, opaque)`. Inside Mesa it takes the renderbuffer's (or the
texture's) `pipe_resource`, wraps the IOSurface memory as a second `pipe_resource` (SURFACE_BO gives a BO handle + stride + offset; `resource_from_handle` with `WINSYS_HANDLE_TYPE_KMS`, modifier LINEAR, i.e. UBWC off, format
B8G8R8A8 or B8G8R8X8 when the layer is opaque), runs one `pipe->blit` (the blitter does the RGBA->BGRA conversion and the vertical flip through a negative destination height), waits (`st_finish`) and calls BO_SYNC so the CPU
and the display see the pixels. A GPU render-to-surface directly (no blit) is not possible in GL ES semantics without an FBO attachment of the surface, which the shim cannot express for the app's own FBO; the blit is GPU-to-GPU. Surfaces
the GPU cannot use (planes, other pixel formats, stride the freedreno layout rejects) make `OSMesaSweetBlit` return 0 and the shim uses the old CPU readback, per call. `texImageIOSurface` still uploads with `glTexImage2D` (a CPU copy into
a GPU texture; zero-copy sampling of the surface is a later step).

Test plan once the kernel agent reports that submits run (nothing below was run):
```
GPU_EAGL_WORK=... MESA_BLD=$GPU_EAGL_WORK/build-hw gpu/eagl/build.sh $GPU_EAGL_WORK/out-hw      # + EAGL_DEFS=-DEAGL_INJECT ... out-hwi for eagl_ca_test
push with sha256 verification (scratchpad deploy-gen.sh: strip --sign, rm remote dir, scp, sha256sum compare) to /var/root/gpu-eagl-hw and -hwi
SWEET_GPU_DEBUG=1 ./eagl_test                       # GL_RENDERER must say Adreno/FD630; 41 checks; clear + triangle read back from an IOSurface
SWEET_GPU_DEBUG=1 EAGL_INJECT_LIB=... ./eagl_ca_test  # six CA scenes with timings, compare with the softpipe table above
SWEET_GPU=0 ...                                       # same binaries on softpipe for the comparison
```
First things to look at on failure: `SWEET_DRM_TRACE=1` (failing msm requests), `SWEET_GPU_DEBUG=1`, `INFO.flags` bit1 (GPU lost), freedreno's own `FD_MESA_DEBUG`/`IR3_SHADER_DEBUG` environment.
Known risks: freedreno's resource layout for BGRA linear with a pitch that is not a multiple of 64 bytes (the shim's own pool surfaces use multiples of 64; surfaces made by other processes may be rejected -> CPU fallback);
a6xx features Mesa assumes that the kernel/CP setup of stage 8 does not program yet (HWCG, CP_PROTECT, UBWC config, GBIF/UCHE minimum; see GPU_KERNEL.md risk 2); GET_PARAMs the kernel answers `kIOReturnUnsupported` for
(UBWC_*, HIGHEST_BANK_BIT, MACROTILE_MODE: Mesa then uses defaults which may be wrong for the SDM845 memory config); no fence fds/syncobj (freedreno falls back to its own); 32-bit GPU VA space; one ring.

## The ES renderer as a bootable option: `bglrender` (root tweak + boot-arg), 2026-10-23

Why not the live override of the earlier plan: the phone has no `launchctl` (and launchd 18 reads the `launchd.plist` cache at boot), so a running backboardd cannot be restarted with a different environment without
changing files that outlive the session. The approved design below keeps everything inert unless the kernel boot-args ask for it, so "boot the ES renderer" = boot an image, "go back" = boot the normal one.

* **Launcher** `gpu/eagl/launch/bgl-launch.c` (arm64e, 50 KB): the backboardd job points here; it reads `kern.bootargs` (`sysctlbyname`, readable as mobile) and then execs the real `/usr/libexec/backboardd`:
  `bglrender=1` -> `DYLD_INSERT_LIBRARIES=/usr/local/lib/bergamota-gl/OpenGLES.framework/OpenGLES` (GPU if the kernel has one, else softpipe: the shim's libOSMesa decides); `bglrender=soft` -> same plus `SWEET_GPU=0`;
  `bgldebug=1` adds `EAGL_SHIM_DEBUG=1 SWEET_GPU_DEBUG=1`. Anything else (no arg, other value, sysctl failure, a payload file missing/unreadable, `/private/var/tmp/bgl-render.state` not writable) = plain backboardd, unchanged.
  Crash-loop guard: the state file holds (boot time, last start, strikes); a start less than 60 s after the previous start of the same boot is a strike, three strikes -> plain backboardd for the rest of that boot; a new boot resets it
  (nothing carries across a reboot). While injecting, stderr of backboardd (and so the shim's messages) goes to `/private/var/tmp/bgl-backboardd.log` (truncated above 1 MiB).
  Verified on the phone with a test build (`-DBGL_TEST`: paths and boot-args overridable) and the real shim libraries: no arg -> plain; `soft` -> insert + `SWEET_GPU=0`; `1`+`bgldebug=1`; strike counter 0,1,2 then plain on the 4th start in a minute;
  bogus value and missing libraries -> plain; the real `kern.bootargs` read as uid 501 works. Dyld honours `DYLD_INSERT_LIBRARIES` for platform binaries on this kernel (checked with `/bin/ps`, `/bin/df`).
* **Payload** `gpu/eagl/make-payload.sh` -> `research/bergamota-gl/` (git-ignored; `MANIFEST.sha256`): `bgl-launch`, the injection build of the shim (`OpenGLES.framework/OpenGLES`, 350 KB), `libOSMesa.8.dylib` (Mesa 25.0.7 freedreno + softpipe, 15.3 MB),
  `libdrm.2.dylib` (stand-in, 87 KB); arm64e, `pacstrip --sign`. The shim's inject constructor now also patches when OpenGLES shows up in a later image load (`_dyld_register_func_for_add_image`).
* **Root side** (branch `renegade-auto`, `tools/renegade/root_tweaks18.py`, feature `bglrender`, ON by default, `--no-bglrender` / `RENEGADE_NO_BGLRENDER=1` to skip, also in `renegade update`): installs the payload into `/usr/local/lib/bergamota-gl/` (launcher last) and changes only
  the `launchd.plist` cache entry of `com.apple.backboardd` (ProgramArguments[0] `/usr/libexec/backboardd` -> `/usr/local/lib/bergamota-gl/bgl-launch`). Idempotent; skipped with a message (job untouched) when the payload is not built. It looks for the payload in
  `$RENEGADE_BGL`, `research/bergamota-gl` of its own checkout, of the main checkout and of `../ios-beryllium-gpu-eagl`. Tested on a copy of the real launchd.plist (one entry changed, second run no-op).
* **Boot images** `gpu/eagl/make-boot-image.py BASE OUT --add ARG --del KEY`: edits only the 608-byte cmdline of the SWEETXNU payload; kernel, ADT, Enxerto and the Android header stay byte-identical (27 bytes differ).
  `shim/out/shim-boot-gles-soft.img` = `shim-boot-ios18-fixvar-dma.img` minus `sweetfixvar=1`, plus `bglrender=soft` (sha256 1a08e6c4...0a37). `shim-boot-gles-gpu.img` later: the gpu-kernel 8d image/ADT `beryllium-hi-3x-gpufwz.adt` + `sweetgpu=8` + `bglrender=1`
  (`make-boot-image.py <8d image> shim-boot-gles-gpu.img --add bglrender=1`).
* **To use:** `renegade update` on the root image (installs payload + job change), flash, boot `shim-boot-gles-soft.img`. **To go back:** boot the normal image (no `bglrender`): backboardd then runs plain through the launcher. To remove the tweak from the root for good:
  `renegade update --no-bglrender` does not undo it; restore ProgramArguments[0] to `/usr/libexec/backboardd` in the launchd.plist cache.
* **Unknowns the first boot will answer:** whether backboardd's CA picks the GLES path at all (where the render server creates its `EAGLContext` is still not located); whether the process sandbox lets the injected library and `IOSurface`/IOKit calls through (the library is mapped by dyld before the sandbox is applied; the GPU path additionally
  needs `iokit-open` for `SweetAdreno630`); what the frame cost is (softpipe: hundreds of ms per frame at 256x256, so a 750x1334 screen will be visibly slow). Everything lands in `/private/var/tmp/bgl-backboardd.log` (+ the unified log).

## First freedreno runs and the live backboardd test (2026-10-23, kernel 8d)

**Freedreno on the Adreno 630 works under the shim** (`SWEET_GPU=1`, libOSMesa with freedreno + softpipe, libdrm stand-in): screen `FD630 / freedreno`, GL_VERSION `OpenGL ES 3.1 Mesa 25.0.7`.
* The first run crashed with a NULL call in `fd_batch_create` (`fd_ringbuffer_attach_bo` of Mesa 25.0.7's *legacy* msm ringbuffer is missing). Fix: the stand-in now reports msm **1.4** (FD_VERSION_SOFTPIN), which selects the "sp" submit path that gallium freedreno really uses (kernel-assigned iovas from GEM_INFO(GET_IOVA) passed as `presumed`, no relocs), and it strips the pipe id (`MSM_PIPE_3D0`) from `submit.flags` (the kernel wants only NO_IMPLICIT; it answered `kIOReturnUnsupported` before).
* `eagl_test`: **41/41** on freedreno (clear + triangle read back from an IOSurface through the GPU blit, attach/texture selectors, macro context, sampling), 128x128 triangle + present ~2.1 ms/frame; **750x1334 textured quad + present 18.3 ms/frame vs 532 ms softpipe**.
* `eagl_ca_test` (CARenderer, six scenes, 256x256), 0 failed on both; ms/frame freedreno vs softpipe: solid 119 (first scene includes ir3 shader compiles) vs 62, image 49 vs 47, IOSurface contents 6 vs 17, shadow 34 vs 117, backdrop gaussianBlur 24 vs 204, colorSaturate 40 vs 308, 300 layers 68 vs 429. No GPU fault or lost state; the kernel log shows normal submit lines.

**Live backboardd test: the render server never used the shim.** `gpu/eagl/live/bgl-live.sh` installed the launcher as `/usr/libexec/backboardd` (original copied to `backboardd.real`, hash-checked), a marker and a dead-man, then `kill -9 backboardd`:
backboardd restarted as `backboardd.real` with the shim injected (log `bgl-launch: injecting ...`), SpringBoard came up and the home screen was displayed and touch-responsive, BUT: (1) the GPU service had 0 clients, (2) the shim logged no screen creation, (3) the UI had no blur (flat white dock/widgets/search pill).
Cause (static, 22H352): **QuartzCore has no reference to the EAGLContext class at all** (no class ref, no `initWithAPI:*`/`sharegroup` selector in its method-name table, no class-name string; the only "EAGLContext" text is a warning message), and no `MTLCreateSystemDefaultDevice` string. `CARenderer` and `CAEAGLLayer` use EAGL on contexts handed in by the CALLER; the render server does not create one. It picks its renderer through a C++ virtual (call at 0x1848656b0..0x1848656c4 and +0x188 at 0x1848656f8; when either returns NULL it tail-calls the software path at 0x1849d110c, whose lazy software-renderer constructor is 0x1849d11b0). With no Metal device that returns NULL, so the server runs CoreAnimation's software renderer, which has no backdrop/blur support. This is why the earlier plan's "Metal -> GLES -> software" cascade did not occur: the GLES step is gone from the server in this build.
So the shim is loaded harmlessly but cannot change what backboardd draws. To get a GPU-composited, blurred system UI the renderer choice must be patched (hackios did this on iOS 16: `inject.c`): replace the NULL-returning virtual (or the software constructor) with a function that builds a CA::OGL renderer over an EAGLContext of our shim, using the same internal factory as `-[CARenderer _initWithEAGLContext:options:]`; then the macro-context path verified above does the drawing. That is the next work item (reverse engineering of the CA::OGL/Server constructors).

**Marker volatility finding.** `/private/var/run` is NOT cleared at boot on this root and file times / `kern.boottime` are unreliable early in boot (the RTC is set later: `kern.boottime` was ~1970 when the launcher ran), so an mtime-based marker survived a reboot and injected again. The launcher now ties the marker to the boot session: `/private/var/run/bglrender` contains `MODE BOOT-SESSION-UUID [debug]` and is honoured only when the uuid equals this boot's `kern.bootsessionuuid` (`bgl-launch --bgl-print-boot-uuid` prints it; `bgl-live.sh mode` writes it); the crash-loop guard is keyed on the same uuid. A reboot therefore always comes up on plain backboardd. (The phone had the old mtime-based launcher installed when its battery died: re-run `bgl-live.sh revert`, then `install`.)
Other findings: `kill`, `sleep`, `setsid`, `nohup` exist, `killall`/`launchctl` do not; copying a 15 MB file over the USB link can fail with `Input/output error` on this filesystem (an interrupted `scp` left a partial, unremovable `/private/var/tmp/bgl-in/libOSMesa.8.dylib`), so verify every push by sha256 and never rely on a partial file; the USB link vanished at ~15:33 because the battery was empty (no GPU involvement).

## Making the render server use CA::OGL on the shim: reverse engineering and hook design (QuartzCore 22H352, 2026-10-23; NOT yet run)

Method: QuartzCore extracted from the PAC-stripped cache with Apple's `dsc_extractor.bundle` (3.8 GB scratch, deleted afterwards), analysed in IDA (same unslid addresses as the cache: image base 0x18470f000).

**How the server picks a renderer (all unslid addresses).**
* Per frame the server calls `sub_18486566C(server, ..., dest_surface, ...)` (also a twin `sub_1848C4684`): if `dest_surface->vtbl[+0xa0]()` is true and `server->vtbl[+0x188]()` returns a renderer object, it renders with it through the generic `sub_184865794(shared, renderer, dest, ...)`; otherwise it tail-calls the software path `sub_1849D110C`, which builds the CPU renderer (`sub_1849D11B0`, lazily: a 0x68-byte renderer wrapper with a 0x40000 scratch buffer around a software context), sets `shared[753] |= 0x80` and calls the same `sub_184865794`. So the renderer is a polymorphic object; software, Metal and GLES contexts share one virtual interface (the context's vtable +0x398 `render`, +0x398.. `set destination` at +920, ...).
* `server->vtbl[+0x188]` (slot 49) is implemented by four vtables (0x1ef97cce8 class A, 0x1ef97cf58, 0x1ef97e780 class B, 0x1ef980f40). Two return 0 (stub `sub_1849D1514`); **class A (`sub_18476D7C4`) and class B (`sub_1848C4908`) are the Metal implementations**: take `shared[296]` or `sub_18488EFF4()` (the MTLDevice wrapper; NULL without a Metal device, our case), build `CA::OGL::MetalContext` with `sub_18489631C(device, 0, flags, ..., 4, descr)` (4128-byte object, "ogl-metal.mm"), wrap it in the 0x68 renderer wrapper, store context/wrapper in the server (A: +1024/+1032, B: +696/+704) and `shared[312]`, set the context flag words (`ctx+224`, `ctx+432`, and `sub_18488EF40(ctx)` if bits 0x2000200 changed) and return the wrapper. Without a device they return NULL: software.
* The GLES context class is `sub_1848F968C(obj, EAGLContext*)` (2232-byte object from CA's malloc zone, constructor queries the extensions through `getMacroContextPrivate`); its only callers are `-[CARenderer _initWithEAGLContext:options:]` (`sub_184A33B0C`) and a descriptor factory (`sub_184928E38`, API 3 only). Nothing in the server creates it, which is why the shim was never reached.

**Hook (src/ca_server_hook.m, injection build only):** an add-image callback finds QuartzCore, checks the first instruction word of the five functions it touches (aborts on mismatch = other build), then overwrites vtable slot 49 of class A (0x1ef97ce70) and class B (0x1ef97e908) with wrappers: call the original; if it returns a renderer (Metal available) return it; otherwise build the same objects as the Metal implementation but with `GLESContext(zone_calloc(2232), shim EAGLContext ES3)` (the context is made current first), store them at the same server offsets and `shared[312]`, apply the flag words identically (class A: `(shared[753]&0x4000 ? 0x2020010 : 0x20010) | server[184]` as in `sub_18476D7C4`; class B: `server[184] | 0x20010`), return the wrapper. Slot pages are made writable with `vm_protect(... VM_PROT_COPY)` and set back to read-only. Nothing is attempted unless `BGL_CA_HOOK=1`, which `bgl-launch` sets whenever it injects (opt out: boot-arg `bglhook=0` or `nohook` in the marker). Every failure path returns NULL = the software renderer, as today. `EAGL_SHIM_DEBUG=1` logs the hook steps to `/private/var/tmp/bgl-backboardd.log`.

**Display surfaces.** Unchanged: the server hands the destination IOSurface-backed `Surface` object (`a3`, from the IOMFB/SweetFramebuffer swap chain, the same object the software renderer writes into by CPU) to `sub_184865794`, which calls the context's virtual "set destination" (+920) and "render" (+912/+408). For `CA::OGL::GLESContext` that path creates a `CA::OGL::GLESImage` and calls `-[EAGLContext attachImage:toCoreSurface:invertedRender:]` on the destination surface, which the shim answers with the GPU blit (`OSMesaSweetBlit`) at `glFlush`/`glFinish`, followed by `BO_SYNC`. So frames reach the panel through the same IOSurface as before; the new work is one blit per frame instead of a CPU rasterisation. Unknowns the first run will answer: whether `dest->vtbl[+0xa0]` accepts the swap-chain surface (otherwise the server stays on software before the hook is even asked), whether the GLES context needs the `ctx+848 |= 6` / `sub_184897A7C` setup that CARenderer applies after construction (not copied: a crash would show in the log and in three strikes drops to plain), and the actual frame cost.

**Next (when the phone is back):** `bgl-live.sh revert` (the phone may still have the old mtime-based launcher and its marker), delete the partial `/private/var/tmp/bgl-in/libOSMesa.8.dylib`, install the boot-session launcher and the hook build, then marker `1 <uuid> debug`, dead-man, respring; then compare the unified log and `bgl-backboardd.log` with the photo.

## MILESTONE 2026-10-23: the iOS 18 system UI rendered by CoreAnimation's GLES renderer on the Adreno 630, blur included

The live backboardd test (`gpu/eagl/live/bgl-live.sh`, marker + dead-man, kernel 8d) ended with the user's report "blur works!": SpringBoard's home screen, dock, widgets and search pill drawn through
`CA::OGL::GLESContext` -> our EAGL shim -> Mesa freedreno (FD630) -> GPU blit into the IOMFB swap-chain IOSurfaces, with the backdrop blur that the software renderer cannot do. The path:

1. `bgl-launch` (installed as `/usr/libexec/backboardd`, real binary `backboardd.real`) injects the shim into backboardd when the marker `MODE UUID` matches this boot (or boot-arg `bglrender=1|soft`).
2. `ca_server_hook.m` replaces vtable slot 49 of the two server renderer classes: with no Metal device the original returns NULL, the hook builds `CA::OGL::GLESContext` + renderer wrapper on a shim `EAGLContext` (ES3), `OSMesa/sweet: freedreno screen: FD630` is created inside backboardd (the GPU user-client count goes 0 -> 1).
3. CoreAnimation draws with its normal GLES shaders (programs compiled lazily by ir3), uploads glyph masks / gradient tables / images through `texImageIOSurface`, and calls `attachImage:toCoreSurface:invertedRender:` on the display surface; our `glFlush`/`glFinish` hooks blit the attached texture into that surface (`OSMesaSweetBlit`, `BO_SYNC`).

What it took (all found by dumping on the phone):
* `attachImage:`'s first argument is a GL **target** (`GL_TEXTURE_2D` = 3553), not an object name: the image bound at that target gets the IOSurface as storage. The first attempt treated 3553 as a name, the FBO had no storage and the screen stayed black.
  Now: bound texture/renderbuffer is resolved, storage allocated at the surface size, existing pixels uploaded (CoreAnimation redraws only damaged parts), attach recorded with its kind.
* `texImageIOSurface` now takes any GL format/type CoreAnimation uses (ALPHA/LUMINANCE/LA/RG/RGB/RGBA/BGRA x UNSIGNED_BYTE/HALF_FLOAT/FLOAT/565/...) and returns NO instead of crashing when the surface has no CPU mapping (`IOSurfaceGetBaseAddress` NULL: one crash loop of backboardd, SEGV in memcpy at a NULL-based address).
* **Orientation rule for the render server:** target-form attaches with `invertedRender:NO` must be copied with the GL row order kept (no flip); a flip (the rule that fits CARenderer tests with the name form) drew the UI upside down. Now: target form: flip iff `inverted`; name form (our tests): flip iff `!inverted`.
* Debug aids: marker word `debug` (`EAGL_SHIM_DEBUG`), frames 1/10/60 and `/private/var/tmp/bgl-dump-now` dump the GL readback (`-gl.ppm`) and the CPU view of the display surface (`-surf.ppm`) to `/private/var/tmp/bgl-dump/`.
* Marker volatility: boot-session uuid (see above); the state file in `/private/var/tmp` hit filesystem EIO twice (the launcher then simply does not inject, by design).

Numbers (Mesa 25.0.7 freedreno vs softpipe, same shim, phone): `eagl_test` 750x1334 textured quad + present **18.3 ms vs 532 ms (29x)**; CARenderer scenes at 256x256, ms/frame FD630 vs softpipe: backdrop gaussianBlur 24 vs 204, colorSaturate 40 vs 308, shadow 34 vs 117, 300 translucent layers 68 vs 429, IOSurface-contents 6 vs 17. The render-server frame time itself was not measured (no photo/FPS tooling yet): the next step is a per-frame timer around the sync in debug mode.

**Bootable without SSH:** `shim/out/shim-boot-gles-gpu.img` (sha256 d8419f0e...bb5a) = `enxerto-boot-develop-gpu8d.img` (develop Enxerto, kernel xnu-11215 + GPU 8d, ADT `beryllium-hi-3x-gpufwz.adt`, `sweetgpu=8 ufslogsecs=1`) + `bglrender=1` (12 bytes differ, built with `make-boot-image.py`). The root needs the Renegade `bglrender` tweak (branch `renegade-auto`, installs `research/bergamota-gl` = the current hook build, launcher in the job): `gpu/eagl/make-payload.sh` first, then `renegade update`. Without `bglrender=1` the same root runs plain backboardd. Known gaps: 14 unresolved APPLE/OES entry points, texture uploads are CPU copies, GPU frequency is the kernel's boot level (257 MHz), `attachImage` still allocates and blits per attached image (zero-copy rendering into the surface BO is possible: wrap the BO as the texture's resource).

### Cold-boot crash loop of backboardd (2026-10-23, `enxerto-boot-develop-all.img`, bglrender=1) and its fixes

Symptom: black screen, backboardd.real crashed and restarted every second, `SIGSEGV KERN_INVALID_ADDRESS 0x29eda0` on the display thread. Symbolicated (`atos` on the unstripped libOSMesa, offsets from the crash report):
`_platform_memmove <- _mesa_store_compressed_texsubimage <- st_CompressedTexSubImage <- st_CompressedTexImage <- teximage_err <- _mesa_CompressedTexImage2D <- QuartzCore` (the wallpaper path of a cold boot: CoreAnimation uploads
a compressed texture). **Cause: `glCompressedTexImage2D` has EIGHT arguments, and my macro-context forwarders only handle seven integer arguments after `rend` in registers; the eighth (the data pointer) lives on the stack and was
replaced by the stale `imageSize` (0x29eda0 = 2.7 MB used as a pointer).** The generated wide-wrapper list had every other 8+ argument entry point except this one. Fix: `mw_CompressedTexImage2D` in `macro_ctx.c` and in the generator's list
(checked against the ES headers: exactly CompressedTexImage2D, CopyTexImage2D, CopyTexSubImage2D, (Compressed)TexImage2D/SubImage2D/3D, CopyTexSubImage3D and BlitFramebuffer need it); `eagl_test` now calls it through the macro context (ETC2 block).
Why a live respring did not crash: the live run had no compressed upload yet.

Other fixes from the same investigation:
* **Crash-loop guard.** The state file could be unreadable (filesystem EIO on this root) and then counted nothing; an unreadable state now means "do not inject", and the threshold is 2 strikes within 120 s (the third start in two minutes runs plain), for boot-arg and marker alike.
* **Dump trigger.** `/private/var/tmp/bgl-dump-now` was left over from a live test and, surviving the reboot, made EVERY frame dump 16 MB of PPM: now one-shot (unlinked at first use).
* **GPU/CPU cache coherency of IOSurface targets.** An `eagl_test` check failed intermittently with black rows read back from an IOSurface the GPU had just written: the post-blit `BO_SYNC` is a clean+invalidate, so dirty CPU lines of a surface the CPU had painted (zeroed) were written back over the GPU's pixels.
  The surface is now cleaned once BEFORE the GPU first uses it (`sweet_hw_surface_resource`); 5/5 runs pass afterwards. This is also the most likely cause of the dark band on the left edge seen on the panel.

## Shader cache, pipeline measurements, zero-copy preparation (session notes)

* **Shader disk cache**: Mesa built with `-Dshader-cache=enabled` (128M); `ir3_disk_cache_init` keys the cache on the LC_UUID of libOSMesa (sha1) since Mach-O has no ELF build-id. The shim (`osm.c`, `setup_shader_cache`) sets `MESA_SHADER_CACHE_DIR=/private/var/tmp/bergamota-gl-cache/<uid>` (parent 1777, per-uid 0700 subdirectory) and `MESA_SHADER_CACHE_MAX_SIZE=128M` unless the environment already sets them (`MESA_SHADER_CACHE_DISABLE`, `BGL_CACHE_DIR` override). Verified on the phone with eagl_test (cache db created, size stable on the second run).
* **Pipeline measurements** (`EAGL_SHIM_DEBUG=1`, marker word `debug`; `frames` additionally enables the old per-frame luminance/thumbnails): a `PIPE` line every 60 display syncs gives per-sync glFlush time, GPU render-wait (forced finish before the blit), blit enqueue, copy-wait (GPU time of the blit), BO_SYNC, CPU-copy count/time. First measurement (lock screen, sweetgpufreq default kernel): glFlush ~1 ms, render-wait 3-10 ms, ~21 ms per full-screen 1125x2436 blit and two of them per flush (both display textures were copied every flush), BO_SYNC ~0.9 ms each, CPU fallback ~0.5 ms/sync for ~2 small wrapped surfaces per sync.
* **Dirty tracking** (opt-in, marker word `dirty` / `BGL_DIRTY=1`, not default): draw/clear entry points mark the attachment the bound FBO renders into so only that display buffer is copied. First try copied nothing (the FBO colour attachment was not matched), so it stays off until the FBO layout CA uses is logged (`FBO tracking:` lines).
* **Zero-copy (kernel ABI minor 1)**: the libdrm stand-in sends the 112-byte `sweet_gpu_surface_bo` only when `INFO.abi_minor >= 1`, else the 48-byte V1 struct. Wrapped (client-memory) surfaces come back GPU READ-ONLY: the shim describes first (no BO), refuses them as blit destinations (CPU copy stays, a GPU write there is an SMMU fault) and logs the kernel ABI at screen creation. Using them as texture sources (replacing the CPU read in `texImageIOSurface`) is the next step and needs the new kernel.

### Display buffers: stale attachments, dirty tracking, direct rendering
* **Root cause of the flicker / black wallpaper**: CoreAnimation attaches a NEW texture to the same display IOSurface every frame (log: textures 1, 95, 100 -> surface 2276). The shim kept all of them and copied every attachment at every flush, so older textures overwrote the surface with older pixels in array order. Fixed: only the latest attachment per surface is kept (`attachImage`), plus dirty tracking (default; `syncall` marker word / `BGL_SYNC_ALL=1` turns it off): draw / clear / blit / copy / upload entry points (and their OES aliases, which the render server's macro slots use) mark the attachment the bound FBO (or bound texture) writes; display-size attachments are copied only when marked, and everything is copied when GL work happened that no attachment explains.
* **Direct rendering** (`direct` marker word / `BGL_DIRECT=1`, off by default, untested on hardware): `OSMesaSweetAttachDirect` makes the display texture BE the surface memory (SURFACE_BO + resource_from_handle + `st_bind_egl_image`, like glEGLImageTargetTexture2DOES), so CoreAnimation renders into the surface: no seed upload, no blit, and the per-flush cost is `st_finish` + BO_SYNC (`OSMesaSweetDirectSync`). Only for linear BGRA kernel-allocated surfaces and `inverted=0` attachments; wrapped (read-only) surfaces are refused and keep the blit/CPU path. This removes the ~21 ms full-screen blit.
* Control Center: the 23x23 / 28x28 format-less surfaces (CPU copy path) read back as all zero in the first dump; the module platters are probably drawn from such small masks/backdrops. Not diagnosed yet.

### Writable alias for client-memory surfaces (kernel abi_minor 2, branch sbo-alias)
Client-memory (wrapped) IOSurfaces are read-only for the GPU and for backboardd's own mapping (prot = max_prot = read), so the render server could not deliver pixels into them (Control Center platters, live icons: black squares and bars). With `INFO.abi_minor >= 2` and `INFO.flags & CAP_SBO_ALIAS (0x10)` the stand-in sends the 128-byte `sweet_gpu_surface_bo` and `sweet_hw_surface_alias` asks SURFACE_BO for `SBO_IN_WRITABLE_ALIAS|SBO_IN_SYNC`; the reply's `alias_addr + offset` is pixel (0,0) in a RW write-back mapping. `rgba_to_surface` (the CPU copy path) writes through it, then BO_SYNC. The alias is unmapped by the kernel at GEM_CLOSE (done when the shim forgets the surface). Without the capability nothing changes (CPU path skips read-only surfaces as before); `BGL_ALIAS=0` disables it.
