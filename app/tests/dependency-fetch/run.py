"""Exercise dependency initialization with local Git sources; no network required."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[3] / 'scripts/fetch-dependencies.sh'


class DependencyFetch(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.origin = self.root / 'upstream'
        self.git('init', str(self.origin))
        (self.origin / 'source.txt').write_text('upstream fixture\n')
        self.git('-C', str(self.origin), 'add', '.')
        self.git('-C', str(self.origin), '-c', 'user.name=Fixture', '-c',
                 'user.email=fixture@example.invalid', 'commit', '-m', 'Fixture')
        self.commit = self.git('-C', str(self.origin), 'rev-parse', 'HEAD').strip()
        self.project = self.root / 'project'
        (self.project / 'scripts').mkdir(parents=True)
        shutil.copy2(SCRIPT, self.project / 'scripts/fetch-dependencies.sh')
        (self.project / 'DEPENDENCIES.json').write_text(json.dumps([
            {'path': 'vendor/dependency', 'url': str(self.origin), 'commit': self.commit}]))
        self.dependency = self.project / 'vendor/dependency'

    def git(self, *args):
        return subprocess.check_output(['git', *args], text=True, stderr=subprocess.DEVNULL)

    def fetch(self):
        return subprocess.run(['bash', 'scripts/fetch-dependencies.sh'], cwd=self.project,
                              text=True, capture_output=True, timeout=20)

    def verify_checkout(self):
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('-C', str(self.dependency), 'rev-parse', 'HEAD').strip(), self.commit)
        self.assertEqual((self.dependency / 'source.txt').read_text(), 'upstream fixture\n')

    def test_missing_directory_and_repeat(self):
        self.verify_checkout()
        self.verify_checkout()

    def test_fresh_clone_empty_gitlink_directory(self):
        self.git('init', str(self.project))
        (self.project / '.gitmodules').write_text(
            '[submodule "dependency"]\n\tpath = vendor/dependency\n\turl = ' + str(self.origin) + '\n')
        self.git('-C', str(self.project), 'add', '.')
        self.git('-C', str(self.project), 'update-index', '--add', '--cacheinfo',
                 '160000,' + self.commit + ',vendor/dependency')
        self.git('-C', str(self.project), '-c', 'user.name=Fixture', '-c',
                 'user.email=fixture@example.invalid', 'commit', '-m', 'Fixture')
        clone = self.root / 'clone'
        self.git('clone', '--no-hardlinks', str(self.project), str(clone))
        self.project = clone
        self.dependency = clone / 'vendor/dependency'
        self.assertTrue(self.dependency.is_dir())
        self.assertEqual(list(self.dependency.iterdir()), [])
        self.verify_checkout()

    def test_nonempty_directory_preserved(self):
        self.dependency.mkdir(parents=True)
        sentinel = self.dependency / 'user.txt'
        sentinel.write_text('preserve me')
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a Git checkout or empty directory', result.stderr)
        self.assertEqual(sentinel.read_text(), 'preserve me')
        self.assertFalse((self.dependency / '.git').exists())

    def test_dirty_checkout_rejected(self):
        self.verify_checkout()
        (self.dependency / 'source.txt').write_text('local changes')
        self.assertNotEqual(self.fetch().returncode, 0)
        self.assertEqual((self.dependency / 'source.txt').read_text(), 'local changes')


if __name__ == '__main__':
    unittest.main()
