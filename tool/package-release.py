"""Stage release assets with predictable names; keep reports and caches private."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import tarfile
import zipfile


def version_of(root):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+\+[1-9]\d*)\s*$',
                      (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    if not match:
        raise ValueError('Invalid project version')
    return match.group(1)


def stage(root, platform, installer=None):
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
    else:
        runtime = root / 'build/windows/x64/runner/Release'
        for name in ('asterlink.exe', 'asterlink_gopeed.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so'):
            if not (runtime / name).is_file():
                raise ValueError('Windows runtime is incomplete')
        files = sorted(p for p in runtime.rglob('*') if p.is_file())
        for path in files:
            relative = path.relative_to(runtime)
            if path.is_symlink() or runtime.resolve() not in path.resolve().parents:
                raise ValueError('Windows runtime contains a link')
            if any(part in {'.local', '.git', 'logs', 'diagnostics'} for part in relative.parts) or path.suffix in {'.jks', '.keystore', '.p12', '.pfx', '.log', '.pdb'}:
                raise ValueError('Windows runtime contains private or development files')
        destination = output / ('asterlink-' + version + '-windows-x64.zip')
        if destination.exists():
            raise ValueError('A staged Windows asset already exists')
        with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                archive.write(path, path.relative_to(runtime).as_posix())
        if installer:
            source = Path(installer).resolve()
            if not source.is_file() or source.suffix.lower() != '.exe':
                raise ValueError('Installer must be an existing EXE')
            target = output / ('asterlink-' + version + '-windows-x64-setup.exe')
            if target.exists():
                raise ValueError('A staged installer already exists')
            shutil.copy2(source, target)
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
    parser.add_argument('--platform', choices=('android', 'windows', 'linux'))
    parser.add_argument('--installer')
    parser.add_argument('--checksums', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        if args.platform:
            stage(root, args.platform, args.installer)
            print('Release assets staged for ' + args.platform)
        if args.checksums:
            print('SHA-256 written for {} assets'.format(checksums(root / '.local/release-assets')))
        if not args.platform and not args.checksums:
            raise ValueError('Choose --platform or --checksums')
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
