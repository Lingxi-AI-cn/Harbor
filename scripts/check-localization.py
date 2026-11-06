"""Check every explicitly localized literal and generated catalog; never translate protocol data."""
from pathlib import Path
import json,re,subprocess
from swift_strings import scan
root=Path(__file__).resolve().parents[1]
subprocess.run(['python3',str(root/'scripts/generate-localization.py'),'--check'],check=True)
translations=json.loads((root/'app/Resources/zh-Hans.json').read_text());count=0;missing=[]
for p in sorted((root/'app').glob('*.swift')):
 if p.name=='LocalizationCatalog.swift':continue
 source=p.read_text()
 for item in scan(source):
  if re.search(r'\bL\(\s*$',source[:item['start']]):
   count+=1
   if item['key'] not in translations:missing.append(f'{p.name}:{source.count(chr(10),0,item["start"])+1}: {item["key"]}')
assert not missing,'Missing translations:\n'+'\n'.join(missing)
print(f'Checked {count} localized literal sites; no missing keys')
