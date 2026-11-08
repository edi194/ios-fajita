#!/bin/bash
# SPDX-License-Identifier: MIT
# Cross-build Mesa 25.0.7 (official release tag, no third-party code) for iOS arm64e: OSMesa frontend, GLES1/2/3 contexts, gallium
# softpipe and (GPU_EAGL_HW=1, the default) freedreno/a6xx over the libdrm stand-in gpu/freedreno-sweet. No LLVM, no X11/Wayland/GBM/EGL/GLX.
# Mesa is patched with bergamota-mesa-25.0.7.patch (OSMesa ES profile, GPU blit into IOSurfaces, iOS fixes for freedreno).
# The hardware path needs libdrm headers: the official libdrm-2.4.124 tag is cloned (headers only) and a libdrm.pc points at the stand-in.
#   GPU_EAGL_WORK=/some/scratch/dir gpu/eagl/mesa/build-mesa.sh      (needs ~1.6 GB; Xcode with the iphoneos SDK;
#                                                                     brew install meson bison; python mako/pyyaml in a venv)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${GPU_EAGL_WORK:?set GPU_EAGL_WORK}"
TAG="${MESA_TAG:-mesa-25.0.7}"
ARCH="${ARCH:-arm64e}"
mkdir -p "$WORK"; cd "$WORK"
if [ ! -d venv ]; then
  python3 -m venv venv
  ./venv/bin/pip -q install mako pyyaml packaging setuptools meson lxml
fi
export PATH="$WORK/venv/bin:$PATH"
if [ ! -d mesa ]; then
  git clone -q --depth 1 --branch "$TAG" https://gitlab.freedesktop.org/mesa/mesa.git mesa
  git -C mesa apply "$HERE/bergamota-mesa-25.0.7.patch"
fi
HW="${GPU_EAGL_HW:-1}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BISON="$(brew --prefix bison)/bin/bison"
CROSS="$WORK/ios-$ARCH.cross"
cat > "$CROSS" <<EOT
[binaries]
c = ['xcrun','--sdk','iphoneos','clang','-arch','$ARCH']
cpp = ['xcrun','--sdk','iphoneos','clang++','-arch','$ARCH']
objc = ['xcrun','--sdk','iphoneos','clang','-arch','$ARCH']
ar = ['xcrun','--sdk','iphoneos','ar']
strip = ['xcrun','--sdk','iphoneos','strip']
ranlib = ['xcrun','--sdk','iphoneos','ranlib']
bison = '$BISON'
pkg-config = '$(command -v pkg-config)'

[built-in options]
pkg_config_path = ['$WORK/pc']
c_args = ['-miphoneos-version-min=18.0','-isysroot','$SDK']
cpp_args = ['-miphoneos-version-min=18.0','-isysroot','$SDK']
c_link_args = ['-miphoneos-version-min=18.0','-isysroot','$SDK']
cpp_link_args = ['-miphoneos-version-min=18.0','-isysroot','$SDK']

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = '$ARCH'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOT
if [ "$HW" = 1 ]; then
  BLD="$WORK/build-hw"
  [ -d libdrm ] || git clone -q --depth 1 --branch libdrm-2.4.124 https://gitlab.freedesktop.org/mesa/drm.git libdrm
  "$HERE/../../freedreno-sweet/build.sh" "$WORK/drm-standin-out" >/dev/null
  mkdir -p drm-standin pc
  cp "$WORK/drm-standin-out/libdrm.2.arm64e.dylib" drm-standin/libdrm.2.dylib
  ln -sf libdrm.2.dylib drm-standin/libdrm.dylib
  cat > pc/libdrm.pc <<EOP
Name: libdrm
Description: Bergamota libdrm stand-in (gpu/freedreno-sweet)
Version: 2.4.124
Cflags: -I$WORK/libdrm/include/drm -I$WORK/libdrm
Libs: -L$WORK/drm-standin -ldrm
EOP
  DRIVERS=softpipe,freedreno; EXTRA="-Dfreedreno-kmds=msm -Dgallium-xa=disabled -Dtools="
else
  BLD="$WORK/build-${ARCH/arm64e/a64e}"; DRIVERS=softpipe; EXTRA=""
fi
if [ ! -d "$BLD" ]; then
  (cd mesa && meson setup "$BLD" --cross-file "$CROSS" --buildtype=release \
    -Dgallium-drivers=$DRIVERS $EXTRA -Dvulkan-drivers= -Dllvm=disabled \
    -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dplatforms= \
    -Dosmesa=true -Dopengl=true -Dgles1=enabled -Dgles2=enabled -Dshared-glapi=enabled \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dxmlconfig=disabled -Dbuild-tests=false \
    -Dglvnd=disabled -Dlmsensors=disabled -Dgallium-opencl=disabled -Dgallium-rusticl=false \
    -Dshader-cache=enabled -Dshader-cache-max-size=128M -Dprefix=/)
fi
ninja -C "$BLD"
ls -l "$BLD/src/gallium/targets/osmesa/libOSMesa.8.dylib"
