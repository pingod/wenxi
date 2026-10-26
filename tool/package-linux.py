#!/usr/bin/env python3
"""Turn the Flutter Linux release bundle into installable packages.

    python tool/package-linux.py --format deb --format arch
    python tool/package-linux.py --format arch --compression gzip   # for tests

The bundle in build/linux/x64/release/bundle is the only input: the runner finds
data/ and lib/ next to the executable through /proc/self/exe, so the complete
directory is installed under /opt/asterlink and /usr/bin/asterlink is a symlink
to it. Both formats are written with the standard library alone, so the same
code runs on the Arch-based development machine and on the Ubuntu CI runner.
"""
import argparse
import gzip
import hashlib
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

PACKAGE = 'asterlink'
APPLICATION_ID = 'com.asterlink.asterlink'
DISPLAY_NAME = '文析助手'
HOMEPAGE = 'https://github.com/pingod/wenxi'
INSTALL_ROOT = 'opt/asterlink'
DESKTOP_FILE = 'usr/share/applications/' + APPLICATION_ID + '.desktop'
ICON_FILE = 'usr/share/icons/hicolor/512x512/apps/asterlink.png'
COPYRIGHT_FILE = 'usr/share/doc/asterlink/copyright'
REQUIRED_BUNDLE_FILES = (
    'asterlink',
    'asterlink_gopeed',
    'lib/libapp.so',
    'lib/libflutter_linux_gtk.so',
    'data/icudtl.dat',
    'data/flutter_assets/AssetManifest.bin',
)
PRIVATE_PARTS = {'.local', '.git', 'logs', 'diagnostics'}
PRIVATE_SUFFIXES = {'.jks', '.keystore', '.p12', '.pfx', '.log', '.pdb'}
DEFAULT_EPOCH = 1704067200  # 2024-01-01T00:00:00Z keeps builds reproducible.
# The state key lives in the Secret Service, so a desktop session needs a
# provider (gnome-keyring, KWallet, ...) or the first launch waits out the
# D-Bus activation timeout. Recommended, not required: without any session bus
# the app falls back to a local key, and other providers exist.
SECRET_SERVICE = 'gnome-keyring'
DEB_ARCH = {'x86_64': 'amd64', 'aarch64': 'arm64'}
ARCH_ARCH = {'x86_64': 'x86_64', 'aarch64': 'aarch64'}
# Debian renamed several libraries during the t64 transition, so the affected
# names are listed with an alternative instead of pinning a single release.
# libc6 2.38 is the floor because flutter_secure_storage's plugin needs it.
DEB_DEPENDS = (
    'libgtk-3-0t64 | libgtk-3-0',
    'libglib2.0-0t64 | libglib2.0-0',
    'libatk1.0-0t64 | libatk1.0-0',
    'libayatana-appindicator3-1',
    'libsecret-1-0',
    'libmpv2 | libmpv1',
    'libepoxy0',
    'libpango-1.0-0',
    'libcairo2',
    'libcairo-gobject2',
    'libgdk-pixbuf-2.0-0',
    'libharfbuzz0b',
    'libfontconfig1',
    'libdbusmenu-glib4',
    'libstdc++6',
    'libc6 (>= 2.38)',
)
ARCH_DEPENDS = (
    'gtk3',
    'glib2',
    'atk',
    'libayatana-appindicator',
    'libsecret',
    'mpv',
    'libepoxy',
    'pango',
    'cairo',
    'gdk-pixbuf2',
    'harfbuzz',
    'fontconfig',
    'libdbusmenu-glib',
    'gcc-libs',
    'glibc',
)


