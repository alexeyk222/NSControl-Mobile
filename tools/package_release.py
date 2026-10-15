#!/usr/bin/env python3
"""Create a deterministic NSControl source bundle with SHA-256 manifest.

The bundle is an allowlisted source delivery, not evidence of physical acceptance.
A release APK is included only if the known release output exists (or --apk is
explicitly supplied). No debug APKs, SDK caches, signing material or symlinks.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import zipfile

SOURCE_DIRECTORIES = frozenset({
    'lib', 'test', 'test_tools', 'tools', 'android', 'ios', 'watchos', 'garmin',
    'docs', '.github', 'Итоговые документы',
})
ROOT_FILES = frozenset({
    'README.md', 'LICENSE', 'LICENSE.md', 'NOTICE', 'pubspec.yaml', 'pubspec.lock',
    'analysis_options.yaml', '.metadata', '.gitignore', '.flutter-version',
})
EXCLUDED_PARTS = frozenset({
    '.git', '.tooling', '.codex', '.codex-doc-review', '.agents', '.gradle', '.kotlin', '.cxx',
    '.dart_tool', '.idea', '.swiftpm', '.build', '.symlinks', '__pycache__',
    'node_modules', 'build', 'bin', 'deriveddata', 'xcuserdata', 'pods', 'ephemeral',
})
EXCLUDED_NAMES = frozenset({
    'local.properties', 'key.properties', 'gradle.properties.local',
    'google-services.json', 'googleservice-info.plist', '.ds_store',
    'generated.xcconfig', 'flutter_export_environment.sh', 'secrets.json',
    'secrets.yaml', 'secrets.yml', 'credentials.json', 'service-account.json',
    'signing.properties',
})
SECRET_SUFFIXES = frozenset({
    '.jks', '.keystore', '.p12', '.pfx', '.pem', '.key', '.mobileprovision',
    '.der', '.p8', '.p7b', '.p7c', '.keychain', '.keychain-db',
    '.provisionprofile', '.cer', '.crt', '.pyc', '.pyo', '.xcuserstate',
    '.iml', '.ipr', '.iws',
})
ZIP_TIME = (1980, 1, 1, 0, 0, 0)


def permitted(relative: Path) -> bool:
    parts = relative.parts
    if not parts:
        return False
    if len(parts) == 1:
        return relative.name in ROOT_FILES
    if parts[0] not in SOURCE_DIRECTORIES:
        return False
    lowered = [part.lower() for part in parts]
    if any(part in EXCLUDED_PARTS for part in lowered):
        return False
    if any(part.startswith('.') or part.startswith('~$') or part.lower().startswith('developer_key') for part in parts[1:]):
        return False
    if relative.name.lower() in EXCLUDED_NAMES or relative.suffix.lower() in SECRET_SUFFIXES:
        return False
    if any(part.lower().startswith('.env') for part in parts):
        return False
    if parts[0] == 'Итоговые документы' and relative.suffix.lower() not in {'.docx', '.pdf'}:
        return False
    return True


def selected_files(root: Path):
    for directory, child_dirs, names in os.walk(root, followlinks=False):
        current = Path(directory)
        relative = current.relative_to(root)
        if current == root:
            child_dirs[:] = sorted(name for name in child_dirs if name in SOURCE_DIRECTORIES and not (current / name).is_symlink())
        else:
            child_dirs[:] = sorted(name for name in child_dirs
                                   if name.lower() not in EXCLUDED_PARTS
                                   and not name.startswith('.')
                                   and not (current / name).is_symlink())
        for name in sorted(names):
            path = current / name
            if not path.is_symlink() and path.is_file() and permitted(relative / name):
                yield path


def _zip_entry(name: str, data: bytes):
    info = zipfile.ZipInfo(name, date_time=ZIP_TIME)
    info.create_system = 3
    executable = name.endswith('.sh') or Path(name).name in {'gradlew'}
    info.external_attr = (0o100755 if executable else 0o100644) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    return info, data


def package(root: Path, output: Path, *, apk: Path | None = None):
    root = root.resolve(strict=True)
    output = output.resolve()
    if not root.is_dir() or not (root / 'pubspec.yaml').is_file():
        raise ValueError('root must contain pubspec.yaml')
    try:
        relative_output = output.relative_to(root)
    except ValueError:
        relative_output = None
    if relative_output is not None and (relative_output.parts[0] in SOURCE_DIRECTORIES or relative_output.name in ROOT_FILES):
        raise ValueError('output must be outside packaged source directories')
    if output.exists():
        raise ValueError('output already exists; choose a new path')
    files = {path.relative_to(root).as_posix(): path.read_bytes() for path in selected_files(root)}
    candidate = apk if apk is not None else root / 'build/app/outputs/flutter-apk/app-release.apk'
    if apk is not None and not candidate.is_file():
        raise ValueError('explicit release APK does not exist')
    packaged_apk = None
    if candidate.is_file() and candidate.resolve() == candidate.absolute():
        if candidate.suffix.lower() != '.apk' or 'debug' in candidate.name.lower():
            raise ValueError('only a release APK may be included')
        packaged_apk = 'artifacts/app-release.apk'
        files[packaged_apk] = candidate.read_bytes()
    manifest = {
        'schema_version': 1,
        'release': 'NSControl 1.0',
        'physical_acceptance': 'not_claimed',
        'artifacts': {'android_release_apk': packaged_apk},
        'files': [
            {'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            for name, data in sorted(files.items())
        ],
    }
    files['MANIFEST.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode('utf-8')
    files['SHA256SUMS'] = ''.join(
        f'{hashlib.sha256(data).hexdigest()}  {name}\n' for name, data in sorted(files.items())
    ).encode('utf-8')
    output.parent.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.nscontrol-package-', suffix='.zip', dir=output.parent, delete=False) as temporary:
            temp_name = Path(temporary.name)
        with zipfile.ZipFile(temp_name, mode='w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, data in sorted(files.items()):
                info, payload = _zip_entry(name, data)
                archive.writestr(info, payload, compresslevel=9)
        # Exclusive link prevents replacing a file created after the first check.
        os.link(temp_name, output)
    finally:
        if temp_name is not None:
            temp_name.unlink(missing_ok=True)
    return {
        'path': str(output), 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
        'files': len(files), 'android_release_apk': packaged_apk,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--apk', type=Path)
    args = parser.parse_args(argv)
    try:
        result = package(args.root, args.output, apk=args.apk)
    except (OSError, ValueError) as error:
        parser.exit(2, f'packaging failed: {error}\n')
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == '__main__':
    main()
