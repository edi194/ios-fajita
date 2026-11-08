"""Unit tests for berga_tools.py (`renegade fetch-tools`) and the lookup order in root_tweaks18.py. Offline: a fake zip and a fake
urlopen stand in for GitHub; nothing touches the network or the real cache.

  python3 -I -m unittest discover -s tools/renegade/tests -v          (from the repo root)
"""
import hashlib
import importlib.util
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
RENEGADE = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, RENEGADE)
import berga_tools as bt  # noqa: E402


def sha(b):
    return hashlib.sha256(b).hexdigest()


FILES = {
    'sweetnet/ios18/sweetuicache': (b'\xcf\xfa\xed\xfeuicache', 0o755),
    'sweetnet/sweetreboot': (b'\xcf\xfa\xed\xfereboot', 0o755),
    'bergamota-gl/bgl-launch': (b'\xcf\xfa\xed\xfelaunch', 0o755),
    'bergamota-gl/libOSMesa.8.dylib': (b'\xcf\xfa\xed\xfemesa', 0o755),
    'LICENSES/NOTICE.txt': (b'notice\n', 0o644),
}


def make_zip(path, tag='berga-tools-v7', files=FILES, tamper=None, extra=None, manifest_edit=None):
    entries = [{'path': p, 'sha256': sha(d), 'size': len(d), 'arch': 'arm64e'} for p, (d, m) in sorted(files.items())]
    manifest = {'schema': 1, 'name': 'berga-tools', 'version': '7', 'tag': tag, 'commit': 'a' * 40, 'files': entries}
    if manifest_edit:
        manifest_edit(manifest)
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(bt.MANIFEST, json.dumps(manifest))
        for p, (d, m) in files.items():
            zi = zipfile.ZipInfo(p, (2026, 1, 1, 0, 0, 0))
            zi.external_attr = (0o100000 | m) << 16
            zf.writestr(zi, tamper(p, d) if tamper else d)
        for p, d in (extra or {}).items():
            zf.writestr(p, d)


class FakeResp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


class FakeGitHub:
    """urlopen stand-in: serves canned JSON for the API and the zip / checksum for the download URLs; records the requests."""

    def __init__(self, releases, zip_bytes, side=None):
        self.releases, self.zip_bytes, self.side, self.requests = releases, zip_bytes, side, []

    def __call__(self, req, timeout=None):
        url = req.full_url
        self.requests.append((url, dict(req.header_items())))
        if url.endswith('/releases?per_page=50'):
            return FakeResp(json.dumps(self.releases).encode())
        if '/releases/tags/' in url:
            tag = url.rsplit('/', 1)[1]
            hit = [r for r in self.releases if r['tag_name'] == tag]
            if not hit:
                import urllib.error
                raise urllib.error.HTTPError(url, 404, 'Not Found', {}, None)
            return FakeResp(json.dumps(hit[0]).encode())
        if url.endswith('berga-tools.zip'):
            return FakeResp(self.zip_bytes)
        if url.endswith('berga-tools.zip.sha256'):
            return FakeResp(self.side)
        raise AssertionError('unexpected request ' + url)


def release(tag, prerelease=True, draft=False, with_zip=True, digest=None, side=False):
    assets = []
    if with_zip:
        a = {'name': 'berga-tools.zip', 'size': 10, 'browser_download_url': 'https://example.invalid/%s/berga-tools.zip' % tag}
        if digest:
            a['digest'] = 'sha256:' + digest
        assets.append(a)
    if side:
        assets.append({'name': 'berga-tools.zip.sha256', 'size': 80,
                       'browser_download_url': 'https://example.invalid/%s/berga-tools.zip.sha256' % tag})
    return {'tag_name': tag, 'prerelease': prerelease, 'draft': draft, 'assets': assets, 'html_url': 'https://example.invalid/' + tag}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cache = os.path.join(self.tmp, 'cache')
        self.zip = os.path.join(self.tmp, 'berga-tools.zip')
        make_zip(self.zip)
        self.zip_bytes = open(self.zip, 'rb').read()
        self.log = []
        self.env = {k: os.environ.pop(k, None) for k in ('RENEGADE_TOOLS_CACHE', 'RENEGADE_BERGA_TOOLS', 'GITHUB_TOKEN', 'GH_TOKEN')}

    def tearDown(self):
        for k, v in self.env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)


