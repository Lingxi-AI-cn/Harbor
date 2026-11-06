from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1]
subprocess.run(['python3',str(root/'scripts/verify-ghostty.py')],check=True)
paths=[root/'vendor/ghostty.lock.json',root/'vendor/ghostty/include/ghostty.h']
paths+=list((root/'vendor/ghostty/macos/GhosttyKit.xcframework').rglob('*.a'))
assert len(paths)>2, 'No engine library built'
record={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
(root/'vendor/ghostty-build.json').write_text(json.dumps(record,indent=2)+'\n')
print('Recorded engine build inputs and library hashes')
