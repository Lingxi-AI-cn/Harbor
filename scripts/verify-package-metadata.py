"""Reject build-machine paths in bundle metadata, independently of its hash manifest."""
from pathlib import Path
import json,plistlib,re,sys

def verify(bundle):
    bundle=Path(bundle)
    known=[str(Path.home()),str(Path(__file__).resolve().parents[1])]
    forbidden=re.compile(r'(?:/(?:Users|home)/|/private/(?:tmp/|var/)|/var/folders/|/opt/homebrew/|/usr/local/(?:Cellar|opt)/|[A-Za-z]:\\Users\\)')
    checked=0
    for file in bundle.rglob('*'):
        if not file.is_file():continue
        data=file.read_bytes()
        # Also reject build-machine identifiers in Mach-O/debug/runtime data.
        if b'/'+b'Users/' in data or any(len(path)>1 and path.encode() in data for path in known):
            raise ValueError('Build-machine path in '+str(file.relative_to(bundle)))
        if file.suffix.lower() not in ('.json','.plist','.txt'):continue
        if file.suffix.lower()=='.plist':
            text=json.dumps(plistlib.loads(data),default=str)
        elif file.suffix.lower()=='.json':text=json.dumps(json.loads(data),ensure_ascii=False)
        else:text=data.decode('utf-8')
        if forbidden.search(text) or any(len(path)>1 and path in text for path in known):
            raise ValueError('Build-machine path in '+str(file.relative_to(bundle)))
        checked+=1
    print(f'Verified {checked} metadata/text files and all payload bytes: no build-machine paths')

if __name__=='__main__':verify(sys.argv[1])
