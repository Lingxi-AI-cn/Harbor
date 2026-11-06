"""Bind linked Ghostty objects to source packages and retained notices (conservative)."""
from pathlib import Path
import hashlib,json,os,re,subprocess,sys
root=Path(__file__).resolve().parents[1]; contents=Path(sys.argv[1]); linkmap=Path(sys.argv[2])
out=contents/'Resources/ThirdPartyNotices'; source=root/'vendor/ghostty'
inv=json.loads((out/'inventory.json').read_text()); packages=inv['packages']
cache=Path(os.environ.get('ZIG_GLOBAL_CACHE_DIR',str(Path.home()/'.cache/zig')))/'p'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
# Preserve complete embedded license blocks, not reconstructed licensing text.
extra=out/'Embedded';extra.mkdir()
def block(file,marker,name):
    text=file.read_text(); pos=text.index(marker); start=text.rfind('/*',0,pos+1); end=text.index('*/',pos)+2
    (extra/name).write_text(text[start:end]+'\n')
block(source/'src/stb/stb_image.h','ALTERNATIVE A - MIT License','stb-image.txt')
block(source/'src/stb/stb_image_resize.h','ALTERNATIVE A - MIT License','stb-resize.txt')
block(source/'pkg/simdutf/vendor/simdutf.h','Copyright (c) 2016-','simdutf-third-party.txt')
paths={};index={}
for p in packages:
    identifier=p['id']
    path=source/'zig-pkg'/identifier
    if not path.exists():path=cache/identifier
    if identifier=='ghostty':path=source
    elif isinstance(p['origin'],dict):
        # Follow the recorded local dependency edge, including user-replaced sources.
        parent=p['origin']['parent']
        if parent not in paths:raise RuntimeError('Missing local dependency parent: '+parent)
        path=(paths[parent]/p['origin']['path']).resolve()
    if not path.is_dir():continue
    paths[identifier]=path
    if 'sentry-' in str(p['origin']):block(path/'vendor/mpack.h','Copyright (c)','mpack.txt')
    for f in (source/'src' if identifier=='ghostty' else path).rglob('*'):
        if f.suffix in ('.c','.cc','.cpp','.m','.mm'):
            index.setdefault(f.stem+'.o',set()).add(identifier)
objects=re.findall(r'libghostty-internal\.a\(([^)]+)\)',linkmap.read_text(errors='replace').split('# Sections:')[0])
assert objects, 'Link map has no Ghostty objects'
notices={p['id']:p.get('notices',[]) for p in packages}
# Monolithic Zig units may contain code from imported modules: retain all fetched notices.
zig_units={'ghostty_zcu.o','highway_zcu.o','compiler_rt.o'}
mapped=[]
for name in objects:
    candidates=sorted(index.get(name,set()))
    if name in zig_units:candidates=['zig-runtime'] if name=='compiler_rt.o' else ['ghostty']
    if not candidates:raise RuntimeError('Unmapped linked object: '+name)
    if not any(notices.get(c) for c in candidates):
        # Ghostty-owned wrappers retain their parent MIT notice.
        if not all(c.startswith('ghostty--') for c in candidates):raise RuntimeError('Missing notices: '+name)
        candidates.append('ghostty')
    mapped.append({'object':name,'source_candidates':candidates})
manifest={'scope':'Linker-selected archive members mapped by source basename; ambiguous candidates are retained, not asserted as unique. Monolithic Zig units conservatively retain all fetched module notices. System frameworks are supplied by macOS.',
 'app_sha256':digest(contents/'MacOS/Harbor'),'link_map_sha256':digest(linkmap),
 'ghostty_archive_sha256':digest(source/'macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a'),
 'objects':mapped,'embedded_notices':{f.name:digest(f) for f in extra.iterdir()},
 'declaration_inventory':'inventory.json', 'dynamic_inventory':'Desktop/inventory.json',
 'release_requirements':['Provide corresponding LGPL source and rebuild/relink materials alongside binary releases (gettext/libintl static, libusb dynamic).','Preserve user ability to replace/rebuild LGPL components; reassess signed distribution policy before release.']}
(out/'LinkedComponents.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
(out/'README.txt').write_text('Harbor third-party notices\n\nPortions of this software are copyright The FreeType Project (www.freetype.org). All rights reserved. FreeType is used under the FreeType License (FTL); see its docs/FTL.TXT.\n\nlibusb is dynamically linked under LGPL-2.1-or-later. gettext/libintl is statically linked; see gettext-runtime/intl/COPYING.LIB and corresponding source URLs in inventory.json. Binary release preparation must include corresponding source and rebuild/relink materials; this development package is not a distribution clearance.\n\nLinkedComponents.json records the current executable hash and selected archive members, with conservative source candidates. Desktop/inventory.json records every bundled non-system dynamic library and its notices. inventory.json additionally includes unused/build-only declarations; those are not all runtime dependencies. simdutf embedded headers report 9.0.0 despite the upstream wrapper version 5.2.8; MIT notice is from v9.0.0.\n')
print('Mapped',len(mapped),'linked archive members; embedded notices:',len(list(extra.iterdir())))
