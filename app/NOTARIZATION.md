# Create a notarization candidate DMG

Run on macOS from the repository root with Python 3 and Apple's command-line tools. Start from the original built `dist/Harbor.app` containing `Contents/BundleManifest.json`, **not** the Apple Development signed local-test app or a mounted DMG. The script copies the input and never alters it or replaces an existing output directory.

## Check input without signing

```sh
python3 scripts/create-notarization-dmg.py dist/Harbor.app --check-input
```

This checks the exact bundle manifest, linked notices, package metadata and expected Mach-O locations. It does not access the keychain or use credentials.

## Sign and package

Install your **Developer ID Application** certificate and its matching private key in your own keychain. Apple Development, Apple Distribution and Developer ID Installer certificates are rejected. Find the exact certificate SHA-1:

```sh
security find-identity -v -p codesigning
```

Then run, replacing the placeholder with its 40-character SHA-1:

```sh
python3 scripts/create-notarization-dmg.py \
  dist/Harbor.app \
  dist/Harbor-notarization-candidate \
  --identity YOUR_DEVELOPER_ID_APPLICATION_CERTIFICATE_SHA1
```

Signing may prompt for permission to use the private key. Internet access to Apple's timestamp service is required. A timestamp failure stops the build; there is no fallback to an unsigned or untimestamped package.

The script explicitly signs dylibs and the helper before the app using `--options runtime --timestamp`, and signs the DMG with `--timestamp`. It verifies the Developer ID certificate requirement, exact leaf certificate, consistent team, secure timestamps, runtime flags, and empty entitlements. It then verifies the DMG and mounts it read-only to recheck code signatures and every signed payload hash. No runtime exceptions or debug entitlements are enabled. New bundle code layouts require review and are rejected rather than silently skipped.

Successful output contains:

- `Harbor-arm64-notarization.dmg`
- `SHA256SUMS`
- `SIGNED-BUNDLE-MANIFEST.json`
- `SIGNATURES.json`
- `BUILD-RECEIPT.json`
- `READ-ME.txt`

These prove local signing and packaging checks, **not Apple's notarization acceptance**. The script never calls `notarytool`, submits credentials, publishes files, or edits the existing LGPL archive or original DMG. It does not perform an interactive functional smoke test; test terminal, helper and remote session functionality under the final signature before release.

## Submit separately

After configuring a notarytool keychain profile yourself, submit the generated candidate explicitly:

```sh
xcrun notarytool submit \
  dist/Harbor-notarization-candidate/Harbor-arm64-notarization.dmg \
  --keychain-profile YOUR_NOTARY_PROFILE --wait
```

Only after the returned status is `Accepted`, inspect the notarization log and staple the DMG:

```sh
xcrun stapler staple dist/Harbor-notarization-candidate/Harbor-arm64-notarization.dmg
xcrun stapler validate dist/Harbor-notarization-candidate/Harbor-arm64-notarization.dmg
```

Stapling changes DMG bytes. Preserve the build receipt as pre-submission evidence; generate a new final SHA-256, update the release's DMG/source correspondence record, and ship the matching LGPL source/rebuild materials alongside the final artifact. Do not reuse the local-test DMG hash. The signed app manifest remains applicable when only the outer DMG is stapled.

Apple references: [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

## Script verification

```sh
python3 app/tests/notarization-packaging/run.py
```

The offline tests cover certificate selection, rejection of missing timestamps/runtime, unexpected code and symlinks, changed input, and existing-output protection. They do not use a real Developer ID private key. A successful end-to-end Developer ID signing run and Apple acceptance must be verified separately on the resulting artifact.
