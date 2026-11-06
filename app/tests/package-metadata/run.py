from pathlib import Path
import importlib.util,json,plistlib,tempfile
root=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('metadata',root/'scripts/verify-package-metadata.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    path=Path(directory);file=path/'inventory.json'
    file.write_text(json.dumps({'source':'dependency:libssl.3.dylib','sha256':'abc'}));module.verify(path)
    for source in ['/'+'Users/alice/build/lib.dylib','/home/alice/build','/private/var/tmp/build','/opt/homebrew/opt/openssl/lib.dylib']:
        file.write_text(json.dumps({'source':source}))
        try:module.verify(path)
        except ValueError:pass
        else:raise AssertionError('Local source path accepted')
    file.write_text('{"source":"\\u002fUsers/alice/build"}')
    try:module.verify(path)
    except ValueError:pass
    else:raise AssertionError('Escaped local path accepted')
    file.unlink();file=path/'Info.plist'
    file.write_bytes(plistlib.dumps({'Source':'/'+'Users/alice/build'},fmt=plistlib.FMT_BINARY))
    try:module.verify(path)
    except ValueError:pass
    else:raise AssertionError('Binary plist local path accepted')
    file.unlink();file=path/'binary'
    file.write_bytes(b'\x00'+b'/'+b'Users/alice/project'+b'\x00')
    try:module.verify(path)
    except ValueError:pass
    else:raise AssertionError('Binary debug path accepted')
print('PASS: portable identifier accepted; 7 local-path cases rejected')
