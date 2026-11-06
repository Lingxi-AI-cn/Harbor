# Embedded desktop support

The full application builds a FreeRDP/WinPR helper for RDP. VNC uses Harbor's RFB implementation, with RFB 3.3/3.7/3.8, None or traditional VNC password authentication, and Raw, CopyRect and DesktopSize encodings.

Supported controls include keyboard/mouse input, explicit text clipboard actions, manual reconnection and optional SSH routing. VNC passwords are limited to 8 bytes; TLS/VeNCrypt and Apple-specific VNC authentication are not supported. Use an appropriate secure route for untrusted networks.

Audio, drive/device redirection, desktop split panes and desktop layout restoration are not provided. External RDP/VNC clients are optional handoff targets; launching one does not verify successful connection.

The helper requires CMake, pkg-config and OpenSSL 3. Current scripts use `/opt/homebrew/opt/openssl@3`. Full Intel builds and broad real-server interoperability are not yet validated. See the repository README for build commands.
