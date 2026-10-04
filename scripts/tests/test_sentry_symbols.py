"""Offline tests: no real credentials, uploads, signing, or publication."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sentry_symbols as symbols
import validate_release

UUID = 'ee7e133d-a083-3b48-bac4-e45e26a470c9'
OTHER_UUID = '12345678-1234-1234-1234-123456789abc'


class SymbolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'MenuBox.app'
        self.resources = self.app / 'Contents/Resources/MenuBox_MenuBox.bundle/Contents/Resources'
        self.resources.mkdir(parents=True)
        self.config = json.loads(symbols.CONFIG.read_text())
        (self.resources / 'SentryConfiguration.json').write_text(json.dumps(self.config))
        info = dict(CFBundleIdentifier=self.config['appIdentifier'], CFBundleExecutable='MenuBox',
                    CFBundleShortVersionString='1.4.3', CFBundleVersion='146')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        self.symbol = symbols.SymbolFile(self.root / 'test.app.dSYM', UUID, 'arm64')

    def match(self, arch='arm64', version='1.4.3', build=146):
        return symbols.matching_symbols(self.app, self.root, arch, version, build)

    def test_exact_match_selects_version_build_arch_archive(self):
        with patch.object(symbols, 'debug_ids', return_value={(UUID, 'arm64')}):
            result = self.match()
        self.assertEqual(result.uuid, UUID)
        self.assertEqual(result.path.name, 'MenuBox-1.4.3-146-arm64.app.dSYM')

    def test_wrong_uuid_or_architecture_is_rejected(self):
        for actual in ({(OTHER_UUID, 'arm64')}, {(UUID, 'x86_64')}, set()):
            with self.subTest(actual=actual), patch.object(symbols, 'debug_ids', side_effect=[{(UUID, 'arm64')}, actual]):
                with self.assertRaises(symbols.SymbolError):
                    self.match()
        with patch.object(symbols, 'debug_ids', return_value={(UUID, 'x86_64')}):
            with self.assertRaises(symbols.SymbolError):
                self.match()

    def test_wrong_build_or_destination_fails_before_uuid_scan(self):
        with self.assertRaises(symbols.SymbolError):
            self.match(build=147)
        self.config['project'] = 'another-project'
        (self.resources / 'SentryConfiguration.json').write_text(json.dumps(self.config))
        with self.assertRaises(symbols.SymbolError):
            self.match()

    def test_missing_and_empty_dsym_rejected(self):
        with self.assertRaises(symbols.SymbolError):
            symbols.debug_ids(self.root / 'missing')
        self.symbol.path.touch()
        with patch.object(symbols.subprocess, 'run', return_value=Mock(returncode=0, stdout='')):
            with self.assertRaises(symbols.SymbolError):
                symbols.debug_ids(self.symbol.path)

    def test_replaced_symbols_fail_before_credentials_or_upload(self):
        with patch.object(symbols, 'debug_ids', return_value={(OTHER_UUID, 'arm64')}), \
                patch.object(symbols, 'credentials') as auth:
            with self.assertRaises(symbols.SymbolError):
                symbols.upload_symbols([self.symbol])
            auth.assert_not_called()

    def test_ci_token_does_not_require_profile_or_keychain(self):
        setup = symbols.setup_module()
        with patch.object(symbols, 'setup_module', return_value=setup), \
                patch.dict(os.environ, {'SENTRY_AUTH_TOKEN': 'test-secret'}, clear=True), \
                patch.object(setup, 'read_json') as read, patch.object(setup.subprocess, 'run') as keychain:
            client, token, org, project = symbols.credentials(self.config)
            self.assertEqual(token, 'test-secret')
            self.assertEqual(client.base, 'https://sentry.io/api/0/')
            self.assertEqual((org, project), ('elixirevo', 'menubox'))
            read.assert_not_called()
            keychain.assert_not_called()

    def test_keychain_profile_reused_and_wrong_org_rejected(self):
        setup = symbols.setup_module()
        profile = dict(schemaVersion=1, apiBase='https://sentry.io/api/0/', organization='elixirevo',
                       team='team', keychainService='service', keychainAccount='account')
        with patch.object(symbols, 'setup_module', return_value=setup), patch.dict(os.environ, {}, clear=True), \
                patch.object(setup, 'read_json', return_value=profile), \
                patch.object(setup, 'token_from_keychain', return_value='keychain-secret') as keychain:
            self.assertEqual(symbols.credentials(self.config)[1], 'keychain-secret')
            keychain.assert_called_once_with('service', 'account')
            profile['organization'] = 'wrong'
            with self.assertRaises(symbols.SymbolError):
                symbols.credentials(self.config)

    def test_upload_waits_and_confirms_both_architectures_without_exposing_token(self):
        second = symbols.SymbolFile(self.root / 'intel.app.dSYM', OTHER_UUID, 'x86_64')
        client = Mock(base='https://sentry.io/api/0/')
        client.get.side_effect = [[dict(uuid=s.uuid.upper(), cpuName=s.arch, data={'features': ['debug']})]
                                  for s in (self.symbol, second)]
        with patch.object(symbols, 'debug_ids', side_effect=[{(UUID, 'arm64')}, {(OTHER_UUID, 'x86_64')}]), \
                patch.object(symbols.shutil, 'which', return_value='/test/sentry-cli'), \
                patch.object(symbols, 'credentials', return_value=(client, 'test-secret', 'org', 'project')), \
                patch.object(symbols.subprocess, 'run', return_value=Mock(returncode=0)) as run, \
                patch.dict(os.environ, {'SENTRY_ALLOW_FAILURE': '1', 'SENTRY_LOG_LEVEL': 'debug'}):
            symbols.upload_symbols([self.symbol, second])
        command = run.call_args.args[0]
        self.assertNotIn('test-secret', command)
        self.assertIn('--wait-for', command)
        self.assertIn(OTHER_UUID, command)
        self.assertEqual(run.call_args.kwargs['env']['SENTRY_AUTH_TOKEN'], 'test-secret')
        self.assertNotIn('SENTRY_ALLOW_FAILURE', run.call_args.kwargs['env'])
        self.assertNotIn('SENTRY_LOG_LEVEL', run.call_args.kwargs['env'])
        self.assertEqual(client.get.call_count, 2)

    def test_cli_failure_or_missing_remote_debug_info_blocks_success(self):
        for exit_code, rows in ((1, []), (0, []),
                                (0, [dict(uuid=UUID, cpuName='arm64', data={'features': ['symtab']})])):
            client = Mock(base='https://sentry.io/api/0/')
            client.get.return_value = rows
            with self.subTest(exit_code=exit_code, rows=rows), \
                    patch.object(symbols, 'debug_ids', return_value={(UUID, 'arm64')}), \
                    patch.object(symbols.shutil, 'which', return_value='/test/sentry-cli'), \
                    patch.object(symbols, 'credentials', return_value=(client, 'secret', 'org', 'project')), \
                    patch.object(symbols.subprocess, 'run', return_value=Mock(returncode=exit_code, stderr='secret')):
                with self.assertRaises(symbols.SymbolError) as caught:
                    symbols.upload_symbols([self.symbol])
                self.assertNotIn('secret', str(caught.exception))
                if exit_code:
                    client.get.assert_not_called()

    def test_dmg_is_detached_even_when_symbol_validation_fails(self):
        # validate_bundle must inspect the mounted distribution app and always detach.
        expected = plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())
        for key in ('CFBundleName', 'SUFeedURL', 'SUPublicEDKey', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
            expected[key] = 'value'
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(expected))
        mount = plistlib.dumps({'system-entities': [{'mount-point': str(self.root)}]})
        with patch.object(validate_release.subprocess, 'check_output', side_effect=[mount, 'arm64']), \
                patch.object(validate_release.subprocess, 'run') as run, \
                patch.object(validate_release, 'matching_symbols', side_effect=symbols.SymbolError('mismatch')) as match:
            with self.assertRaises(symbols.SymbolError):
                validate_release.validate_bundle(self.root / 'test.dmg', 'arm64', 146, expected)
            self.assertEqual(match.call_args.args[0], self.app)
            self.assertEqual(run.call_args.args[0], ['hdiutil', 'detach', str(self.root)])


class ReleaseShellTests(unittest.TestCase):
    def test_symbol_gate_failure_stops_prepare_reuse_and_publish(self):
        for phase in ('prepare', 'publish'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in ('scripts', 'Resources', 'dist', 'tap/Casks', 'homebrew/Casks',
                             '.build/artifacts/sparkle/Sparkle/bin', 'bin'):
                    (root / name).mkdir(parents=True)
                shutil.copy(symbols.ROOT / 'scripts/release.sh', root / 'scripts/release.sh')
                (root / 'Resources/Info.plist').write_bytes(plistlib.dumps({'SUPublicEDKey': 'key'}))
                (root / 'notes.md').write_text('notes')
                (root / 'tap/Casks/menubox.rb').touch()
                (root / 'homebrew/Casks/menubox.rb').touch()
                for arch in ('arm64', 'x86_64'):
                    (root / f'dist/MenuBox-1.4.3-{arch}.dmg').write_text('fake DMG')
                (root / 'scripts/generate_appcast.sh').write_text('exit 0\n')
                (root / 'scripts/update_cask.py').write_text('pass\n')
                (root / 'scripts/validate_release.py').write_text(
                    "import sys\nfrom pathlib import Path\n"
                    "assert '--upload-symbols' in sys.argv\n"
                    "Path('gate-called').touch()\nsys.exit(17)\n")
                for name in ('xcrun', 'codesign', 'spctl', 'git', 'gh'):
                    path = root / 'bin' / name
                    path.write_text('#!/bin/sh\n' + ('touch forbidden-publication\n' if name in ('git', 'gh') else '') + 'exit 0\n')
                    path.chmod(0o755)
                key = root / '.build/artifacts/sparkle/Sparkle/bin/generate_keys'
                key.write_text('#!/bin/sh\necho key\n')
                key.chmod(0o755)
                env = dict(os.environ, APP_VERSION='1.4.3', APP_BUILD_X86_64='146', APP_BUILD_ARM64='147',
                           RELEASE_PHASE=phase, SKIP_BUILD='1', SIGN_IDENTITY='Developer ID Application: Test',
                           RELEASE_NOTES_FILE=str(root / 'notes.md'), HOMEBREW_TAP_DIR=str(root / 'tap'),
                           DIST_DIR=str(root / 'dist'), PATH=str(root / 'bin') + ':' + os.environ['PATH'])
                result = subprocess.run(['bash', 'scripts/release.sh'], cwd=root, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
                self.assertTrue((root / 'gate-called').exists())
                self.assertFalse((root / 'forbidden-publication').exists())


if __name__ == '__main__':
    unittest.main()
