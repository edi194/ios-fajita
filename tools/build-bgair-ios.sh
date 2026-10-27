#!/bin/bash
# Build Chlorophyll's libbgair.dylib (AIR -> NIR -> ir3) for iOS arm64 from Linux.
#
#   tools/build-bgair-ios.sh [WORKDIR]        default WORKDIR: ~/mesa-ios-build
#
# Needs: clang + ld64.lld (Linux), the iPhoneOS SDK, meson+ninja+mako+pyyaml
# (pip install --user --break-system-packages meson ninja mako pyyaml), network for the clones.
#
# Everything the build needs beyond the upstream scripts was learned the hard way; see
# tools/mesa-ios/README.md for why each piece is there.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W=${1:-$HOME/mesa-ios-build}
SDK=${IOS_SDK:-/home/edi194/ios-sdk/iPhoneOS16.5.sdk}
MESA_REF=${MESA_REF:-mesa-25.0.7}
DRM_REF=${DRM_REF:-libdrm-2.4.124}
BERG=${BERGAMOTA:-/home/edi194/ref/Bergamota}
CHL=${CHLOROPHYLL:-/home/edi194/ref/Chlorophyll}
export PATH="$HOME/.local/bin:$PATH"

mkdir -p "$W"
cd "$W"

# --- sources -------------------------------------------------------------------------
[ -d mesa ] || git clone -q --depth 1 --branch mesa-25.0.7 \
    https://gitlab.freedesktop.org/mesa/mesa.git mesa
[ -d libdrm ] || git clone -q --depth 1 --branch libdrm-2.4.124 \
    https://gitlab.freedesktop.org/mesa/drm.git libdrm
cd mesa
git checkout -q .
for p in "$BERG/gpu/eagl/mesa/bergamota-mesa-25.0.7.patch" "$CHL"/patches/*.patch; do
    git apply "$p" 2>/dev/null || true
done

# the AIR sources live in Chlorophyll/air in the reference tree
mkdir -p src/compiler/air
for f in "$CHL"/air/*; do ln -sf "$f" "src/compiler/air/$(basename "$f")"; done

# --- meson edits: "msm over a libdrm stand-in, no KMS" --------------------------------
python3 - <<'PY'
import re
p='meson.build'
s=open(p).read()
if 'fajita: msm over the libdrm stand-in' not in s:
    s = s.replace("with_gallium_drisw_kms = false\nif system_has_kms_drm\n  dep_libdrm = dependency(",
                  "with_gallium_drisw_kms = false\nif system_has_kms_drm or freedreno_kmds.length() > 0   # fajita: msm over the libdrm stand-in, no KMS\n  dep_libdrm = dependency(", 1)
p2='src/freedreno/meson.build'
s2=open(p2).read()
if 'no KMS' not in s2:
    s2 = s2.replace("if system_has_kms_drm\n  subdir('drm')\nendif",
                    "if system_has_kms_drm or freedreno_kmds.length() > 0   # Bergamota/fajita: msm over the libdrm stand-in, no KMS\n  subdir('drm')\nendif", 1)
p3='src/freedreno/drm/meson.build'
s3=open(p3).read()
if 'libvdrm exists only with virtio_vk' not in s3:
    s3 = s3.replace("  # TODO\n  link_with : [libvdrm],",
                    "  # TODO\n  link_with : freedreno_kmds.contains('virtio') ? [libvdrm] : [],   # libvdrm exists only with virtio_vk", 1)
open(p,'w').write(s); open(p2,'w').write(s2); open(p3,'w').write(s3)
PY

# --- pkg-config for the iOS target --------------------------------------------------
mkdir -p "$W/pc" "$W/drm-link"
[ -f "$W/drm-link/libdrm.2.dylib" ] || cp -f /home/edi194/ios-userland/libdrm.2.dylib "$W/drm-link/"
ln -sf libdrm.2.dylib "$W/drm-link/libdrm.dylib"
cat > "$W/pc/libdrm.pc" <<EOP
Name: libdrm
Description: Bergamota libdrm stand-in (SweetAdreno630)
Version: 2.4.124
Cflags: -I$W/libdrm/include/drm -I$W/libdrm
Libs: -L$W/drm-link -ldrm
EOP
cat > "$W/pc/zlib.pc" <<EOP
Name: zlib
Description: iOS SDK zlib stub (resolved through -isysroot)
Version: 1.3.1
Libs: -lz
Cflags:
EOP

# --- cross file ---------------------------------------------------------------------
# -DHAVE_* : meson's own feature checks link test programs and fail in a cross build, and
# every one of them that matters here is true for iOS. cpp_args must carry the target too:
# with only c_args, C++ objects were compiled for the build machine (x86_64-linux).
cat > "$W/ios.cross" <<EOC
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
objcpp = 'clang++'
ar = '/usr/bin/llvm-ar'
strip = '/usr/bin/llvm-strip'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['--target=arm64-apple-ios16.0', '-isysroot', '$SDK', '-fuse-ld=lld', '-DHAVE_STRUCT_TIMESPEC', '-DHAVE_DLADDR', '-DHAVE_DLFCN_H', '-DHAVE_FUNC_ATTRIBUTE_PACKED']
c_link_args = ['--target=arm64-apple-ios16.0', '-isysroot', '$SDK', '-fuse-ld=lld']
cpp_args = ['--target=arm64-apple-ios16.0', '-isysroot', '$SDK', '-fuse-ld=lld', '-DHAVE_STRUCT_TIMESPEC', '-DHAVE_DLADDR', '-DHAVE_DLFCN_H', '-DHAVE_FUNC_ATTRIBUTE_PACKED', '-Wno-c++11-narrowing', '-Wno-narrowing']
cpp_link_args = ['--target=arm64-apple-ios16.0', '-isysroot', '$SDK', '-fuse-ld=lld']
EOC

export PKG_CONFIG_PATH="$W/pc"
rm -rf build-ios
meson setup build-ios . --cross-file "$W/ios.cross" --buildtype=release \
  -Dgallium-drivers=softpipe,freedreno -Dfreedreno-kmds=msm \
  -Dgallium-xa=disabled -Dtools= -Dvulkan-drivers= -Dllvm=disabled -Dglx=disabled -Degl=disabled \
  -Dgbm=disabled -Dplatforms= -Dosmesa=false -Dopengl=true -Dgles1=disabled -Dgles2=enabled \
  -Dshared-glapi=enabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled \
  -Dxmlconfig=disabled -Dbuild-tests=false -Dglvnd=disabled -Dlmsensors=disabled \
  -Dgallium-opencl=disabled -Dgallium-rusticl=false -Dshader-cache=disabled -Dprefix=/ > "$W/setup.log" 2>&1 \
  || { tail -20 "$W/setup.log"; exit 1; }

ninja -C build-ios -j"$(nproc)" src/gallium/drivers/freedreno/libbgair.dylib
ls -l build-ios/src/gallium/drivers/freedreno/libbgair.dylib
