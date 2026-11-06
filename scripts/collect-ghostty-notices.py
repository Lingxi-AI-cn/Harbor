"""Collect fetched declared dependencies, not a claim that every package is linked."""
import hashlib, json, os, re, shutil, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = root / 'vendor/ghostty'
cache = Path(os.environ.get('ZIG_GLOBAL_CACHE_DIR', str(Path.home()/'.cache/zig'))) / 'p'
local_packages = source / 'zig-pkg'
lock = json.loads((root/'vendor/ghostty.lock.json').read_text())
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
seen = set(); packages = []; missing = []
notice_name = re.compile(r'^(license|licence|copying|copyright|notice|ofl)([._-]|$)', re.I)
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def visit(path, identifier, origin):
    path = path.resolve()
    if path in seen: return
    seen.add(path)
    if not path.exists():
        missing.append({'id': identifier, 'origin': origin, 'reason': 'not fetched; may be unused on this target'}); return
    record = {'id': identifier, 'origin': origin, 'notices': []}
    # Do not walk engine caches; local package wrappers are handled separately.
    candidates = list(path.rglob('*')) if (cache in path.parents or local_packages in path.parents) else list(path.iterdir())
    if path == source:
        candidates += list((source/'vendor/nerd-fonts').rglob('*'))
    if 'freetype-' in str(origin):
        candidates += [path/'docs/FTL.TXT', path/'src/bdf/README', path/'src/pcf/README']
    for file in sorted(candidates):
        special = file in [path/'docs/FTL.TXT', path/'src/bdf/README', path/'src/pcf/README']
        if not file.is_file() or (not special and not notice_name.match(file.name)) or file.suffix in ['.cfg','.py','.sh']: continue
        rel = file.relative_to(path)
        destination = out/identifier/rel
        destination.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(file,destination)
        record['notices'].append({'path':str(Path(identifier)/rel),'sha256':digest(file)})
    supplements = json.loads((root/'vendor/notices/index.json').read_text())
    if identifier in supplements:
        extra = root/'vendor/notices'/supplements[identifier]
        sources = json.loads((extra/'sources.json').read_text())
        for entry in sources:
            file = extra/entry['file']
            assert digest(file) == entry['sha256'], 'Supplemental notice changed: '+str(file)
            destination = out/identifier/entry['file']
            destination.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(file,destination)
            record['notices'].append({'path':str(Path(identifier)/entry['file']),'sha256':entry['sha256'],'origin':entry['url']})
        record['supplemental_sources'] = sources
    zon = path/'build.zig.zon'
    if zon.exists(): record['build_zig_zon_sha256'] = digest(zon)
    if not record['notices'] and (cache in path.parents or local_packages in path.parents):
        record['notice_status'] = 'missing standalone notice; review source headers before distribution'
        # Preserve actual SPDX declarations as evidence, without synthesizing a license.
        headers = []
        for file in sorted(path.rglob('*.zig')):
            for line in file.read_text(errors='replace').splitlines()[:5]:
                if 'SPDX-License-Identifier:' in line or 'Copyright' in line:
                    headers.append(str(file.relative_to(path))+': '+line)
        if headers:
            dest=out/identifier/'SOURCE-HEADERS.txt'; dest.parent.mkdir(parents=True,exist_ok=True); dest.write_text('\n'.join(headers)+'\n')
            record['source_headers']={'path':str(Path(identifier)/dest.name),'sha256':digest(dest)}
    packages.append(record)
    if not zon.exists(): return
    text=zon.read_text()
    for match in re.finditer(r'\.(\w+)\s*=\s*\.\{([^{}]*)\}',text,re.S):
        name,body=match.groups()
        hashed=re.search(r'\.hash\s*=\s*"([^"]+)"',body)
        url=re.search(r'\.url\s*=\s*"([^"]+)"',body)
        local=re.search(r'\.path\s*=\s*"([^"]+)"',body)
        if hashed:
            package_path = local_packages/hashed[1]
            if not package_path.is_dir(): package_path = cache/hashed[1]
            visit(package_path,hashed[1],url[1] if url else name)
        elif local: visit(path/local[1],identifier+'--'+name,{'parent':identifier,'path':local[1]})
visit(source,'ghostty',lock['repository']+'/tree/'+lock['commit'])
visit(root/'vendor/notices/zig-runtime','zig-runtime','https://github.com/ziglang/zig/tree/'+lock['zig'])
manifest={'scope':'Fetched declared dependency graph; includes build-only and unused-platform packages. Not a linked-component SBOM or distribution clearance.', 'packages':packages,'unfetched':missing}
(out/'inventory.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
print(f'Collected {len(packages)} package records; {len(missing)} unfetched declarations')
