#!/usr/bin/env python3
"""berga-tools: the prebuilt on-device binaries of Bergamota (sweetnet tools, the bglrender payload), as a release asset.

  berga_tools.py [--tag berga-tools-vN] [--repo OWNER/REPO] [--cache DIR] [--sha256 HEX] [--force]
                                          download berga-tools.zip from the GitHub release (the newest berga-tools-v* one
                                          without --tag), verify it, extract it into the cache
  berga_tools.py --zip FILE [--sha256 HEX]  the same from a local zip (offline)
  berga_tools.py --status                   print the cache and what `renegade root` / `renegade update` will use

Python standard library only (urllib, zipfile, hashlib): the same on macOS and Linux, no gh, no curl.

Verification, in this order (a failure removes everything it extracted and exits 1):
  1. the zip against the SHA-256 given with --sha256, or the `digest` GitHub reports for the asset, or the
     berga-tools.zip.sha256 asset of the release (a warning if the release has none of them);
  2. every file in the zip against berga-tools.json (SHA-256 and size), with no file missing and no file unlisted;
  3. every path is relative and stays inside the cache directory.

The cache is $RENEGADE_TOOLS_CACHE, else $XDG_CACHE_HOME/bergamota/berga-tools, else ~/.cache/bergamota/berga-tools. It holds one
directory per tag plus `current`, the tag in use. $RENEGADE_BERGA_TOOLS points at an already extracted directory instead.
root_tweaks18.py looks in local builds first (research/sweetnet, research/bergamota-gl, $RENEGADE_SWEETNET, $RENEGADE_BGL) and
only then in <cache>/<current>/sweetnet and <cache>/<current>/bergamota-gl.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

DEFAULT_REPO = 'ry-diffusion/Bergamota'
ASSET = 'berga-tools.zip'
MANIFEST = 'berga-tools.json'
TAG_RE = re.compile(r'^berga-tools-v(\d+)$')
API = 'https://api.github.com'
UA = 'renegade-fetch-tools'
TIMEOUT = 60


class ToolsError(Exception):
    pass


def cache_root():
    env = os.environ.get('RENEGADE_TOOLS_CACHE')
    if env:
        return os.path.abspath(env)
    base = os.environ.get('XDG_CACHE_HOME') or os.path.join(os.path.expanduser('~'), '.cache')
    return os.path.join(base, 'bergamota', 'berga-tools')


def current_dir(cache=None):
    """The extracted berga-tools directory in use, or None: $RENEGADE_BERGA_TOOLS, else <cache>/<contents of current>."""
    env = os.environ.get('RENEGADE_BERGA_TOOLS')
    if env:
        return os.path.abspath(env) if os.path.isdir(env) else None
    cache = cache or cache_root()
    try:
        with open(os.path.join(cache, 'current')) as f:
            tag = f.read().strip()
    except OSError:
        return None
    d = os.path.join(cache, tag)
    if tag and os.sep not in tag and tag not in ('.', '..') and os.path.isfile(os.path.join(d, MANIFEST)):
        return d
    return None


def search_dirs(cache=None):
    """(sweetnet dir, bergamota-gl dir) of the berga-tools in use, each None when absent. Looked up AFTER local builds."""
    d = current_dir(cache)
    if not d:
        return None, None
    sn, gl = os.path.join(d, 'sweetnet'), os.path.join(d, 'bergamota-gl')
    return (sn if os.path.isdir(sn) else None), (gl if os.path.isdir(gl) else None)


def ssh_dir(cache=None):
    """The ssh/ dir (dropbear, dash, toybox; berga-tools-v2 and later) of the berga-tools in use, or None."""
    d = current_dir(cache)
    d = d and os.path.join(d, 'ssh')
    return d if d and os.path.isdir(d) else None


# ---------------------------------------------------------------------------------------------------- network

def _get(url, headers=None, opener=None):
    req = urllib.request.Request(url, headers=dict({'User-Agent': UA}, **(headers or {})))
    try:
        return (opener or urllib.request.urlopen)(req, timeout=TIMEOUT)
    except urllib.error.HTTPError as e:
        raise ToolsError('%s: HTTP %d %s' % (url, e.code, e.reason))
    except (urllib.error.URLError, OSError) as e:
        raise ToolsError('%s: %s' % (url, getattr(e, 'reason', e)))


def api_json(path, opener=None):
    h = {'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'}
    tok = os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN')
    if tok:                                       # only for the API (rate limit); never sent to the download redirect
        h['Authorization'] = 'Bearer ' + tok
    with _get(API + path, h, opener) as r:
        return json.load(r)


def pick_release(releases, tag=None):
    """The release to install. With a tag: that one. Without: the highest berga-tools-vN that is not a draft and carries the zip
    (the API's /releases/latest skips prereleases, and berga-tools releases are prereleases, so the list is read instead)."""
    best = None
    for r in releases:
        if r.get('draft'):
            continue
        t = r.get('tag_name') or ''
        if tag:
            if t == tag:
                return r
            continue
        m = TAG_RE.match(t)
        if m and any(a.get('name') == ASSET for a in r.get('assets', [])):
            if best is None or int(m.group(1)) > best[0]:
                best = (int(m.group(1)), r)
    if tag or best is None:
        raise ToolsError('no release %s with %s found' % (('tagged ' + tag) if tag else 'berga-tools-vN', ASSET))
    return best[1]


def find_release(repo, tag=None, opener=None):
    if tag:
        return pick_release([api_json('/repos/%s/releases/tags/%s' % (repo, tag), opener)], tag)
    return pick_release(api_json('/repos/%s/releases?per_page=50' % repo, opener))


def download(url, dest, opener=None):
    h = hashlib.sha256()
    with _get(url, opener=opener) as r, open(dest, 'wb') as f:
        for chunk in iter(lambda: r.read(1 << 20), b''):
            h.update(chunk)
            f.write(chunk)
    return h.hexdigest()


def expected_zip_sha256(release, given=None, opener=None):
    """The SHA-256 the zip must have: --sha256, the asset's `digest`, or the berga-tools.zip.sha256 asset. None if there is none."""
    if given:
        return given.lower()
    assets = {a.get('name'): a for a in release.get('assets', [])}
    dg = (assets.get(ASSET) or {}).get('digest') or ''
    if dg.startswith('sha256:'):
        return dg[7:].lower()
    side = assets.get(ASSET + '.sha256')
    if side:
        with _get(side['browser_download_url'], opener=opener) as r:
            m = re.match(rb'\s*([0-9a-fA-F]{64})\b', r.read(4096))
        if m:
            return m.group(1).decode().lower()
    return None


# ---------------------------------------------------------------------------------------------------- the zip

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def safe_rel(name):
    """A normalized relative path with no .. and no absolute or drive part, or ToolsError."""
    if not name or name.startswith(('/', '\\')) or '\\' in name or '\x00' in name or re.match(r'^[A-Za-z]:', name):
        raise ToolsError('unsafe path in the zip: %r' % name)
    parts = name.split('/')
    if any(p in ('', '.', '..') for p in parts):
        raise ToolsError('unsafe path in the zip: %r' % name)
    return '/'.join(parts)


def read_manifest(zf):
    try:
        m = json.loads(zf.read(MANIFEST))
    except KeyError:
        raise ToolsError('%s is not in the zip' % MANIFEST)
    except ValueError as e:
        raise ToolsError('%s is not valid JSON: %s' % (MANIFEST, e))
    if not isinstance(m.get('files'), list) or not m.get('tag'):
        raise ToolsError('%s has no tag or files' % MANIFEST)
    return m


def verify_zip(zf, manifest):
    """Every file of the zip against the manifest (SHA-256 and size; none missing, none unlisted, no duplicates)."""
    listed = {}
    for e in manifest['files']:
        p = safe_rel(e['path'])
        if p in listed or p == MANIFEST:
            raise ToolsError('manifest lists %s twice or lists itself' % p)
        listed[p] = e
    infos = {}
    for i in zf.infolist():
        if i.is_dir():
            continue
        p = safe_rel(i.filename)
        if p in infos:
            raise ToolsError('%s appears twice in the zip' % p)
        infos[p] = i
    infos.pop(MANIFEST, None)
    extra, missing = sorted(set(infos) - set(listed)), sorted(set(listed) - set(infos))
    if extra:
        raise ToolsError('files in the zip that the manifest does not list: ' + ', '.join(extra))
    if missing:
        raise ToolsError('files in the manifest that are not in the zip: ' + ', '.join(missing))
    for p, e in listed.items():
        h, n = hashlib.sha256(), 0
        with zf.open(infos[p]) as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
                n += len(chunk)
        if h.hexdigest() != e['sha256'].lower() or n != e.get('size', n):
            raise ToolsError('%s does not match the manifest (sha256 %s, manifest %s)' % (p, h.hexdigest(), e['sha256']))
    return listed, infos


def install_zip(zip_path, cache=None, expect_sha256=None, force=False, log=print):
    """Verify zip_path and extract it to <cache>/<tag>/, then make that tag current. Returns the directory."""
    cache = cache or cache_root()
    got = sha256_file(zip_path)
    if expect_sha256 and got != expect_sha256.lower():
        raise ToolsError('%s: SHA-256 %s, expected %s' % (os.path.basename(zip_path), got, expect_sha256.lower()))
    if not expect_sha256:
        log('warning: no SHA-256 for the zip itself (--sha256, the asset digest or %s.sha256); checking the manifest only' % ASSET)
    with zipfile.ZipFile(zip_path) as zf:
        manifest = read_manifest(zf)
        tag = manifest['tag']
        if not TAG_RE.match(tag):
            raise ToolsError('manifest tag %r is not berga-tools-vN' % tag)
        listed, infos = verify_zip(zf, manifest)
        dest = os.path.join(cache, tag)
        if os.path.isfile(os.path.join(dest, MANIFEST)) and not force:
            same = sha256_file(os.path.join(dest, MANIFEST)) == hashlib.sha256(zf.read(MANIFEST)).hexdigest()
            if same:
                log('%s is already in %s (--force to extract again)' % (tag, cache))
                set_current(cache, tag)
                return dest
        os.makedirs(cache, exist_ok=True)
        tmp = tempfile.mkdtemp(prefix='.extract-', dir=cache)
        try:
            for p, i in list(infos.items()) + [(MANIFEST, zf.getinfo(MANIFEST))]:
                out = os.path.join(tmp, *p.split('/'))
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with zf.open(i) as src, open(out, 'wb') as dst:
                    shutil.copyfileobj(src, dst)
                mode = (i.external_attr >> 16) & 0o777
                os.chmod(out, 0o755 if mode & 0o111 else 0o644)
            for root, _, files in os.walk(tmp):                 # the extracted tree is checked once more, from disk
                for fn in files:
                    full = os.path.join(root, fn)
                    rel = os.path.relpath(full, tmp).replace(os.sep, '/')
                    if rel != MANIFEST and sha256_file(full) != listed[rel]['sha256'].lower():
                        raise ToolsError('%s changed on the way to the disk' % rel)
            if os.path.exists(dest):
                shutil.rmtree(dest)
            os.rename(tmp, dest)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
    set_current(cache, tag)
    log('installed %s (%d files) in %s' % (tag, len(listed) + 1, dest))
    return dest


def set_current(cache, tag):
    tmp = os.path.join(cache, '.current.tmp')
    with open(tmp, 'w') as f:
        f.write(tag + '\n')
    os.replace(tmp, os.path.join(cache, 'current'))


def fetch(repo=DEFAULT_REPO, tag=None, cache=None, sha256=None, force=False, opener=None, log=print):
    cache = cache or cache_root()
    rel = find_release(repo, tag, opener)
    asset = next((a for a in rel.get('assets', []) if a.get('name') == ASSET), None)
    if not asset:
        raise ToolsError('release %s has no %s asset' % (rel.get('tag_name'), ASSET))
    want = expected_zip_sha256(rel, sha256, opener)
    os.makedirs(cache, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.download-', suffix='.zip', dir=cache)
    os.close(fd)
    try:
        log('downloading %s from %s (%s, %d bytes)' % (ASSET, rel.get('html_url') or rel.get('tag_name'), rel['tag_name'],
                                                          asset.get('size', 0)))
        download(asset['browser_download_url'], tmp, opener)
        return install_zip(tmp, cache, want, force, log)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def status(cache=None, log=print):
    cache = cache or cache_root()
    log('cache: ' + cache)
    d = current_dir(cache)
    if not d:
        log('berga-tools: none installed (renegade fetch-tools)')
        return 1
    with open(os.path.join(d, MANIFEST)) as f:
        m = json.load(f)
    log('current: %s (%s, commit %s, %d files)' % (m.get('tag'), d, str(m.get('commit', '?'))[:12], len(m['files'])))
    sn, gl = search_dirs(cache)
    log('  sweetnet     -> %s' % (sn or 'absent'))
    log('  bergamota-gl -> %s' % (gl or 'absent'))
    log('  ssh          -> %s' % (ssh_dir(cache) or 'absent (berga-tools-v2 and later: dropbear, dash = /bin/sh, toybox)'))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog='renegade fetch-tools', description=__doc__.split('\n\n')[0])
    ap.add_argument('--tag', help='release tag (default: the newest berga-tools-vN)')
    ap.add_argument('--repo', default=os.environ.get('BERGA_TOOLS_REPO', DEFAULT_REPO))
    ap.add_argument('--cache', help='cache directory (default: %s)' % cache_root())
    ap.add_argument('--zip', help='install this local berga-tools.zip instead of downloading')
    ap.add_argument('--sha256', help='expected SHA-256 of the zip')
    ap.add_argument('--force', action='store_true', help='extract again even if the tag is already in the cache')
    ap.add_argument('--status', action='store_true', help='show what is installed and exit')
    a = ap.parse_args(argv)
    try:
        if a.status:
            return status(a.cache)
        if a.zip:
            install_zip(a.zip, a.cache, a.sha256, a.force)
        else:
            fetch(a.repo, a.tag, a.cache, a.sha256, a.force)
    except (ToolsError, zipfile.BadZipFile) as e:
        print('fetch-tools: %s' % e, file=sys.stderr)
        return 1
    status(a.cache)
    return 0


if __name__ == '__main__':
    sys.exit(main())