class TestPickRelease(unittest.TestCase):
    def test_newest_berga_tools_prerelease_wins(self):
        rels = [release('v1.0', prerelease=False), release('berga-tools-v2'), release('berga-tools-v10'),
                release('berga-tools-v11', draft=True), release('berga-tools-v12', with_zip=False)]
        self.assertEqual(bt.pick_release(rels)['tag_name'], 'berga-tools-v10')          # numeric, not lexical; no drafts

    def test_explicit_tag(self):
        rels = [release('berga-tools-v2'), release('berga-tools-v3')]
        self.assertEqual(bt.pick_release(rels, 'berga-tools-v2')['tag_name'], 'berga-tools-v2')

    def test_none_found(self):
        with self.assertRaises(bt.ToolsError):
            bt.pick_release([release('v1.0')])
        with self.assertRaises(bt.ToolsError):
            bt.pick_release([release('berga-tools-v1')], 'berga-tools-v9')


class TestInstall(Base):
    def test_install_extracts_modes_and_current(self):
        d = bt.install_zip(self.zip, self.cache, sha(self.zip_bytes), log=self.log.append)
        self.assertEqual(d, os.path.join(self.cache, 'berga-tools-v7'))
        for p, (data, mode) in FILES.items():
            full = os.path.join(d, *p.split('/'))
            self.assertEqual(open(full, 'rb').read(), data)
            self.assertEqual(bool(os.stat(full).st_mode & stat.S_IXUSR), bool(mode & 0o111), p)
        self.assertTrue(os.path.isfile(os.path.join(d, bt.MANIFEST)))
        self.assertEqual(bt.current_dir(self.cache), d)
        sn, gl = bt.search_dirs(self.cache)
        self.assertEqual(sn, os.path.join(d, 'sweetnet'))
        self.assertEqual(gl, os.path.join(d, 'bergamota-gl'))
        self.assertEqual([n for n in os.listdir(self.cache) if n.startswith('.')], [])      # no temp leftovers

    def test_reinstall_is_idempotent(self):
        bt.install_zip(self.zip, self.cache, log=self.log.append)
        bt.install_zip(self.zip, self.cache, log=self.log.append)
        self.assertTrue(any('already in' in l for l in self.log))

    def test_wrong_zip_sha256(self):
        with self.assertRaises(bt.ToolsError) as c:
            bt.install_zip(self.zip, self.cache, '0' * 64, log=self.log.append)
        self.assertIn('expected', str(c.exception))
        self.assertFalse(os.path.exists(os.path.join(self.cache, 'berga-tools-v7')))

    def test_file_not_matching_manifest(self):
        make_zip(self.zip, tamper=lambda p, d: d + b'!' if p == 'sweetnet/sweetreboot' else d)
        with self.assertRaises(bt.ToolsError) as c:
            bt.install_zip(self.zip, self.cache, log=self.log.append)
        self.assertIn('sweetnet/sweetreboot', str(c.exception))
        self.assertFalse(os.path.exists(os.path.join(self.cache, 'berga-tools-v7')))
        self.assertIsNone(bt.current_dir(self.cache))

    def test_unlisted_file_in_zip(self):
        make_zip(self.zip, extra={'sweetnet/evil': b'x'})
        with self.assertRaises(bt.ToolsError) as c:
            bt.install_zip(self.zip, self.cache, log=self.log.append)
        self.assertIn('does not list', str(c.exception))

    def test_file_missing_from_zip(self):
        def drop(m):
            m['files'].append({'path': 'sweetnet/gone', 'sha256': '0' * 64, 'size': 1})
        make_zip(self.zip, manifest_edit=drop)
        with self.assertRaises(bt.ToolsError) as c:
            bt.install_zip(self.zip, self.cache, log=self.log.append)
        self.assertIn('not in the zip', str(c.exception))

    def test_path_traversal_refused(self):
        for bad in ('../escape', '/abs/path', 'a/../../b', 'a//b', 'C:/x', 'a\\b'):
            with self.assertRaises(bt.ToolsError, msg=bad):
                bt.safe_rel(bad)
        evil = {'../escape': (b'x', 0o644)}
        make_zip(self.zip, files=evil)
        with self.assertRaises(bt.ToolsError):
            bt.install_zip(self.zip, self.cache, log=self.log.append)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, 'escape')))

    def test_manifest_required_and_tag_checked(self):
        with zipfile.ZipFile(self.zip, 'w') as zf:
            zf.writestr('sweetnet/x', b'x')
        with self.assertRaises(bt.ToolsError):
            bt.install_zip(self.zip, self.cache, log=self.log.append)
        make_zip(self.zip, tag='../../etc')
        with self.assertRaises(bt.ToolsError):
            bt.install_zip(self.zip, self.cache, log=self.log.append)

    def test_warns_without_zip_checksum(self):
        bt.install_zip(self.zip, self.cache, log=self.log.append)
        self.assertTrue(any('no SHA-256' in l for l in self.log))


