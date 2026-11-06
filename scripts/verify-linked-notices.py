"""Reject stale linked-component evidence and missing/tampered dependency notices."""
from pathlib import Path
import hashlib,json,subprocess,sys
bundle=Path(sys.argv[1]); contents=bundle/'Contents'; notices=contents/'Resources/ThirdPartyNotices'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
linked=json.loads((notices/'LinkedComponents.json').read_text())
assert digest(contents/'MacOS/Harbor')==linked['app_sha256'], 'Stale executable evidence'
desktop=json.loads((notices/'Desktop/inventory.json').read_text())['libraries']
assert {p.name for p in (contents/'Frameworks').iterdir() if p.is_file()}==set(desktop), 'Unrecorded bundled library'
for binary in list((contents/'MacOS').iterdir())+list((contents/'Frameworks').iterdir()):
    deps=subprocess.check_output(['otool','-L',str(binary)],text=True).splitlines()[1:]
    for line in deps:
        dep=line.strip().split(' (compatibility')[0]
        if dep.startswith(('/usr/lib/','/System/Library/')):continue
        if dep=='@rpath/'+binary.name and binary.parent.name=='Frameworks':continue
        assert dep.startswith('@loader_path/'), 'Unresolved non-system load: '+dep
        resolved=(binary.parent/dep.removeprefix('@loader_path/')).resolve()
        assert resolved.parent==(contents/'Frameworks').resolve() and resolved.name in desktop, 'Missing linked dependency: '+dep
for name,record in desktop.items():
    assert record['license'] and record['source_url'] and record['notices'], 'Incomplete dynamic notice record'
    assert digest(contents/'Frameworks'/name)==record['packaged_sha256'], 'Changed dynamic library: '+name
    for name,h in record['notices'].items():assert digest(notices/'Desktop'/name)==h, 'Changed dynamic notice: '+name
packages=json.loads((notices/'inventory.json').read_text())['packages'];ids={p['id'] for p in packages}
for p in packages:
    for n in p.get('notices',[]):assert digest(notices/n['path'])==n['sha256'], 'Changed static notice: '+n['path']
for row in linked['objects']:
    assert row['source_candidates'] and set(row['source_candidates'])<=ids, 'Unmapped linked member'
for name,h in linked['embedded_notices'].items():assert digest(notices/'Embedded'/name)==h, 'Changed embedded notice'
assert len(linked['objects'])>0
print('Verified',len(desktop),'dynamic libraries and',len(linked['objects']),'selected archive members with notice hashes')
