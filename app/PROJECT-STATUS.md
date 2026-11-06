# Feature status

Harbor is an early macOS development project, validated locally on Apple Silicon.

Implemented: local terminals; Ghostty and Legacy backends; tabs and terminal splits; SSH and jump hosts; session folders, favorites and recent sessions; SFTP browsing, transfer and UTF-8 editing; configurable serial access; SSH tunnels; embedded RDP/VNC and external-client handoff; snippets, selected-session broadcasting, logs, history exports and macros.

English and Simplified Chinese are available. Light, dark and automatic system appearance are supported. Import supports Harbor JSON and subsets of SSH config and MobaXterm bookmarks; it does not import password vaults or guarantee complete format compatibility.

Remote compatibility remains dependent on servers and devices. Physical serial hardware, broad RDP/VNC interoperability, long-running network recovery and full cross-machine build reproduction require further validation. There is no bundled X server. A Developer ID Application signed DMG has completed Apple notarization and ticket stapling, but has not been published. Functional acceptance remains open: the corresponding unsigned build has unresolved self-test, appearance and preference-persistence results requiring verification in a normal desktop session. See [build validation](PUBLIC-BUILD-VALIDATION.md).

See [verification](VERIFICATION.md), [desktop limits](P3-EMBEDDED-DESKTOP.md), and the repository README.