class TestFetch(Base):
    def test_latest_uses_the_list_and_digest(self):
        gh = FakeGitHub([release('berga-tools-v1'), release('berga-tools-v7', digest=sha(self.zip_bytes))], self.zip_bytes)
        d = bt.fetch('o/r', cache=self.cache, opener=gh, log=self.log.append)
        self.assertEqual(os.path.basename(d), 'berga-tools-v7')
        self.assertTrue(gh.requests[0][0].endswith('/repos/o/r/releases?per_page=50'))     # /releases/latest skips prereleases
        self.assertNotIn('no SHA-256', ' '.join(self.log))

    def test_tag_and_sidecar_checksum(self):
        side = ('%s  berga-tools.zip\n' % sha(self.zip_bytes)).encode()
        gh = FakeGitHub([release('berga-tools-v7', side=True)], self.zip_bytes, side)
        bt.fetch('o/r', 'berga-tools-v7', self.cache, opener=gh, log=self.log.append)
        self.assertTrue(any('/releases/tags/berga-tools-v7' in u for u, _ in gh.requests))
        self.assertTrue(os.path.isfile(os.path.join(self.cache, 'berga-tools-v7', bt.MANIFEST)))

    def test_bad_digest_fails_and_leaves_nothing(self):
        gh = FakeGitHub([release('berga-tools-v7', digest='f' * 64)], self.zip_bytes)
        with self.assertRaises(bt.ToolsError):
            bt.fetch('o/r', cache=self.cache, opener=gh, log=self.log.append)
        self.assertEqual(os.listdir(self.cache), [])                                       # temp download removed too

    def test_explicit_sha256_overrides(self):
        gh = FakeGitHub([release('berga-tools-v7', digest='f' * 64)], self.zip_bytes)
        bt.fetch('o/r', cache=self.cache, sha256=sha(self.zip_bytes), opener=gh, log=self.log.append)
        self.assertIsNotNone(bt.current_dir(self.cache))

    def test_token_only_on_the_api(self):
        os.environ['GITHUB_TOKEN'] = 'secret'
        gh = FakeGitHub([release('berga-tools-v7', digest=sha(self.zip_bytes))], self.zip_bytes)
        bt.fetch('o/r', cache=self.cache, opener=gh, log=self.log.append)
        for url, headers in gh.requests:
            auth = {k.lower(): v for k, v in headers.items()}.get('authorization')
            self.assertEqual(auth is not None, url.startswith(bt.API), url)

    def test_http_error_is_a_tools_error(self):
        gh = FakeGitHub([], b'')
        with self.assertRaises(bt.ToolsError):
            bt.fetch('o/r', 'berga-tools-v9', self.cache, opener=gh, log=self.log.append)


