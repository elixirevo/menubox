"""Verify release source archives use committed code and exclude local secrets."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sources', Path(__file__).resolve().parents[1] / 'prepare_release_assets.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class SourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.app = base / 'menubox'
        self.library = base / 'tools/library'
        self.output = base / 'output'
        self.output.mkdir()
        for root in (self.app, self.library):
            root.mkdir(parents=True)
            self.git(root, 'init', '-q')
            self.git(root, 'config', 'user.name', 'Test')
            self.git(root, 'config', 'user.email', 'test@example.invalid')
            (root / '.gitignore').write_text('local-secret\n')
            (root / 'LICENSE').write_text('GPL-3.0-only fixture')
            (root / 'code.swift').write_text('committed code')
            (root / 'local-secret').write_text('never publish')
        (self.app / 'Package.resolved').write_text(json.dumps({'pins': []}))
        for root in (self.app, self.library):
            self.git(root, 'add', '.')
            self.git(root, 'commit', '-qm', 'fixture')

    def git(self, root, *args):
        return subprocess.check_output(['git', '-C', str(root), *args])

    def test_contains_both_committed_checkouts_and_build_instructions(self):
        with patch.object(m, 'ROOT', self.app):
            m.package_sources(self.output, '1.5.0')
        with tarfile.open(self.output / 'MenuBox-1.5.0-source.tar.gz') as archive:
            names = archive.getnames()
            self.assertIn('MenuBox-1.5.0-source/menubox/code.swift', names)
            self.assertIn('MenuBox-1.5.0-source/tools/library/LICENSE', names)
            self.assertFalse(any('local-secret' in name or '/.git/' in name for name in names))
            content = archive.extractfile('MenuBox-1.5.0-source/BUILDING.md').read().decode()
            self.assertIn(self.git(self.library, 'rev-parse', 'HEAD').decode().strip(), content)

    def test_uncommitted_dependency_is_rejected(self):
        (self.library / 'code.swift').write_text('uncommitted')
        with patch.object(m, 'ROOT', self.app), self.assertRaisesRegex(RuntimeError, 'Commit'):
            m.package_sources(self.output, '1.5.0')
        self.assertFalse(list(self.output.iterdir()))


if __name__ == '__main__':
    unittest.main()
