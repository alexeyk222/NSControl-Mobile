"""Public CLI packaging checks with real temporary repositories and archives."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'tools/package_release.py'


class PackageReleaseTest(unittest.TestCase):
    def build(self, root, output):
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(root), '--output', str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_allowlist_excludes_secrets_and_tooling_but_includes_final_documents_and_release_apk(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'repo'
            root.mkdir()
            allowed = {
                'README.md': b'NSControl',
                'pubspec.yaml': b'name: nscontrol',
                'pubspec.lock': b'packages: {}',
                'lib/main.dart': b'void main() {}',
                'docs/acceptance.md': 'Приёмка'.encode(),
                'android/app/build.gradle.kts': b'android {}',
                'ios/Runner/Info.plist': b'<plist/>',
                'Итоговые документы/ТЗ_NSControl_редакция_2_3.docx': b'final doc',
                'build/app/outputs/flutter-apk/app-release.apk': b'release binary',
            }
            excluded = [
                '.tooling/flutter/secret', '.git/config', '.codex-doc-review/report.md',
                'build/intermediates/token', 'build/app/outputs/flutter-apk/app-debug.apk',
                'android/local.properties', 'android/key.properties', 'android/app/release.jks',
                'android/nscontrol_android.iml', 'android/project.ipr', 'android/workspace.iws',
                'android/app/signing.keystore', 'ios/key.p12', 'ios/Profile.mobileprovision',
                'garmin/developer_key.der', 'garmin/developer_key.txt', 'garmin/bin/app.prg',
                'ios/Flutter/Generated.xcconfig', 'ios/Flutter/flutter_export_environment.sh',
                'ios/key.p8', 'android/secrets.json', 'Итоговые документы/~$ТЗ.docx',
                'ios/Runner/.env', 'lib/.env.production', 'docs/.secret',
                'test_tools/__pycache__/test.pyc', 'ios/Runner.xcodeproj/xcuserdata/user.xcuserstate',
                'ПЗ.docx', 'Редакция_2026-10-15/draft.docx', 'random.txt',
            ]
            for relative, data in allowed.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            for relative in excluded:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'NEVER DISTRIBUTE')
            output = Path(temp) / 'release.zip'
            self.build(root, output)
            with zipfile.ZipFile(output) as archive:
                names = set(archive.namelist())
                expected = set(allowed) - {'build/app/outputs/flutter-apk/app-release.apk'}
                expected.add('artifacts/app-release.apk')
                self.assertEqual(names, expected | {'MANIFEST.json', 'SHA256SUMS'})
                for name in names:
                    self.assertNotIn(b'NEVER DISTRIBUTE', archive.read(name))
                manifest = json.loads(archive.read('MANIFEST.json'))
                checksums = dict(line.split('  ', 1)[::-1] for line in archive.read('SHA256SUMS').decode().splitlines())
                for item in manifest['files']:
                    data = archive.read(item['path'])
                    self.assertEqual(item['sha256'], hashlib.sha256(data).hexdigest())
                    self.assertEqual(item['bytes'], len(data))
                    self.assertEqual(checksums[item['path']], item['sha256'])
                self.assertEqual(checksums['MANIFEST.json'], hashlib.sha256(archive.read('MANIFEST.json')).hexdigest())
                self.assertEqual(manifest['artifacts']['android_release_apk'], 'artifacts/app-release.apk')

    def test_archive_is_byte_reproducible_and_symlinks_never_escape_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'repo'
            (root / 'lib').mkdir(parents=True)
            (root / 'README.md').write_text('source only')
            (root / 'pubspec.yaml').write_text('name: nscontrol')
            (root / 'lib/main.dart').write_text('main() {}')
            outside = Path(temp) / 'private.key'
            outside.write_text('private')
            (root / 'lib/linked.dart').symlink_to(outside)
            (root / 'lib/nested').symlink_to(Path(temp), target_is_directory=True)
            first, second = Path(temp) / 'one.zip', Path(temp) / 'two.zip'
            self.build(root, first)
            self.build(root, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with zipfile.ZipFile(first) as archive:
                self.assertNotIn('lib/linked.dart', archive.namelist())
                manifest = json.loads(archive.read('MANIFEST.json'))
                self.assertIsNone(manifest['artifacts']['android_release_apk'])
                self.assertEqual(manifest['physical_acceptance'], 'not_claimed')

    def test_output_inside_allowed_tree_is_rejected_without_replacing_existing_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'tools').mkdir()
            (root / 'README.md').write_text('source')
            (root / 'pubspec.yaml').write_text('name: nscontrol')
            destination = root / 'tools/source.zip'
            destination.write_text('keep me')
            result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(root), '--output', str(destination)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(destination.read_text(), 'keep me')
            self.assertIn('output must be outside packaged source directories', result.stderr)


if __name__ == '__main__':
    unittest.main()
