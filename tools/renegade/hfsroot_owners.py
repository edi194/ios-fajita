#!/usr/bin/env python3
"""Set owner/group/mode of the catalog records of an unjournaled HFS+/HFSX image in place, without sudo.

  hfsroot_owners.py IMAGE [--map MAPFILE] [--default-root]

The unprivileged Mac user cannot chown, so the image is built as the user (everything uid 501) and then fixed
here, by editing the catalog B-tree leaves. Differences to hfsroot_chown.py (RAM-disk root, everything 0:0):

* follows the catalog file through the extents-overflow B-tree (a 16 GiB root has ~400k records, the catalog
  fragments into more than the 8 extents of the volume header),
* MAPFILE (tab separated "relative/path<TAB>uid<TAB>gid<TAB>mode-octal", NFD-normalized or not, one record per
  line, written by mkroot-full.py from lstat() of the mounted IPSW volumes) gives the real owner and permission
  bits of every file; paths missing from the map become 0:0 with the mode left alone (--default-root; without
  it they are left untouched),
* hard links: a link record (type 'hlnk'/'hfs+') carries no permissions of its own, the "iNode<N>" file in
  "\\0\\0\\0\\0HFS+ Private Data" does; the map entry of any path that is a link is applied to its iNode record.
* only the 12 permission bits (rwx, setuid/setgid/sticky) of the mode are replaced, the file type bits stay.
"""
import struct
import sys
import unicodedata

ROOT_CNID = 2
HLNK = (0x686C6E6B, 0x6866732B)        # fileType 'hlnk', creator 'hfs+'


def u16str(b):
    return b.decode('utf-16-be')


