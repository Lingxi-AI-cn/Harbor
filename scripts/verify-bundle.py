"""Verify an exact local bundle payload, including unexpected stale files."""
from pathlib import Path
import sys,json,hashlib
bundle=Path(sys.argv[1]); manifest='Contents/BundleManifest.json'
expected=json.loads((bundle/manifest).read_text())
actual={str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file()}
assert actual == set(expected)|{manifest}, 'Bundle file set differs from manifest'
for name,digest in expected.items():
    assert hashlib.sha256((bundle/name).read_bytes()).hexdigest()==digest, 'Bundle file changed: '+name
print('Verified exact bundle payload:',len(expected),'files')
