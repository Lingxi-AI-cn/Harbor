# Verification

Run from a normal macOS desktop session with the required toolchain installed:

```sh
cargo build --offline --release
./target/release/harbor-terminal --self-test
python3 scripts/check-localization.py
```

After building the full application:

```sh
bash app/tests/appearance/build.sh
python3 app/tests/appearance/run.py
```

The appearance implementation previously passed 33 local appearance checks, one cross-process preference check and 77 application self-checks. These historical local results are not an acceptance certificate for a new build. The tests exercise effective appearance propagation without changing the user's macOS settings.

The public source also passed a complete Ghostty/FreeRDP/application build, package checks and local protocol checks. See [the exact build validation](PUBLIC-BUILD-VALIDATION.md). This does not establish cross-machine byte reproducibility or general remote-server compatibility. Generated logs and screenshots are not shipped. Run applicable checks for the exact artifact you intend to use or distribute.

## Current notarized artifact (2026-11-06)

The Developer ID Application signed DMG has been accepted by Apple's notary service, with stapling and validation reported successful in the user's terminal. Its final SHA-256 was checked directly. It has not been published. See [artifact identities and evidence limits](PUBLIC-BUILD-VALIDATION.md) and [matching LGPL materials](LGPL-REBUILD.md).

The notarized artifact uses the earlier notice-repair build, whose self-tests stopped after 26 passes, appearance checks had 5 failures out of 33, and cross-process preference persistence failed. A normal desktop-session rerun on the final signed application is still required; environmental errors have not been established as the sole cause. Historical passing checks on other builds are not acceptance evidence for this artifact.
