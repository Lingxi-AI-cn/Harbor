"""Build with build.sh, then run from a macOS desktop terminal or open the emitted test app."""
from pathlib import Path
import json, os, plistlib, shlex, subprocess, sys, uuid
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'checks/appearance';OUT.mkdir(parents=True,exist_ok=True)
if '--desktop' in sys.argv:
    env=dict(os.environ,HARBOR_TEST_PREFERENCES_DOMAIN='local.harbor.appearance-test.'+uuid.uuid4().hex,
             HARBOR_APPEARANCE_OUTPUT=str(OUT),HARBOR_LANGUAGE='zh-Hans',
             GHOSTTY_RESOURCES_DIR=str(ROOT/'vendor/ghostty/zig-out/share/ghostty'))
    results={}
    for name,args in [('ui',[str(OUT/'native/native-test')]),('persist',[str(OUT/'native/native-test'),'--persist']),
                      ('selftest',[str(ROOT/'dist/Harbor.app/Contents/MacOS/Harbor'),'--self-test'])]:
        with (OUT/(name+'.log')).open('w') as log:
            try:code=subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=90).returncode
            except subprocess.TimeoutExpired:code=124
        results[name]=code
        (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    sys.exit(int(any(results.values())))
bundle=OUT/'Harbor Appearance Checks.app';macos=bundle/'Contents/MacOS';macos.mkdir(parents=True,exist_ok=True)
run=macos/'run';run.write_text('#!/bin/sh\nexec /usr/bin/python3 '+shlex.quote(str(Path(__file__).resolve()))+' --desktop\n');run.chmod(0o755)
with (bundle/'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(dict(CFBundleExecutable='run',CFBundleName='Harbor Appearance Checks',CFBundleIdentifier='local.harbor.appearance-checks',CFBundlePackageType='APPL'),stream)
print(bundle)
if '--prepare' not in sys.argv:subprocess.run(['open','-n',str(bundle)],check=True)
