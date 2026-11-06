"""Build a fresh bundle, record inputs, then replace the prior generated bundle."""
import hashlib, json, os, pathlib, plistlib, shutil, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
records = [json.loads(x) for x in pathlib.Path(os.environ['BUILD_LOG']).read_text().splitlines() if x.startswith('{')]
out = next(pathlib.Path(x['out_dir']) for x in reversed(records) if x.get('reason') == 'build-script-executed' and 'harbor-terminal' in x['package_id'])
lock = json.loads((root/'vendor/ghostty.lock.json').read_text())
source = root/'vendor/ghostty'; dist = root/'dist'; dist.mkdir(exist_ok=True)
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='.harbor-package-',dir=dist) as temp:
    staging = pathlib.Path(temp)/'Harbor.app'; contents = staging/'Contents'
    (contents/'MacOS').mkdir(parents=True)
    shutil.copy2(out/'Harbor',contents/'MacOS/Harbor')
    # Remove Mach-O debug maps that retain compiler and static-archive paths.
    subprocess.run(['xcrun','strip','-S',str(contents/'MacOS/Harbor')],check=True)
    resources = contents/'Resources'; resources.mkdir()
    subprocess.run(['python3',str(root/'scripts/build-app-icon.py'),str(resources/'Harbor.icns')],check=True)
    shutil.copytree(source/'zig-out/share',resources,dirs_exist_ok=True,ignore=shutil.ignore_patterns('pkgconfig'))
    shutil.copy2(source/'LICENSE',resources/'GHOSTTY-LICENSE')
    subprocess.run(['python3',str(root/'scripts/collect-ghostty-notices.py'),str(resources/'ThirdPartyNotices')],check=True)
    (resources/'GhosttySource.txt').write_text(f'Ghostty v{lock["version"]} commit {lock["commit"]}\n{lock["repository"]}\nSee ThirdPartyNotices/inventory.json for fetched dependency notices and remaining gaps. Local validation build.\n')
    subprocess.run(['python3',str(root/'scripts/package-desktop-engine.py'),str(contents)],check=True)
    subprocess.run(['python3',str(root/'scripts/collect-linked-notices.py'),str(contents),str(out/'Harbor-link-map.txt')],check=True)
    inputs = list((root/'app').glob('*.swift')) + [root/p for p in ['Cargo.toml','Cargo.lock','app/build.rs','vendor/ghostty.lock.json','vendor/ghostty-build.json','scripts/package-ghostty.py','scripts/collect-ghostty-notices.py','app/package-ghostty.sh','app/desktop-engine/main.c','scripts/build-desktop-engine.sh','scripts/package-desktop-engine.py','scripts/verify-package-metadata.py','vendor/desktop-engine/harbor-desktop-engine']]
    inputs += [root/'app/Resources/zh-Hans.json', root/'scripts/generate-localization.py']
    inputs += [root/'app/Resources/AppIcon/Harbor.png', root/'scripts/build-app-icon.py']
    inputs += [root/'scripts/collect-linked-notices.py']
    inputs += [root/'scripts/verify-linked-notices.py']
    inputs += [root/'vendor'/patch['file'] for patch in lock.get('patches',[])]
    inputs += [p for p in (root/'vendor/notices').rglob('*') if p.is_file()]
    provenance = {'inputs':{str(p.relative_to(root)):digest(p) for p in sorted(inputs)},'swift':subprocess.check_output(['xcrun','swiftc','--version'],text=True).strip(),'cargo':subprocess.check_output(['cargo','--version'],text=True).strip(),'scope':'Local unsigned validation build; hashes identify inputs, not an independent engine rebuild proof.'}
    (resources/'BuildProvenance.json').write_text(json.dumps(provenance,indent=2,sort_keys=True)+'\n')
    with (contents/'Info.plist').open('wb') as f:
        plistlib.dump(dict(CFBundleIdentifier='local.harbor.terminal',CFBundleName='Harbor',CFBundleExecutable='Harbor',CFBundleIconFile='Harbor.icns',CFBundlePackageType='APPL',CFBundleVersion='0.1.0',NSHighResolutionCapable=True,NSPrincipalClass='NSApplication',CFBundleDevelopmentRegion='en',CFBundleLocalizations=['en','zh-Hans']),f)
    subprocess.run(['python3',str(root/'scripts/verify-package-metadata.py'),str(staging)],check=True)
    subprocess.run(['python3',str(root/'scripts/verify-linked-notices.py'),str(staging)],check=True)
    manifest = {str(p.relative_to(staging)):digest(p) for p in sorted(staging.rglob('*')) if p.is_file()}
    (contents/'BundleManifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
    destination = dist/'Harbor.app'; backup = pathlib.Path(temp)/'previous.app'
    if destination.exists(): destination.rename(backup)
    try: staging.rename(destination)
    except BaseException:
        if backup.exists(): backup.rename(destination)
        raise
print(dist/'Harbor.app')
