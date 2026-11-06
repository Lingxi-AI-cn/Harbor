#!/usr/bin/env python3
"""Create a Developer ID signed Harbor DMG candidate; never submit or publish it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
DEVELOPER_ID_REQUIREMENT = 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
MACHO_MAGIC = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def run(argv, stdout_only=False):
    result = subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                            env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {argv[0]}\n{result.stdout}{result.stderr}")
    return result.stdout if stdout_only else result.stdout + result.stderr


def digest(path, algorithm='sha256'):
    h = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def hashes(app):
    return {str(p.relative_to(app)): digest(p) for p in sorted(app.rglob('*')) if p.is_file()}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def code_paths(app):
    # This packager deliberately supports Harbor's current flat bundle layout.
    # Reject new code locations instead of silently leaving code unsigned.
    contents = app / 'Contents'
    expected = {contents / 'MacOS/Harbor', contents / 'MacOS/harbor-desktop-engine'}
    expected.update((contents / 'Frameworks').glob('*.dylib'))
    actual = set()
    for p in app.rglob('*'):
        require(not p.is_symlink(), f'Unsupported bundle symlink: {p}')
        if p.is_file():
            with p.open('rb') as stream:
                if stream.read(4) in MACHO_MAGIC:
                    actual.add(p)
    require(actual == expected, 'Unexpected or missing Mach-O code; review bundle layout before signing')
    return sorted(expected - {contents / 'MacOS/Harbor'})


def validate_input(app):
    require(app.is_dir(), 'Input must be a built, unsigned Harbor.app directory')
    manifest = app / 'Contents/BundleManifest.json'
    require(manifest.is_file(), 'Unsigned BundleManifest.json missing. Use the original built app, not the local-test signed app.')
    expected = json.loads(manifest.read_text())
    expected['Contents/BundleManifest.json'] = digest(manifest)
    require(hashes(app) == expected, 'Unsigned input does not match its exact manifest')
    code_paths(app)
    for script in ('verify-linked-notices.py', 'verify-package-metadata.py'):
        run([sys.executable, ROOT / script, app])
    return digest(manifest)


def validate_identity(identity, listing):
    require(re.fullmatch(r'[0-9a-fA-F]{40}', identity) is not None,
            'Use the exact 40-character certificate SHA-1 from security find-identity')
    entries = re.findall(r'\b([0-9A-Fa-f]{40})\s+"([^"]+)"', listing)
    matches = [name for fingerprint, name in entries if fingerprint.upper() == identity.upper()]
    require(matches and all(name.startswith('Developer ID Application:') for name in matches),
            'Identity is not a valid Developer ID Application identity with a private key in the keychain')


def validate_details(details, runtime):
    require(re.search(r'^Authority=Developer ID Application:', details, re.M), 'Wrong certificate type')
    require(re.search(r'^Timestamp=.+', details, re.M), 'Secure timestamp missing')
    team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details, re.M)
    require(team, 'Signing TeamIdentifier missing')
    if runtime:
        flags = re.search(r'flags=0x([0-9a-fA-F]+)', details)
        require(flags and int(flags.group(1), 16) & 0x10000, 'Hardened Runtime missing')
    return team.group(1)


def verify_signature(path, identity, temp, runtime=True):
    # Without '=', codesign treats the requirement text as a filename.
    run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', '-R', '=' + DEVELOPER_ID_REQUIREMENT, path])
    details = run(['/usr/bin/codesign', '--display', '--verbose=4', path])
    team = validate_details(details, runtime)
    prefix = temp / 'certificate-'
    for previous in temp.glob('certificate-*'):
        previous.unlink()
    run(['/usr/bin/codesign', '--display', '--extract-certificates=' + str(prefix), path])
    leaf = Path(str(prefix) + '0')
    require(leaf.is_file() and digest(leaf, 'sha1').upper() == identity.upper(), 'Unexpected leaf signing certificate')
    if runtime:
        entitlements = run(['/usr/bin/codesign', '--display', '--entitlements', ':-', path], stdout_only=True)
        # codesign omits the entitlement blob for an empty dictionary on macOS.
        require(not entitlements.strip() or plistlib.loads(entitlements.encode()) == {},
                'Unexpected entitlements in signed code')
    return details, team


def build(source, output, identity, manifest_sha):
    require(not output.exists(), 'Destination exists; choose a new output directory')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.harbor-notarization-', dir=output.parent) as work:
        temp = Path(work)
        delivery, volume = temp / 'delivery', temp / 'volume'
        delivery.mkdir(); volume.mkdir()
        app = volume / 'Harbor.app'
        run(['/usr/bin/ditto', source, app])
        require(validate_input(app) == manifest_sha, 'Input changed while copying')
        contents = app / 'Contents'
        entitlements = temp / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps({}))
        signature_records = {}
        teams = set()

        def sign(path, runtime=True):
            command = ['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp']
            if runtime:
                command += ['--options', 'runtime', '--entitlements', entitlements]
            print('Signing:', path.name, flush=True)
            run(command + [path])
            details, team = verify_signature(path, identity, temp, runtime)
            teams.add(team)
            require(len(teams) == 1, 'Inconsistent signing teams')
            signature_records[str(path.relative_to(temp))] = details

        for binary in code_paths(app):
            sign(binary)
        notices = contents / 'Resources/ThirdPartyNotices'
        inventory = notices / 'Desktop/inventory.json'
        record = json.loads(inventory.read_text())
        for name, entry in record['libraries'].items():
            entry['packaged_sha256'] = digest(contents / 'Frameworks' / name)
        write_json(inventory, record)
        linked = notices / 'LinkedComponents.json'
        record = json.loads(linked.read_text())
        record['pre_signing_app_sha256'] = record.pop('app_sha256')
        record['verification_phase'] = 'Unsigned build evidence; use codesign and external SIGNED-BUNDLE-MANIFEST.json for signed payload.'
        write_json(linked, record)
        evidence = contents / 'Resources/UnsignedBuildEvidence'
        evidence.mkdir()
        (contents / 'BundleManifest.json').rename(evidence / 'BundleManifest.json')
        (evidence / 'README.txt').write_text('Historical unsigned-build hashes. Signing changes code bytes. Verify signed payload using codesign and external SIGNED-BUNDLE-MANIFEST.json.\n')
        sign(app)
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        signed = hashes(app)
        write_json(volume / 'SIGNED-BUNDLE-MANIFEST.json', signed)
        (volume / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (volume / 'READ-ME.txt').write_text('Harbor Developer ID signed notarization candidate. NOT YET NOTARIZED.\nDrag Harbor.app to Applications after notarization.\nSigned payload: SIGNED-BUNDLE-MANIFEST.json. Unsigned evidence is historical only.\n')
        dmg = delivery / 'Harbor-arm64-notarization.dmg'
        run(['/usr/bin/hdiutil', 'create', '-volname', 'Harbor', '-srcfolder', volume, '-fs', 'HFS+', '-format', 'UDZO', dmg])
        sign(dmg, runtime=False)
        run(['/usr/bin/hdiutil', 'verify', dmg])
        mounted = temp / 'mounted'; mounted.mkdir()
        run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mounted, dmg])
        try:
            mounted_app = mounted / 'Harbor.app'
            run(['/usr/bin/codesign', '--verify', '--deep', '--strict', mounted_app])
            for path in code_paths(mounted_app) + [mounted_app]:
                verify_signature(path, identity, temp)
            require(hashes(mounted_app) == signed, 'Mounted payload differs from signed manifest')
            require(json.loads((mounted / 'SIGNED-BUNDLE-MANIFEST.json').read_text()) == signed,
                    'Mounted manifest differs')
        finally:
            run(['/usr/bin/hdiutil', 'detach', mounted])
        for name in ('SIGNED-BUNDLE-MANIFEST.json', 'READ-ME.txt'):
            shutil.copy2(volume / name, delivery / name)
        write_json(delivery / 'SIGNATURES.json', signature_records)
        receipt = {'status': 'signed candidate; not submitted, notarized, or published',
                   'certificate_sha1': identity.upper(), 'team_id': next(iter(teams)),
                   'unsigned_manifest_sha256': manifest_sha, 'dmg_sha256': digest(dmg),
                   'signed_manifest_sha256': digest(delivery / 'SIGNED-BUNDLE-MANIFEST.json'),
                   'checks': ['input manifest and notices', 'explicit nested signing', 'Developer ID certificate requirement',
                              'exact leaf certificate', 'secure timestamps', 'hardened runtime', 'empty entitlements',
                              'deep strict signature', 'DMG integrity', 'mounted signatures and exact payload']}
        write_json(delivery / 'BUILD-RECEIPT.json', receipt)
        (delivery / 'SHA256SUMS').write_text(f"{digest(dmg)}  {dmg.name}\n")
        require(not output.exists(), 'Destination appeared during build; refusing to replace it')
        delivery.rename(output)
    print(output / 'Harbor-arm64-notarization.dmg')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, help='Original unsigned app with Contents/BundleManifest.json')
    parser.add_argument('output', type=Path, nargs='?', help='New output directory; never overwritten')
    parser.add_argument('--identity', help='Exact Developer ID Application certificate SHA-1')
    parser.add_argument('--check-input', action='store_true', help='Verify input only; no keychain access, signing, or output')
    args = parser.parse_args()
    require(sys.platform == 'darwin', 'This script requires macOS')
    source = args.app.resolve()
    manifest_sha = validate_input(source)
    if args.check_input:
        print('Unsigned input validated; no signing or keychain access performed.')
        return
    require(args.output is not None and args.identity, 'Provide output directory and --identity, or use --check-input')
    identity = args.identity.upper()
    validate_identity(identity, run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning']))
    build(source, args.output.resolve(), identity, manifest_sha)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
