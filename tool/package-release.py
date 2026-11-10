"""Stage release assets with predictable names; keep reports and caches private."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import zipfile


def version_of(root):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+\+[1-9]\d*)\s*$',
                      (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    if not match:
        raise ValueError('Invalid project version')
    return match.group(1)


def stage(root, platform, installer=None, architecture='x64'):
    if platform not in {'android', 'linux', 'windows', 'macos'} or architecture not in {'x64', 'arm64'}:
        raise ValueError('Unsupported release platform or architecture')
    root = Path(root).resolve()
    version = version_of(root)
    output = root / '.local/release-assets'
    output.mkdir(parents=True, exist_ok=True)
    if platform == 'android':
        source = root / 'build/app/outputs/flutter-apk/app-release.apk'
        destination = output / ('asterlink-' + version + '-android-arm64.apk')
        if not source.is_file() or destination.exists():
            raise ValueError('APK is missing or a staged asset already exists')
        shutil.copy2(source, destination)
    elif platform == 'linux':
        runtime = root / 'build/linux/x64/release/bundle'
        # Flutter's Linux bundle keeps the AOT library in lib/ (Windows uses
        # data/app.so), so check the paths that the runner expects at startup.
        for name in ('asterlink', 'asterlink_gopeed', 'lib/libapp.so', 'lib/libflutter_linux_gtk.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin'):
            if not (runtime / name).is_file():
                raise ValueError('Linux bundle is incomplete')
        files = sorted(p for p in runtime.rglob('*') if p.is_file())
        for path in files:
            relative = path.relative_to(runtime)
            if path.is_symlink() or runtime.resolve() not in path.resolve().parents:
                raise ValueError('Linux bundle contains a link')
            # Executables must stay executable after extraction; the archive
            # format keeps the mode bits, so only reject private files here.
            if any(part in {'.local', '.git', 'logs', 'diagnostics'} for part in relative.parts) or path.suffix in {'.jks', '.keystore', '.p12', '.pfx', '.log', '.pdb'}:
                raise ValueError('Linux bundle contains private or development files')
        # A zip archive does not carry the Unix mode, so extracting it would
        # drop the executable bit from asterlink and asterlink_gopeed. tar.gz
        # keeps the permissions of the bundle as built.
        destination = output / ('asterlink-' + version + '-linux-x64.tar.gz')
        if destination.exists():
            raise ValueError('A staged Linux asset already exists')
        with tarfile.open(destination, 'x:gz') as archive:
            for path in files:
                info = archive.gettarinfo(str(path), path.relative_to(runtime).as_posix())
                info.uid = info.gid = 0
                info.uname = info.gname = ''
                with path.open('rb') as stream:
                    archive.addfile(info, stream)
    elif platform == 'windows':
        runtime = root / ('build/windows/' + architecture + '/runner/Release')
        for name in ('asterlink.exe', 'asterlink_gopeed.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so'):
            if not (runtime / name).is_file():
                raise ValueError('Windows runtime is incomplete')
        files = sorted(p for p in runtime.rglob('*') if p.is_file())
        for path in files:
            relative = path.relative_to(runtime)
            if re.match(r'(?i)^(fvp|mdk(?:-(?:braw|r3d))?|ffmpeg-9|libass)\.dll$', path.name):
                raise ValueError('Windows runtime contains a removed player library')
            if path.is_symlink() or runtime.resolve() not in path.resolve().parents:
                raise ValueError('Windows runtime contains a link')
            if any(part in {'.local', '.git', 'logs', 'diagnostics'} for part in relative.parts) or path.suffix in {'.jks', '.keystore', '.p12', '.pfx', '.log', '.pdb'}:
                raise ValueError('Windows runtime contains private or development files')
        destination = output / ('asterlink-' + version + '-windows-' + architecture + '.zip')
        if destination.exists():
            raise ValueError('A staged Windows asset already exists')
        with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                archive.write(path, path.relative_to(runtime).as_posix())
        if installer:
            source = Path(installer).resolve()
            if not source.is_file() or source.suffix.lower() != '.exe':
                raise ValueError('Installer must be an existing EXE')
            target = output / ('asterlink-' + version + '-windows-' + architecture + '-setup.exe')
            if target.exists():
                raise ValueError('A staged installer already exists')
            shutil.copy2(source, target)
    elif platform == 'macos':
        # Flutter's macOS bundle is a .app directory named after the Xcode
        # PRODUCT_NAME (文析助手). AsterLink keeps both the app executable and
        # the download helper in Contents/MacOS, so check the paths the Dart
        # runtime resolves at startup (desktopHelperName).
        app = root / 'build/macos/Build/Products/Release/文析助手.app'
        contents = app / 'Contents'
        required = (
            ('Contents/MacOS/文析助手', app / 'Contents/MacOS/文析助手'),
            ('Contents/MacOS/asterlink_gopeed', app / 'Contents/MacOS/asterlink_gopeed'),
            ('Contents/Info.plist', contents / 'Info.plist'),
            ('Contents/Frameworks/App.framework/App', contents / 'Frameworks/App.framework/App'),
            (
                'Contents/Frameworks/App.framework/Resources/flutter_assets/AssetManifest.bin',
                contents / 'Frameworks/App.framework/Resources/flutter_assets/AssetManifest.bin',
            ),
        )
        for name, path in required:
            if not path.is_file():
                raise ValueError('macOS bundle is incomplete: missing ' + name)
        # `ditto -c -k` keeps the executable bit and symlinks intact, which a
        # plain zip would drop; the .app must stay a directory tree on extract.
        destination = output / ('asterlink-' + version + '-macos-arm64.zip')
        if destination.exists():
            raise ValueError('A staged macOS asset already exists')
        subprocess.run(
            ['ditto', '-c', '-k', '--keepParent', str(app), str(destination)],
            check=True,
        )
    return output


def checksums(directory):
    directory = Path(directory)
    files = sorted(p for p in directory.iterdir() if p.is_file() and p.name != 'SHA256SUMS.txt')
    if not files:
        raise ValueError('No release assets were found')
    records = []
    for path in files:
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        records.append(digest.hexdigest() + '  ' + path.name)
    (directory / 'SHA256SUMS.txt').write_text('\n'.join(records) + '\n', encoding='utf-8')
    return len(files)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('android', 'windows', 'linux', 'macos'))
    parser.add_argument('--installer')
    parser.add_argument('--architecture', choices=('x64', 'arm64'), default='x64')
    parser.add_argument('--checksums', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        if args.platform:
            stage(root, args.platform, args.installer, args.architecture)
            print('Release assets staged for ' + args.platform)
        if args.checksums:
            print('SHA-256 written for {} assets'.format(checksums(root / '.local/release-assets')))
        if not args.platform and not args.checksums:
            raise ValueError('Choose --platform or --checksums')
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
