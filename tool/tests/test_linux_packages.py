import importlib.util
import io
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tool' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


packages = load('linux_packages', 'package-linux.py')

BUNDLE_FILES = (
    'asterlink',
    'asterlink_gopeed',
    'lib/libapp.so',
    'lib/libflutter_linux_gtk.so',
    'data/icudtl.dat',
    'data/flutter_assets/AssetManifest.bin',
    'data/flutter_assets/assets/icons/app.png',
)


def ar_members(payload):
    """Split a .deb into its ar members, mirroring what dpkg-deb does."""
    if not payload.startswith(b'!<arch>\n'):
        raise ValueError('not an ar archive')
    members, offset = {}, 8
    while offset < len(payload):
        header = payload[offset:offset + 60]
        name = header[0:16].decode('ascii').strip()
        size = int(header[48:58].decode('ascii').strip())
        members[name] = payload[offset + 60:offset + 60 + size]
        offset += 60 + size + (size % 2)
    return members


class LinuxPackageTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'pubspec.yaml').write_text(
            'name: asterlink\n'
            'description: 文析助手，支持网盘解析、下载和 BT 在线播放。\n'
            'version: 1.2.3+4\n', encoding='utf-8')
        (self.root / 'LICENSE').write_text('AGPL-3.0-only fixture\n', encoding='utf-8')
        self.bundle = self.root / 'build/linux/x64/release/bundle'
        for name in BUNDLE_FILES:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
        for name in ('asterlink', 'asterlink_gopeed'):
            (self.bundle / name).chmod(0o755)
        self.output = self.root / '.local/release-assets'

    def deb_options(self, **kwargs):
        options = dict(version='1.2.3+4', maintainer='m',
                       homepage='https://example.invalid',
                       description='fixture', root=self.root)
        options.update(kwargs)
        return options

    def arch_options(self, **kwargs):
        options = dict(version='1.2.3+4', pkgrel='1', packager='p',
                       homepage='https://example.invalid',
                       description='fixture', root=self.root, compression='gzip')
        options.update(kwargs)
        return options

    def test_deb_installs_under_opt_and_links_usr_bin(self):
        path = packages.build_deb(self.bundle, self.output, **self.deb_options())
        self.assertEqual(path.name, 'asterlink_1.2.3+4_amd64.deb')
        members = ar_members(path.read_bytes())
        self.assertEqual(members['debian-binary'], b'2.0\n')
        self.assertIn('control.tar.xz', members)
        self.assertIn('data.tar.xz', members)
        with tarfile.open(fileobj=io.BytesIO(members['data.tar.xz'])) as archive:
            entries = {member.name: member for member in archive.getmembers()}
        link = entries['./usr/bin/asterlink']
        self.assertTrue(link.issym())
        self.assertEqual(link.linkname, '/opt/asterlink/asterlink')
        self.assertEqual(entries['./opt/asterlink/asterlink'].mode & 0o777, 0o755)
        self.assertIn('./usr/share/applications/com.asterlink.asterlink.desktop', entries)
        self.assertIn('./usr/share/icons/hicolor/512x512/apps/asterlink.png', entries)
        self.assertIn('./usr/share/doc/asterlink/copyright', entries)

    def test_deb_control_names_runtime_dependencies(self):
        path = packages.build_deb(self.bundle, self.output, **self.deb_options())
        members = ar_members(path.read_bytes())
        with tarfile.open(fileobj=io.BytesIO(members['control.tar.xz'])) as archive:
            text = archive.extractfile('./control').read().decode('utf-8')
        self.assertIn('Package: asterlink\n', text)
        self.assertIn('Version: 1.2.3+4\n', text)
        self.assertIn('Architecture: amd64\n', text)
        self.assertIn('libgtk-3-0t64 | libgtk-3-0', text)
        self.assertIn('libmpv2 | libmpv1', text)
        self.assertIn('libc6 (>= 2.38)', text)
        self.assertNotIn('filesystem', text)
        # A Secret Service provider is recommended, never required: the app only
        # stalls without one when a session bus exists but has no provider.
        self.assertIn('Recommends: gnome-keyring\n', text)
        depends = [line for line in text.splitlines() if line.startswith('Depends: ')][0]
        self.assertNotIn('gnome-keyring', depends)
        with tarfile.open(fileobj=io.BytesIO(members['control.tar.xz'])) as archive:
            sums = archive.extractfile('./md5sums').read().decode('utf-8')
        # dpkg's md5sums covers regular files; the /usr/bin symlink is not listed.
        self.assertIn('opt/asterlink/asterlink\n', sums)
        self.assertIn('usr/share/applications/com.asterlink.asterlink.desktop\n', sums)
        self.assertNotIn('usr/bin/asterlink', sums)

    def test_deb_refuses_a_second_build_of_the_same_version(self):
        packages.build_deb(self.bundle, self.output, **self.deb_options())
        with self.assertRaises(ValueError):
            packages.build_deb(self.bundle, self.output, **self.deb_options())

    def test_arch_package_has_pkginfo_and_the_same_tree(self):
        path = packages.build_arch(self.bundle, self.output, **self.arch_options())
        self.assertEqual(path.name, 'asterlink-1.2.3+4-1-x86_64.pkg.tar.gz')
        with tarfile.open(path) as archive:
            entries = {member.name: member for member in archive.getmembers()}
            info = archive.extractfile('.PKGINFO').read().decode('utf-8')
        self.assertEqual(entries['usr/bin/asterlink'].linkname, '/opt/asterlink/asterlink')
        self.assertEqual(entries['opt/asterlink/asterlink'].mode & 0o777, 0o755)
        self.assertIn('usr/share/applications/com.asterlink.asterlink.desktop', entries)
        self.assertIn('pkgname = asterlink\n', info)
        self.assertIn('pkgver = 1.2.3+4-1\n', info)
        self.assertIn('arch = x86_64\n', info)
        self.assertIn('license = AGPL-3.0-only\n', info)
        self.assertIn('depend = gtk3\n', info)
        self.assertNotIn('framework', info)
        # Arch has no "recommends"; the optional dependency is how the package
        # points at a Secret Service provider.
        self.assertIn('optdepend = gnome-keyring:', info)

    def test_arch_compression_choice_is_visible_in_the_name(self):
        path = packages.build_arch(self.bundle, self.output, **self.arch_options())
        self.assertTrue(path.name.endswith('.pkg.tar.gz'))
        with tarfile.open(path) as archive:
            self.assertIn(b'pkgname = asterlink', archive.extractfile('.PKGINFO').read())

    def test_bundle_without_the_helper_is_rejected(self):
        (self.bundle / 'asterlink_gopeed').unlink()
        with self.assertRaises(ValueError):
            packages.build_arch(self.bundle, self.output, **self.arch_options())

    def test_bundle_with_private_files_is_rejected(self):
        (self.bundle / 'data/ci-release.jks').write_bytes(b'secret')
        with self.assertRaises(ValueError):
            packages.build_arch(self.bundle, self.output, **self.arch_options())

    def test_bundle_with_a_symlink_is_rejected(self):
        # Cover both shapes: a link to a file that exists on this machine and a
        # dangling one. The second is the interesting case, because a link whose
        # target is missing does not report as a file at all.
        (self.bundle / 'lib/alias.so').symlink_to(self.bundle / 'lib/libapp.so')
        with self.assertRaises(ValueError):
            packages.build_arch(self.bundle, self.output, **self.arch_options())
        (self.bundle / 'lib/alias.so').unlink()
        (self.bundle / 'lib/alias.so').symlink_to('/nonexistent/asterlink-fixture.so')
        with self.assertRaises(ValueError):
            packages.build_arch(self.bundle, self.output, **self.arch_options())

    def test_versions_must_match_the_pubspec(self):
        (self.root / 'pubspec.yaml').write_text('name: asterlink\nversion: 1.2.3\n',
                                                encoding='utf-8')
        with self.assertRaises(ValueError):
            packages.version_of(self.root)
        (self.root / 'pubspec.yaml').write_text('name: asterlink\nversion: 1.2.3+4\n',
                                                encoding='utf-8')
        self.assertEqual(packages.version_of(self.root), '1.2.3+4')

    def test_source_date_epoch_makes_packages_reproducible(self):
        first = packages.build_deb(self.bundle, self.output, **self.deb_options(version='1.0.0+1'))
        original = first.read_bytes()
        first.unlink()
        previous = os.environ.get('SOURCE_DATE_EPOCH')
        os.environ['SOURCE_DATE_EPOCH'] = str(packages.DEFAULT_EPOCH)
        try:
            second = packages.build_deb(self.bundle, self.output, **self.deb_options(version='1.0.0+1'))
        finally:
            if previous is None:
                os.environ.pop('SOURCE_DATE_EPOCH', None)
            else:
                os.environ['SOURCE_DATE_EPOCH'] = previous
        self.assertEqual(original, second.read_bytes())

    def test_deb_architecture_uses_the_host_machine(self):
        architecture = packages.DEB_ARCH[packages.machine_arch()]
        path = packages.build_deb(self.bundle, self.output, **self.deb_options())
        self.assertTrue(path.name.endswith('_' + architecture + '.deb'))


if __name__ == '__main__':
    unittest.main()