class TestLookupOrder(Base):
    """root_tweaks18: a local build wins, then the berga-tools cache; with neither, the feature is skipped, not failed."""

    def load(self):
        os.environ['RENEGADE_PLATFORM'] = 'linux'
        self.addCleanup(os.environ.pop, 'RENEGADE_PLATFORM', None)
        spec = importlib.util.spec_from_file_location('root_tweaks18_bt', os.path.join(RENEGADE, 'root_tweaks18.py'))
        rt = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rt)
        return rt

    def test_cache_after_local(self):
        os.environ['RENEGADE_TOOLS_CACHE'] = self.cache
        bt.install_zip(self.zip, self.cache, log=self.log.append)
        rt = self.load()
        cached = os.path.join(self.cache, 'berga-tools-v7', 'sweetnet')
        self.assertEqual(rt.SWEETNET_DIRS[-1], cached)                                      # last
        rt.SWEETNET_DIRS[:] = [os.path.join(self.tmp, 'no-local-build'), cached]            # this checkout may have a real build
        self.assertEqual(rt.find_sweetnet('ios18/sweetuicache'), os.path.join(cached, 'ios18', 'sweetuicache'))
        local = os.path.join(self.tmp, 'local')
        os.makedirs(os.path.join(local, 'ios18'))
        open(os.path.join(local, 'ios18', 'sweetuicache'), 'w').write('local build')
        rt.SWEETNET_DIRS.insert(0, local)
        self.assertEqual(rt.find_sweetnet('ios18/sweetuicache'), os.path.join(local, 'ios18', 'sweetuicache'))

    def test_bgl_payload_needs_all_files(self):
        os.environ['RENEGADE_TOOLS_CACHE'] = self.cache
        bt.install_zip(self.zip, self.cache, log=self.log.append)
        rt = self.load()
        gl = os.path.join(self.cache, 'berga-tools-v7', 'bergamota-gl')
        self.assertEqual(rt.BGL_DIRS[-1], gl)                                               # last
        rt.BGL_DIRS[:] = [os.path.join(self.tmp, 'no-local-build'), gl]
        self.assertIsNone(rt.find_bgl())                                                    # the fake zip lacks OpenGLES + libdrm
        os.makedirs(os.path.join(gl, 'OpenGLES.framework'))
        for f in ('OpenGLES.framework/OpenGLES', 'libdrm.2.dylib'):
            with open(os.path.join(gl, f), 'wb') as fh:
                fh.write(b'x')
        self.assertEqual(rt.find_bgl(), gl)

    def test_nothing_anywhere_is_still_a_skip(self):
        os.environ['RENEGADE_TOOLS_CACHE'] = os.path.join(self.tmp, 'empty')
        rt = self.load()
        rt.SWEETNET_DIRS[:] = [d for d in rt.SWEETNET_DIRS if d and os.path.basename(os.path.dirname(d)) != 'berga-tools']
        rt.SWEETNET_DIRS[:] = [os.path.join(self.tmp, 'none')]
        rt.BGL_DIRS[:] = [os.path.join(self.tmp, 'none')]
        gaps = rt.tool_gaps({f: True for f in rt.FEATURES})
        self.assertTrue({'appreg', 'posterboard', 'wallpaper', 'bglrender'} <= set(gaps))
        self.assertTrue(all('fetch-tools' in r for f, r in gaps.items() if f in ('bglrender', 'posterboard')))

    def test_env_dir_override(self):
        os.environ['RENEGADE_BERGA_TOOLS'] = os.path.join(self.tmp, 'x')
        self.assertIsNone(bt.current_dir(self.cache))
        os.makedirs(os.path.join(self.tmp, 'x', 'sweetnet'))
        self.assertEqual(bt.search_dirs(self.cache)[0], os.path.join(self.tmp, 'x', 'sweetnet'))


if __name__ == '__main__':
    unittest.main()