def version_of(root):
    """Read the marketing version; pubspec stores it as <version>+<build>."""
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+\+[1-9]\d*)\s*$',
                      (Path(root) / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    if not match:
        raise ValueError('Invalid project version')
    return match.group(1)


def description_of(root):
    match = re.search(r'^description:\s*(.+?)\s*$',
                      (Path(root) / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    return match.group(1) if match else DISPLAY_NAME


def epoch_of():
    """Honour SOURCE_DATE_EPOCH so repeated runs produce identical archives."""
    raw = os.environ.get('SOURCE_DATE_EPOCH', '').strip()
    return int(raw) if raw.isdigit() else DEFAULT_EPOCH


def machine_arch():
    machine = os.uname().machine
    return machine if machine in DEB_ARCH else 'x86_64'


def bundle_files(bundle):
    """Validate the release bundle and return (path, relative) pairs."""
    bundle = Path(bundle).resolve()
    for name in REQUIRED_BUNDLE_FILES:
        if not (bundle / name).is_file():
            raise ValueError('Linux bundle is incomplete: missing ' + name)
    files = []
    # Reject links before filtering on is_file(): a link that points outside the
    # bundle does not report as a file when its target is missing, so testing
    # is_file() first would silently skip exactly the entries a package must
    # never carry.
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink() or bundle not in path.resolve().parents:
            raise ValueError('Linux bundle contains a link: ' + path.name)
        if not path.is_file():
            continue
        relative = path.relative_to(bundle)
        if any(part in PRIVATE_PARTS for part in relative.parts) or path.suffix in PRIVATE_SUFFIXES:
            raise ValueError('Linux bundle contains private or development files: '
                             + relative.as_posix())
        files.append((path, relative))
    return files


def stage_tree(bundle, stage, version, root):
    """Lay the bundle plus desktop integration files out for both formats."""
    stage = Path(stage)
    bundle = Path(bundle).resolve()
    payload = stage / INSTALL_ROOT
    payload.mkdir(parents=True)
    for path, relative in bundle_files(bundle):
        destination = payload / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        destination.chmod(path.stat().st_mode & 0o777)
    # A symlink is enough: the runner resolves data/ and lib/ next to the real
    # executable through /proc/self/exe, so nothing depends on the caller's cwd.
    link = stage / 'usr/bin/asterlink'
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to('/' + INSTALL_ROOT + '/asterlink')
    desktop = stage / DESKTOP_FILE
    desktop.parent.mkdir(parents=True, exist_ok=True)
    desktop.write_text('\n'.join((
        '[Desktop Entry]',
        'Type=Application',
        'Name=' + DISPLAY_NAME,
        'Name[en]=AsterLink',
        'Comment=网盘解析、下载与在线播放',
        'Comment[en]=Parse, download and stream from cloud drives',
        'Exec=asterlink %U',
        'Icon=asterlink',
        'Terminal=false',
        'Categories=Network;FileTransfer;',
        'StartupNotify=true',
        'StartupWMClass=' + APPLICATION_ID,
        'Keywords=网盘;下载;cloud;download;torrent;',
        'X-GNOME-UsesNotifications=true',
        '',
    )), encoding='utf-8')
    desktop.chmod(0o644)
    icon = stage / ICON_FILE
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(bundle / 'data/flutter_assets/assets/icons/app.png', icon)
    copyright_file = stage / COPYRIGHT_FILE
    copyright_file.parent.mkdir(parents=True, exist_ok=True)
    # The project is AGPL-3.0-only, so the licence text ships with the package.
    licence = Path(root) / 'LICENSE'
    body = licence.read_text(encoding='utf-8') if licence.is_file() else ''
    copyright_file.write_text(
        'AsterLink ' + version + '\n'
        'Built from the sources at ' + HOMEPAGE + '\n'
        'The download core is Gopeed (GPL-3.0-or-later); the complete\n'
        'third-party notices are installed in data/flutter_assets/assets/licenses/.\n\n'
        + body, encoding='utf-8')
    return stage


def _tar_add(archive, path, arcname, epoch):
    info = archive.gettarinfo(str(path), arcname)
    info.uid = info.gid = 0
    info.uname = info.gname = ''
    info.mtime = epoch
    if info.isreg():
        with path.open('rb') as stream:
            archive.addfile(info, stream)
    else:
        archive.addfile(info)


def _tar_bytes(stage, prefix, epoch, compression=None):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.GNU_FORMAT) as archive:
        stage = Path(stage)
        for path in sorted(stage.rglob('*')):
            _tar_add(archive, path, prefix + path.relative_to(stage).as_posix(), epoch)
    payload = buffer.getvalue()
    return compress(payload, compression) if compression else payload


def _installed_size(stage):
    return sum(path.stat().st_size for path in Path(stage).rglob('*') if path.is_file())


def _md5sums(stage):
    records = []
    for path in sorted(p for p in Path(stage).rglob('*') if p.is_file()):
        digest = hashlib.md5()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        records.append(digest.hexdigest() + '  ' + path.relative_to(stage).as_posix())
    return '\n'.join(records) + '\n'


def _ar_bytes(members):
    """Write a GNU-style ar archive; dpkg reads .deb files through this format."""
    out = io.BytesIO()
    out.write(b'!<arch>\n')
    for name, payload in members:
        out.write('{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n'.format(
            name, 0, 0, 0, '100644', len(payload)).encode('ascii'))
        out.write(payload)
        if len(payload) % 2:
            out.write(b'\n')
    return out.getvalue()


def deb_control_text(version, stage, maintainer, homepage, description):
    return '\n'.join((
        'Package: ' + PACKAGE,
        'Version: ' + version,
        'Architecture: ' + DEB_ARCH[machine_arch()],
        'Maintainer: ' + maintainer,
        'Installed-Size: ' + str(max(1, _installed_size(stage) // 1024 + 1)),
        'Depends: ' + ', '.join(DEB_DEPENDS),
        # Not a hard dependency: a session bus without any provider hangs the
        # first launch, but other implementations exist and a bare busless
        # environment works, so installing one is only suggested.
        'Recommends: ' + SECRET_SERVICE,
        'Section: net',
        'Priority: optional',
        'Homepage: ' + homepage,
        'Description: ' + DISPLAY_NAME + ' - ' + description,
        ' AsterLink parses share links from Chinese cloud drives, downloads them',
        ' with the bundled Gopeed helper and plays torrents in its own player.',
        '',
    ))


def build_deb(bundle, output_dir, version, maintainer, homepage, description, root):
    output_dir = Path(output_dir)
    epoch = epoch_of()
    architecture = DEB_ARCH[machine_arch()]
    with tempfile.TemporaryDirectory(prefix='asterlink-deb-') as temporary:
        stage = Path(temporary) / 'root'
        stage.mkdir()
        stage_tree(bundle, stage, version, root)
        control = Path(temporary) / 'control'
        control.mkdir()
        (control / 'control').write_text(
            deb_control_text(version, stage, maintainer, homepage, description),
            encoding='utf-8')
        (control / 'md5sums').write_text(_md5sums(stage), encoding='utf-8')
        members = [
            ('debian-binary', b'2.0\n'),
            ('control.tar.xz', _tar_bytes(control, './', epoch, 'xz')),
            ('data.tar.xz', _tar_bytes(stage, './', epoch, 'xz')),
        ]
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / (PACKAGE + '_' + version + '_' + architecture + '.deb')
    if destination.exists():
        raise ValueError('A Debian package for this version already exists')
    destination.write_bytes(_ar_bytes(members))
    return destination


def _zstd_bytes(payload):
    if shutil.which('zstd'):
        result = subprocess.run(['zstd', '-19', '-T0', '-q', '-c'], input=payload,
                                stdout=subprocess.PIPE, check=False)
        if result.returncode == 0:
            return result.stdout
    try:
        from compression import zstd  # Python 3.14+ ships zstd in the stdlib.
    except ImportError:
        raise ValueError('zstd is required for Arch packages: install the zstd '
                         'binary or use --compression gzip') from None
    return zstd.compress(payload, level=19)


def compress(payload, compression):
    if compression == 'zstd':
        return _zstd_bytes(payload)
    if compression == 'xz':
        import lzma
        return lzma.compress(payload, format=lzma.FORMAT_XZ, preset=6)
    if compression == 'gzip':
        return gzip.compress(payload, mtime=epoch_of())
    raise ValueError('Unsupported compression: ' + str(compression))


def pkg_info(version, pkgrel, stage, packager, homepage, description):
    return '\n'.join((
        '# Generated by tool/package-linux.py',
        'pkgname = ' + PACKAGE,
        'pkgbase = ' + PACKAGE,
        'pkgver = ' + version + '-' + pkgrel,
        'pkgdesc = ' + description,
        'url = ' + homepage,
        'builddate = ' + str(epoch_of()),
        'packager = ' + packager,
        'size = ' + str(_installed_size(stage)),
        'arch = ' + ARCH_ARCH[machine_arch()],
        'license = AGPL-3.0-only',
        *('depend = ' + name for name in ARCH_DEPENDS),
        # Arch has no "recommends"; an optional dependency with a reason is the
        # equivalent way to point at a Secret Service provider.
        'optdepend = ' + SECRET_SERVICE + ': 提供 org.freedesktop.secrets，首次启动保存状态密钥需要（KWallet 等亦可）',
        '',
    ))


def build_arch(bundle, output_dir, version, pkgrel, packager, homepage, description,
               root, compression='zstd'):
    with tempfile.TemporaryDirectory(prefix='asterlink-arch-') as temporary:
        stage = Path(temporary) / 'pkg'
        stage.mkdir()
        stage_tree(bundle, stage, version, root)
        (stage / '.PKGINFO').write_text(
            pkg_info(version, pkgrel, stage, packager, homepage, description),
            encoding='utf-8')
        payload = _tar_bytes(stage, '', epoch_of(), compression)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    suffix = {'zstd': '.pkg.tar.zst', 'gzip': '.pkg.tar.gz'}[compression]
    destination = output_dir / (PACKAGE + '-' + version + '-' + pkgrel + '-'
                                + ARCH_ARCH[machine_arch()] + suffix)
    if destination.exists():
        raise ValueError('An Arch package for this version already exists')
    destination.write_bytes(payload)
    return destination


def main(argv=None):
    parser = argparse.ArgumentParser(description='Build Linux packages from the release bundle.')
    parser.add_argument('--format', action='append', choices=('deb', 'arch'),
                        help='Package format to build; repeat for both (default: both).')
    parser.add_argument('--bundle', help='Release bundle (default: build/linux/x64/release/bundle).')
    parser.add_argument('--output-dir', help='Destination (default: .local/release-assets).')
    parser.add_argument('--version', help='Override the version taken from pubspec.yaml.')
    parser.add_argument('--pkgrel', default='1', help='Arch package release number.')
    parser.add_argument('--maintainer', default='AsterLink packaging <noreply@users.noreply.github.com>')
    parser.add_argument('--packager', default='AsterLink packaging <noreply@users.noreply.github.com>')
    parser.add_argument('--homepage', default=HOMEPAGE)
    parser.add_argument('--compression', default='zstd', choices=('zstd', 'gzip'))
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    formats = args.format or ['deb', 'arch']
    bundle = Path(args.bundle) if args.bundle else root / 'build/linux/x64/release/bundle'
    output_dir = Path(args.output_dir) if args.output_dir else root / '.local/release-assets'
    try:
        version = args.version or version_of(root)
        if not re.fullmatch(r'\d+\.\d+\.\d+(\+\d+)?', version):
            raise ValueError('Version must look like 1.2.3 or 1.2.3+45')
        description = description_of(root)
        written = []
        if 'deb' in formats:
            written.append(build_deb(bundle, output_dir, version, args.maintainer,
                                     args.homepage, description, root))
        if 'arch' in formats:
            written.append(build_arch(bundle, output_dir, version, args.pkgrel,
                                      args.packager, args.homepage, description,
                                      root, args.compression))
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
    for path in written:
        print(path)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
