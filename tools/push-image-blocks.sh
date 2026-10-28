#!/bin/bash
# Update the iOS root on the device without a 12 GB fastboot flash.
#
#   tools/push-image-blocks.sh BASE.img NEW.img [CHUNK_MiB]
#
# BASE.img must be the image that is on the device (keep a sparse copy of what you flashed), NEW.img
# is the same image after you changed something (mount, copy files, unmount). Only the chunks that
# differ are pushed and written with dd to the raw userdata partition, at the same offsets, so the
# result is byte-identical to flashing the whole partition - but it takes seconds and, unlike a
# userdata flash, does not trigger the iOS data migration.
#
# Needs the phone in a recovery with adb (OrangeFox/TWRP), the partition unmounted. HFS+ support is
# not needed anywhere: no filesystem is interpreted, only blocks are copied.
set -euo pipefail
BASE=${1:?usage: push-image-blocks.sh BASE.img NEW.img [CHUNK_MiB]}
NEW=${2:?usage: push-image-blocks.sh BASE.img NEW.img [CHUNK_MiB]}
CHUNK_MIB=${3:-4}
CHUNK=$((CHUNK_MIB * 1024 * 1024))
DEV=/dev/block/sda17            # userdata, where the iOS root lives (overridable with SWEET_USERDATA)

[[ -f $BASE && -f $NEW ]] || { echo "missing image" >&2; exit 1; }
bsz=$(stat -c%s "$BASE"); nsz=$(stat -c%s "$NEW")
[[ $bsz -eq $nsz ]] || { echo "images differ in size ($bsz vs $nsz) - not a block-level change" >&2; exit 1; }

adb get-state >/dev/null 2>&1 || { echo "no adb device (phone must be in recovery)" >&2; exit 1; }
dev=${SWEET_USERDATA:-$DEV}
echo "device: $(adb get-state)   partition: $dev   chunk: ${CHUNK_MIB} MiB"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "comparing $((bsz / 1024 / 1024 / 1024)) GiB, ${CHUNK_MIB} MiB chunks ..."
python3 - "$BASE" "$NEW" "$CHUNK" "$work" <<'PY'
import sys, hashlib, os
base, new, chunk, work = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
changed = []
with open(base, 'rb') as fb, open(new, 'rb') as fn:
    idx = 0
    while True:
        a = fb.read(chunk)
        b = fn.read(chunk)
        if not a and not b:
            break
        if a != b:
            p = os.path.join(work, f'chunk-{idx:06d}.bin')
            open(p, 'wb').write(b)
            changed.append((idx, p, hashlib.sha256(b).hexdigest()))
        idx += 1
print(f'chunks total: {idx}, changed: {len(changed)} ({len(changed)*chunk//1024//1024} MiB)')
with open(os.path.join(work, 'manifest.txt'), 'w') as m:
    for idx, p, h in changed:
        m.write(f'{idx} {os.path.basename(p)} {h}\n')
PY

manifest="$work/manifest.txt"
[ -s "$manifest" ] || { echo "nothing to do: images are identical"; exit 0; }

echo "===== pushing ====="
while read -r idx file hash; do
    adb push -q "$work/$file" "/tmp/$file" >/dev/null
    echo -n "chunk $idx ($file): writing at $((idx * CHUNK_MIB)) MiB ... "
    adb shell "dd if=/tmp/$file of=$dev bs=1048576 seek=$((idx * CHUNK_MIB)) conv=notrunc 2>/dev/null; sync" >/dev/null
    got=$(adb shell "dd if=$dev bs=1048576 skip=$((idx * CHUNK_MIB)) count=$CHUNK_MIB 2>/dev/null | sha256sum" | cut -d' ' -f1 | tr -d '\r')
    want=$(adb shell "sha256sum /tmp/$file" | cut -d' ' -f1 | tr -d '\r')
    if [ "$got" != "$want" ]; then
        echo "MISMATCH (want $want got $got)"
        exit 1
    fi
    adb shell "rm -f /tmp/$file"
    echo "ok"
done < "$manifest"
echo "device partition updated - reboot to iOS (no migration expected)"
