#!/bin/bash
# Initialize pinned source dependencies from a source archive or fresh repository.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import json,subprocess
root=Path.cwd()
for item in json.loads((root/'DEPENDENCIES.json').read_text()):
    path=root/item['path']
    if path.exists():
        if not (path/'.git').exists():raise SystemExit('Existing dependency is not a Git checkout: '+item['path'])
        origin=subprocess.check_output(['git','-C',str(path),'remote','get-url','origin'],text=True).strip()
        if origin != item['url']:raise SystemExit('Dependency origin mismatch: '+item['path'])
        head=subprocess.run(['git','-C',str(path),'rev-parse','--verify','HEAD'],capture_output=True,text=True)
        if head.returncode == 0:
            if head.stdout.strip() != item['commit']:raise SystemExit('Dependency revision mismatch: '+item['path'])
            subprocess.run(['git','-C',str(path),'diff','--exit-code','HEAD'],check=True)
            continue
    else:
        path.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run(['git','init',str(path)],check=True)
        subprocess.run(['git','-C',str(path),'remote','add','origin',item['url']],check=True)
    subprocess.run(['git','-c','http.version=HTTP/1.1','-C',str(path),'fetch','--depth=1','origin',item['commit']],check=True)
    subprocess.run(['git','-C',str(path),'checkout','--detach',item['commit']],check=True)
PY
