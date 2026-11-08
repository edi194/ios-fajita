# Phone paths written by the gpu-eagl agent on 2026-10-23 (for the UFS durability check)

All writes were made over SSH as root (or by the backboardd process as `mobile`) while the phone ran iOS 18.7.8 on the Heartwood xnu-11215 kernels of the day.
Times are phone local time (PDT). This list is built from the session log; writes of the first part of the day (before 13:00) are listed by pattern only.
Nothing was written to any partition or to boot images by this agent.

## Installed payload (persistent), /usr/local/lib/bergamota-gl/
* `bgl-launch`, `libOSMesa.8.dylib`, `libdrm.2.dylib`, `OpenGLES.framework/OpenGLES`: replaced several times (13:03 first install, then 14:01, 15:2x, 16:24, 17:13, 17:28-17:35).
* Copies next to them: `*.prev`, `*.new`, `*.good`, `OpenGLES.framework/OpenGLES.good*`, `OpenGLES.framework/OpenGLES.dead*`, `OpenGLES.framework/OpenGLES.d<epoch>`, `OpenGLES.framework/OpenGLES.g<epoch>`, `libOSMesa.8.dylib.dead`, `libdrm.2.dylib.dead`, `bgl-launch.dead1`, `bgl-launch.d<epoch>`.
* On this kernel (after the 17:10 reinstall) `rm` and `mv -f` over the files installed at 17:13/17:15 failed with `Input/output error` (rename of the old file away worked). Those inodes were the ones written at 17:13 and 17:15.

## Staging and scripts, /var/root/
* Directories: `bgl-new`, `bgl-new2` .. `bgl-new10`, `bgl-alias`, `bgl-latest`, `bgl-7c75`, `bgl-7c75b`, `bgl-final`, `bgl-final2`, `gpu-eagl-hw/` (eagl_test binary, libOSMesa, libdrm, OpenGLES.framework).
* Scripts/files: `bgl-arm.sh`, `bgl-dead.sh`, `bgl-inst3.sh`, `bgl-revert2.sh`, `bgl-revert3.sh`, `bgl-launch-nz`, `OpenGLES.latest.keep`, `sb-crash.ips`, `eagl-crash.ips`.
* Logs copied here: `bgl-run3.log` .. `bgl-run12.log`, `bgl-prev.log`, `t1.log`, `t2.log`.

## Runtime state, /private/var/tmp/ and /private/var/run/
* `/private/var/tmp/bgl-render.state` (50 bytes; rewritten at every backboardd start by bgl-launch, removed and recreated by hand many times; found as 50 NUL bytes after the 15:47 reboot and as `Invalid argument` on read at 17:1x).
* `/private/var/tmp/bgl-backboardd.log` (appended by backboardd as `mobile`; the file stopped growing mid-run at 17:35 although writes continued).
* `/private/var/tmp/bgl-thumbs.bin`, `/private/var/tmp/bgl-dump/` (debug dumps, earlier in the day), `/private/var/tmp/bergamota-gl-cache/<uid>/` (Mesa shader disk cache written by backboardd and by eagl_test, 128M limit; first created 13:53).
* `/private/var/run/bglrender` (volatile marker, written and removed ~25 times).

## Not yet written (planned, held)
* `/private/var/mobile/Library/Caches/bgl-debug.log` (debug output of the next build).

## Reads that never wrote
`/Users/.../ios-beryllium/logs` is on the Mac. The phone's CrashReporter directory and dyld cache were only read.