class Volume:
    def __init__(self, f):
        self.f = f
        f.seek(1024)
        vh = f.read(512)
        assert vh[:2] in (b'H+', b'HX'), f'not HFS+/HFSX: {vh[:2]!r}'
        assert not (struct.unpack_from('>I', vh, 4)[0] & (1 << 13)), 'volume is journaled (newfs_hfs without -J)'
        self.bsize = struct.unpack_from('>I', vh, 40)[0]
        self.vh = vh

    def fork(self, off):
        logical = struct.unpack_from('>Q', self.vh, off)[0]
        ext = [struct.unpack_from('>II', self.vh, off + 16 + 8 * i) for i in range(8)]
        return logical, [e for e in ext if e[1]]

    def read_extents(self, extents, size):
        out = bytearray()
        for s, c in extents:
            self.f.seek(s * self.bsize)
            out += self.f.read(c * self.bsize)
        return out[:size]

    def catalog_extents(self):
        logical, ext = self.fork(272)
        have = sum(c for s, c in ext)
        need = (logical + self.bsize - 1) // self.bsize
        if have >= need:
            return logical, ext
        # extents-overflow B-tree (volume header offset 192)
        elogical, eext = self.fork(192)
        data = self.read_extents(eext, elogical)
        nodesize = struct.unpack_from('>H', data, 14 + 18)[0]
        node = struct.unpack_from('>I', data, 14 + 10)[0]
        extra = []
        while node:
            nd = data[node * nodesize:(node + 1) * nodesize]
            flink, blink, kind, height, nrec = struct.unpack_from('>IIbBH', nd, 0)
            for i in range(nrec):
                ro = struct.unpack_from('>H', nd, nodesize - 2 * (i + 1))[0]
                klen, fork, pad, fid, start = struct.unpack_from('>HBBII', nd, ro)
                if fid == 4 and fork == 0:
                    for j in range(8):
                        s, c = struct.unpack_from('>II', nd, ro + 2 + klen + 8 * j)
                        if c:
                            extra.append((start, s, c))
            node = flink
        ext = list(ext) + [(s, c) for _, s, c in sorted(extra)]
        assert sum(c for s, c in ext) >= need, 'catalog extents incomplete'
        return logical, ext


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    img = args[0]
    mapfile = args[args.index('--map') + 1] if '--map' in args else None
    default_root = '--default-root' in args
    owners = {}
    if mapfile:
        for line in open(mapfile, encoding='utf-8', errors='surrogateescape'):
            p, u, g, m = line.rstrip('\n').split('\t')
            owners[unicodedata.normalize('NFD', p)] = (int(u), int(g), int(m, 8))
    f = open(img, 'r+b')
    vol = Volume(f)
    logical, extents = vol.catalog_extents()
    cat = vol.read_extents(extents, logical)
    cat = bytearray(cat)
    nodesize = struct.unpack_from('>H', cat, 14 + 18)[0]
    first = struct.unpack_from('>I', cat, 14 + 10)[0]

    # pass 1: index every leaf record
    recs = []                                   # (node offset in cat of the record data start, type, parent, name)
    thread_of = {}                              # folder cnid -> (parent, name)
    n = first
    leafnodes = 0
    while n:
        base = n * nodesize
        flink, blink, kind, height, nrec = struct.unpack_from('>IIbBH', cat, base)
        assert kind == -1, f'node {n} is not a leaf'
        for i in range(nrec):
            ro = base + struct.unpack_from('>H', cat, base + nodesize - 2 * (i + 1))[0]
            klen = struct.unpack_from('>H', cat, ro)[0]
            parent = struct.unpack_from('>I', cat, ro + 2)[0]
            nlen = struct.unpack_from('>H', cat, ro + 6)[0]
            name = u16str(bytes(cat[ro + 8:ro + 8 + 2 * nlen]))
            d = ro + 2 + klen
            d += d & 1
            rtype = struct.unpack_from('>H', cat, d)[0]
            if rtype == 3:                      # folder thread: key.parent = cnid, data: parent + name
                tp = struct.unpack_from('>I', cat, d + 4)[0]
                tl = struct.unpack_from('>H', cat, d + 8)[0]
                thread_of[parent] = (tp, u16str(bytes(cat[d + 10:d + 10 + 2 * tl])))
            elif rtype in (1, 2):
                cnid = struct.unpack_from('>I', cat, d + 8)[0]
                recs.append((d, rtype, parent, name, cnid))
        n = flink
        leafnodes += 1

    # paths of folders
    cache = {ROOT_CNID: ''}

    def fpath(cnid):
        if cnid in cache:
            return cache[cnid]
        tp, nm = thread_of[cnid]
        p = fpath(tp)
        cache[cnid] = p + '/' + nm if p else nm
        return cache[cnid]

    private = next((c for c, (tp, nm) in thread_of.items() if tp == ROOT_CNID and nm.startswith('\0\0\0\0HFS+')), None)
    inode = {}                                  # iNode number -> record offset
    for d, rtype, parent, name, cnid in recs:
        if rtype == 2 and parent == private and name.startswith('iNode'):
            inode[int(name[5:])] = d

    stats = dict(mapped=0, defaulted=0, links=0, missing_inode=0, skipped=0)

    def put(d, uid, gid, mode):
        struct.pack_into('>II', cat, d + 32, uid, gid)
        if mode is not None:
            old = struct.unpack_from('>H', cat, d + 32 + 10)[0]
            struct.pack_into('>H', cat, d + 32 + 10, (old & ~0o7777) | (mode & 0o7777))

    for d, rtype, parent, name, cnid in recs:
        if parent == private and rtype == 2 and name.startswith('iNode'):
            continue                            # handled through the link records
        if parent == 1 and rtype == 1:
            continue
        if rtype == 2 and parent == private:
            continue
        path = fpath(parent) if parent != ROOT_CNID else ''
        rel = path + '/' + name if path else name
        if rtype == 1:
            rel = fpath(cnid)
        target = d
        if rtype == 2:
            ftype, creator = struct.unpack_from('>II', cat, d + 48)
            if (ftype, creator) == HLNK:
                num = struct.unpack_from('>I', cat, d + 32 + 12)[0]
                stats['links'] += 1
                if num not in inode:
                    stats['missing_inode'] += 1
                    continue
                target = inode[num]
        ent = owners.get(rel)
        if ent is not None:
            put(target, *ent)
            stats['mapped'] += 1
        elif default_root:
            put(target, 0, 0, None)
            stats['defaulted'] += 1
        else:
            stats['skipped'] += 1
    if default_root:                            # root folder and the private data folder itself
        for d, rtype, parent, name, cnid in recs:
            if rtype == 1 and (cnid == ROOT_CNID or cnid == private):
                ent = owners.get('') if cnid == ROOT_CNID else None
                put(d, *(ent if ent else (0, 0, None)))

    # HFSX folder counts: macOS keeps kHFSHasFolderCountMask (0x10 in the folder record's flags) and the number of
    # subfolders (folderCount, offset 84) on every folder; Linux's hfsplus driver leaves them unset on the root folder,
    # which fsck_hfs then reports ("HasFolderCount flag needs to be set (id = 2)") and the seal stage refuses
    subdirs = {}
    for d, rtype, parent, name, cnid in recs:
        if rtype == 1:
            subdirs[parent] = subdirs.get(parent, 0) + 1
    counted = 0
    for d, rtype, parent, name, cnid in recs:
        if rtype == 1 and not struct.unpack_from('>H', cat, d + 2)[0] & 0x10:
            struct.pack_into('>H', cat, d + 2, struct.unpack_from('>H', cat, d + 2)[0] | 0x10)
            struct.pack_into('>I', cat, d + 84, subdirs.get(cnid, 0))
            counted += 1
    stats['folder_counts_set'] = counted

    # write the catalog back, extent by extent
    pos = 0
    for s, c in extents:
        span = c * vol.bsize
        chunk = cat[pos:pos + span]
        if not chunk:
            break
        f.seek(s * vol.bsize)
        f.write(chunk)
        pos += span
    f.close()
    print(f'{len(recs)} records in {leafnodes} leaf nodes ({len(extents)} catalog extents): {stats}')


if __name__ == '__main__':
    main()
