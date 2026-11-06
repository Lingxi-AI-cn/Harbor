"""Offline rejection-policy tests; no keychain, private keys, or Apple submission."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('packager', ROOT / 'scripts/create-notarization-dmg.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
IDENTITY = 'A' * 40
DETAILS = '''Authority=Developer ID Application: Example (ABCDEFGHIJ)
Timestamp=Nov 6, 2026 at 16:00:00
TeamIdentifier=ABCDEFGHIJ
CodeDirectory v=20500 flags=0x10000(runtime)
'''


class PackagingPolicy(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS codesign')
    def test_requirement_is_parsed_as_literal(self):
        # Capture the actual verifier command before certificate extraction.
        with patch.object(p, 'run', side_effect=RuntimeError('stop')) as command:
            with self.assertRaisesRegex(RuntimeError, 'stop'):
                p.verify_signature(Path('/bin/ls'), IDENTITY, Path('/unused'))
        argv = command.call_args.args[0]
        requirement = argv[argv.index('-R') + 1]
        # Compile the exact argument with Apple's requirement compiler. This
        # avoids relying on system executable trust or using a private key.
        with tempfile.TemporaryDirectory() as work:
            binary = Path(work) / 'requirement.bin'
            result = subprocess.run(['/usr/bin/csreq', '-r', requirement, '-b', str(binary)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertGreater(binary.stat().st_size, 0)

    def test_identity_selection(self):
        p.validate_identity(IDENTITY, f'1) {IDENTITY} "Developer ID Application: Example (ABCDEFGHIJ)"')
        for kind in ('Apple Development', 'Developer ID Installer', 'Apple Distribution'):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                p.validate_identity(IDENTITY, f'1) {IDENTITY} "{kind}: Example"')
        with self.assertRaises(ValueError):
            p.validate_identity(IDENTITY, '0 valid identities found')
        with self.assertRaises(ValueError):
            p.validate_identity('-', '')

    def test_timestamp_and_runtime(self):
        self.assertEqual(p.validate_details(DETAILS, True), 'ABCDEFGHIJ')
        for details in (DETAILS.replace('Timestamp=', 'Signed Time='),
                        DETAILS.replace('0x10000(runtime)', '0x0(none)'),
                        DETAILS.replace('Developer ID Application:', 'Apple Development:'),
                        DETAILS.replace('TeamIdentifier=ABCDEFGHIJ', 'TeamIdentifier=not set')):
            with self.subTest(details=details), self.assertRaises(ValueError):
                p.validate_details(details, True)
        p.validate_details(DETAILS.replace('0x10000(runtime)', '0x0(none)'), False)

    def test_unexpected_code_and_symlinks(self):
        with tempfile.TemporaryDirectory() as work:
            app = Path(work) / 'Harbor.app'
            code = app / 'Contents/MacOS'
            code.mkdir(parents=True)
            for name in ('Harbor', 'harbor-desktop-engine'):
                (code / name).write_bytes(bytes.fromhex('cffaedfe') + b'fixture')
            self.assertEqual(p.code_paths(app), [code / 'harbor-desktop-engine'])
            extra = app / 'Contents/extra'
            extra.write_bytes(bytes.fromhex('cffaedfe'))
            with self.assertRaises(ValueError):
                p.code_paths(app)
            extra.unlink()
            extra.symlink_to(code / 'Harbor')
            with self.assertRaises(ValueError):
                p.code_paths(app)

    def test_changed_input_rejected_before_tools(self):
        with tempfile.TemporaryDirectory() as work:
            app = Path(work)
            (app / 'Contents').mkdir()
            p.write_json(app / 'Contents/BundleManifest.json', {'Contents/missing': 'bad'})
            with self.assertRaisesRegex(ValueError, 'exact manifest'):
                p.validate_input(app)

    def test_existing_output_preserved(self):
        with tempfile.TemporaryDirectory() as work:
            output = Path(work)
            sentinel = output / 'keep'
            sentinel.write_text('unchanged')
            with self.assertRaisesRegex(ValueError, 'Destination exists'):
                p.build(output / 'missing.app', output, IDENTITY, 'unused')
            self.assertEqual(sentinel.read_text(), 'unchanged')


unittest.main()
