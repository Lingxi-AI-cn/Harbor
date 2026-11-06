# Third-party credits

Harbor uses Apple AppKit, system fonts and SF Symbols through macOS APIs. SSH and SFTP use system OpenSSH executables, which are not bundled. Harbor is not affiliated with MobaXterm or Mobatek.

- Ghostty 1.4.0: MIT, Mitchell Hashimoto and contributors. Source: https://github.com/ghostty-org/ghostty
- FreeRDP/WinPR 3.33.0: Apache-2.0. Source: https://github.com/FreeRDP/FreeRDP
- OpenSSL 3 and bundled fonts/libraries retain their respective licenses.

Pinned commits are recorded in `DEPENDENCIES.json`. Build scripts collect third-party notices into the application bundle. A collected inventory is not a complete licensing or linked-dependency audit. Verify notices for each distributed artifact.

Harbor's own source is provided under the root MIT LICENSE. No original proprietary application binaries or artwork are included.

## Linked component notices

The package includes a hashed dynamic-library inventory and a linker-map-derived static member inventory under `Contents/Resources/ThirdPartyNotices`. Static source candidates can be ambiguous; monolithic Zig modules retain a conservative superset of notices. This is not a claim that every fetched declaration is linked.

- libusb 1.0.30 is dynamically linked, LGPL-2.1-or-later; its COPYING and AUTHORS are included.
- gettext/libintl is statically linked; its LGPL text is retained. A matching source/rebuild kit and local replacement/relink checks are prepared; distribute that kit with the matching binary. See [LGPL rebuild materials](LGPL-REBUILD.md).
- Portions of this software are copyright The FreeType Project (www.freetype.org). All rights reserved. FreeType uses the FreeType License (FTL), included in the bundle.
- simdutf embedded headers identify 9.0.0 (upstream wrapper metadata says 5.2.8); MIT and embedded third-party notices are retained. MPack, stb and Zig runtime notices are included.

Run `python3 scripts/verify-linked-notices.py dist/Harbor.app` to reject missing/tampered notices, unrecorded dynamic libraries or stale executable evidence. This verifies declaration coverage, not all legal conditions for a binary release.
