#!/bin/bash
# Local Heartwood kernel build: the same preparation as .github/workflows/xnu.yml, on this Mac.
#   tools/xnu-local-build.sh [MACOS_VERSION]      (default 26.5 = xnu-12377 with xnu/patches-12377)
#   tools/xnu-local-build.sh --remake [-jN] [26.5] only re-run xnu's make on the existing tree (no re-clone, no
#                                                 re-patch): for fixes edited in place under $XNU_LOCAL_DIR/dxb/xnu;
#                                                 -j1 gives readable (non-interleaved) errors
# Env: XNU_LOCAL_DIR (work dir, default research/xnu-local, gitignored), KERNEL_CONFIG (DEVELOPMENT),
#      USE_KDK=1 to let dxb download the KDK (default: no KDK, see 0027-stage-coreentitlements-v2-stub.sh).
# Compiler cache: sccache only (xnu's makedefs prefix KCC/KC++ with $(CCACHE)). BOUND_CHECKS=0: the
# bounds-safety checks are off, as in the CI build. Output: $XNU_LOCAL_DIR/dxb/fakeroot/System/Library/Kernels/.
# Needs about 8 GB free; run it in the background (it takes a while).
# Toolchain: Xcode 26.x (DEVELOPER_DIR=...). The Xcode 27 SDK no longer ships Kernel.framework's private headers
# (TrustCache/API.h, ...), so with Xcode 27 the build only gets as far as pmap_cs.h unless USE_KDK=1.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REMAKE=0 JOBS=-j8
[ "${1:-}" = --remake ] && { REMAKE=1; shift; }
[[ "${1:-}" == -j* ]] && { JOBS=$1; shift; }
MACOS_VERSION=${1:-26.5}
W=${XNU_LOCAL_DIR:-$ROOT/research/xnu-local}

if [ "$REMAKE" = 1 ]; then
    # the same make invocation as dxb's build.sh (build_xnu), on the tree it left behind
    D=$W/dxb
    [ -d "$D/build/xnu.obj" ] || { echo "no previous build in $D" >&2; exit 1; }
    case "$MACOS_VERSION" in 26.5) KDK=/Library/Developer/KDKs/KDK_26.5_25F71.kdk/ RCV=25.5.0 ;;
                             15.3) KDK=/Library/Developer/KDKs/KDK_15.3_24D60.kdk RCV=24.3.0 ;;
                             *) echo "add the KDK path for $MACOS_VERSION" >&2; exit 1 ;; esac
    [ "${USE_KDK:-0}" = 1 ] || KDK=$W/no-kdk
    cd "$D/xnu"
    export CCACHE=sccache BOUND_CHECKS=0
    export KERNEL_BUILD_DATE="$(TZ=UTC git log -1 --format=%cd --date=format-local:'%a %b %e %T %Z %Y')"
    export KERNEL_BUILD_OBJROOT="$(git describe --tags --always)"
    exec make install $JOBS -k VERBOSE=YES CTFCONVERT=$D/fakeroot/usr/local/bin/ctfconvert \
        CTFMERGE=$D/fakeroot/usr/local/bin/ctfmerge CTFDUMP=$D/fakeroot/usr/local/bin/ctfdump SDKROOT=macosx \
        TARGET_CONFIGS="${KERNEL_CONFIG:-DEVELOPMENT} ARM64 SWEET" CONCISE=0 LOGCOLORS=n BUILD_WERROR=0 BUILD_LTO=0 \
        SRCROOT="$D/xnu" OBJROOT="$D/build/xnu.obj" SYMROOT="$D/build/xnu.sym" DSTROOT="$D/fakeroot" \
        FAKEROOT_DIR="$D/fakeroot" KDKROOT="$KDK" TIGHTBEAMC=tightbeamc-not-supported RC_DARWIN_KERNEL_VERSION=$RCV \
        MEMORY_SIZE="$(sysctl -n hw.memsize)" SYSCTL_HW_PHYSICALCPU="$(sysctl -n hw.physicalcpu)" \
        SYSCTL_HW_LOGICALCPU="$(sysctl -n hw.logicalcpu)" KERNEL_BUILDS_IN_PARALLEL=1
fi
DXB_REPO=https://github.com/blacktop/darwin-xnu-build
DXB_SHA=$(sed -n 's/^  DXB_SHA: //p' "$ROOT/.github/workflows/xnu.yml")

case "$MACOS_VERSION" in
    26.*) SERIES=$ROOT/xnu/patches-12377; PSUB=26.0 ;;
    15.*) SERIES=$ROOT/xnu/patches-11215; PSUB=15.0 ;;
    *) echo "unsupported MACOS_VERSION $MACOS_VERSION" >&2; exit 1 ;;
esac

mkdir -p "$W"
if [ ! -d "$W/dxb/.git" ]; then
    git init -q "$W/dxb"
    git -C "$W/dxb" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
    git -C "$W/dxb" checkout -q FETCH_HEAD
fi
cd "$W/dxb"
# fresh copy of dxb's own files each run, then ours with the sweet- prefix (same order as CI)
git checkout -q -- . && rm -f patches/$PSUB/sweet-*
rm -rf xnu        # dxb clones a pristine xnu and patches it
for f in "$SERIES"/*.patch "$SERIES"/*.sh; do cp "$f" "patches/$PSUB/sweet-$(basename "$f")"; done
sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' build.sh
python3 - <<'PY'
s = open('build.sh').read()
needle = '                warning "Skipping patch ${PATCH} (already upstream, previously applied, or malformed): ${APPLY_CHECK}"\n'
assert needle in s, 'build.sh patches() layout changed'
s = s.replace(needle, needle + '                case "$(basename "${PATCH}")" in [0-9]*|sweet-*) error "our patch does not apply: ${PATCH}"; exit 1 ;; esac\n')
open('build.sh', 'w').write(s)
PY
if [ "${USE_KDK:-0}" != 1 ] && [ "$PSUB" = 26.0 ]; then
    rm -f patches/26.0/00_setup_coreentitlements.sh
    mkdir -p "$W/no-kdk"
    export KDKROOT="$W/no-kdk"
fi
export MACOS_VERSION KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT} MACHINE_CONFIG=SWEET
export CCACHE=sccache BOUND_CHECKS=0 MAKEFLAGS=${MAKEFLAGS:--k}
/opt/homebrew/bin/bash build.sh
ls -la fakeroot/System/Library/Kernels/
