import argparse
import hashlib
import os
import pathlib
import plistlib
import pwd
import re
import stat
import subprocess
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent
ARCHIVE_DATE = (1980, 1, 1, 0, 0, 0)


def check_content(data, name):
    account = pwd.getpwuid(os.getuid()).pw_name
    markers = [str(ROOT), str(pathlib.Path.home())]
    for marker in markers:
        for encoding in ['utf-8', 'utf-16le', 'utf-16be']:
            if marker.encode(encoding) in data:
                raise ValueError('Local filesystem path found in: ' + name)
    for encoding in ['utf-8', 'utf-16le', 'utf-16be']:
        text = data.decode(encoding, errors='ignore')
        if re.search(r'/(?:Users|home)/[^\s\x00/]+/', text):
            raise ValueError('User directory found in: ' + name)
        if account.lower() not in {'root', 'user', 'admin', 'administrator', 'guest', 'test'} and re.search(r'(?<![\w])' + re.escape(account) + r'(?![\w])', text, re.I):
            raise ValueError('Local account name found in: ' + name)


def package(application, output):
    application = application.resolve(strict=True)
    metadata = plistlib.loads((application / 'Contents/Info.plist').read_bytes())
    if metadata.get('CFBundleIdentifier') != 'local.chromeconsent.app':
        raise ValueError('Unexpected application identifier')
    version = metadata.get('CFBundleShortVersionString', '')
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid release version')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(application)], check=True)
    prefix = pathlib.PurePosixPath('Chrome Consent ' + version)
    entries = []
    for path in sorted(application.rglob('*')):
        relative = path.relative_to(application)
        if any(part in ['.DS_Store', '__MACOSX'] or part.startswith('._') for part in relative.parts):
            continue
        if path.is_symlink():
            raise ValueError('Application contains a symbolic link: ' + relative.as_posix())
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError('Unexpected application entry: ' + relative.as_posix())
        mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
        entries.append((path, prefix / 'Chrome Consent.app' / relative.as_posix(), mode))
    entries.append((ROOT / 'RELEASE.md', prefix / 'README.md', 0o644))
    output.mkdir(parents=True, exist_ok=True)
    destination = output / ('Chrome-Consent-' + version + '.zip')
    checksum = destination.with_suffix('.sha256')
    descriptor, name = tempfile.mkstemp(prefix='.package-', suffix='.zip', dir=output)
    os.close(descriptor)
    temporary = pathlib.Path(name)
    checksum_temporary = temporary.with_suffix('.sha256')
    try:
        expected = {}
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path, relative, mode in entries:
                data = path.read_bytes()
                check_content(relative.as_posix().encode(), relative.as_posix())
                check_content(data, relative.as_posix())
                info = zipfile.ZipInfo(relative.as_posix(), date_time=ARCHIVE_DATE)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                info.extra = b''
                info.comment = b''
                archive.writestr(info, data, compresslevel=9)
                expected[info.filename] = hashlib.sha256(data).hexdigest()
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None or archive.comment:
                raise ValueError('Archive integrity check failed')
            for info in archive.infolist():
                if info.extra or info.comment or info.date_time != ARCHIVE_DATE:
                    raise ValueError('Unexpected archive metadata: ' + info.filename)
                if hashlib.sha256(archive.read(info)).hexdigest() != expected[info.filename]:
                    raise ValueError('Archive content verification failed: ' + info.filename)
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        checksum_temporary.write_text(digest + '  ' + destination.name + '\n')
        os.replace(temporary, destination)
        os.replace(checksum_temporary, checksum)
        subprocess.run(['/usr/bin/xattr', '-c', str(destination), str(checksum)], check=True)
    finally:
        temporary.unlink(missing_ok=True)
        checksum_temporary.unlink(missing_ok=True)
    print('Created: ' + destination.name)
    print('SHA-256: ' + digest)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=pathlib.Path, default=ROOT / 'build/Chrome Consent.app')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'outputs')
    args = parser.parse_args()
    package(args.app, args.output)


if __name__ == '__main__':
    main()
