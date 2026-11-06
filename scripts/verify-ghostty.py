"""Validate the pinned engine revision and exact local patch before linking."""
from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1]
lock=json.loads((root/'vendor/ghostty.lock.json').read_text())
source=root/'vendor/ghostty'
revision=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
assert revision==lock['commit'], 'Ghostty revision mismatch'
expected=b''
for patch in lock.get('patches',[]):
    data=(root/'vendor'/patch['file']).read_bytes()
    assert hashlib.sha256(data).hexdigest()==patch['sha256'], 'Ghostty patch checksum mismatch'
    expected+=data
actual=subprocess.check_output(['git','-C',str(source),'diff','HEAD','--no-ext-diff'])
assert actual==expected, 'Unrecorded Ghostty source modifications'
untracked=subprocess.check_output(['git','-C',str(source),'ls-files','--others','--exclude-standard','--','src','include','pkg','build.zig','build.zig.zon'],text=True).strip()
assert not untracked, 'Unrecorded files in engine build inputs: '+untracked
print('Ghostty revision and host patch verified')

import sys
if '--library' in sys.argv:
    manifest=json.loads((root/'vendor/ghostty-build.json').read_text())
    for file,digest in manifest.items():
        assert hashlib.sha256((root/file).read_bytes()).hexdigest()==digest, 'Engine input or library changed: '+file
    print('Engine library hashes verified')
