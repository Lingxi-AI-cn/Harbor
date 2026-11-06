use std::{env, path::PathBuf, process::Command};
fn main() {
    assert_eq!(env::var("CARGO_CFG_TARGET_OS").as_deref(), Ok("macos"), "Harbor requires macOS");
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let files = ["Localization.swift", "LocalizationCatalog.swift", "TerminalMacroEvent.swift", "TerminalPreferences.swift", "Mechanics.swift", "Terminal.swift", "TerminalHost.swift", "TerminalPaneLayout.swift", "WorkspaceState.swift", "SessionManagement.swift", "Productivity.swift", "SerialTransport.swift", "SerialUI.swift", "DesktopSessions.swift", "EmbeddedDesktop.swift", "GhosttyRuntime.swift", "GhosttyTerminal.swift", "TransferOperation.swift", "RemoteFiles.swift", "RemoteFileWorkflows.swift", "Harbor.swift"];
    println!("cargo:rerun-if-changed=app/Resources/zh-Hans.json");
    println!("cargo:rerun-if-changed=scripts/generate-localization.py");
    let catalog = Command::new("python3").arg(root.join("scripts/generate-localization.py")).arg("--check").status().expect("Localization validator failed");
    assert!(catalog.success(), "Regenerate the localization catalog");
    let mut cmd = Command::new("/usr/bin/xcrun");
    cmd.args(["swiftc", "-O", "-module-cache-path"]).arg(root.join("app/.swift-module-cache"));
    for file in files { println!("cargo:rerun-if-changed=app/{file}"); cmd.arg(root.join("app").join(file)); }
    if env::var_os("CARGO_FEATURE_GHOSTTY").is_some() {
        let upstream = root.join("vendor/ghostty");
        let verified = Command::new("python3").arg(root.join("scripts/verify-ghostty.py")).arg("--library").status().expect("Ghostty source verifier failed");
        assert!(verified.success(), "Ghostty source verification failed");
        println!("cargo:rerun-if-changed=scripts/verify-ghostty.py");
        println!("cargo:rerun-if-changed=vendor/ghostty/src");
        println!("cargo:rerun-if-changed=vendor/ghostty/pkg");
        println!("cargo:rerun-if-changed=vendor/ghostty/build.zig");
        println!("cargo:rerun-if-changed=vendor/ghostty/build.zig.zon");
        println!("cargo:rerun-if-changed=vendor/ghostty.lock.json");
        println!("cargo:rerun-if-changed=vendor/ghostty-build.json");
        let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap();
        let slice = if arch == "aarch64" { "macos-arm64" } else { "macos-x86_64" };
        let lib = upstream.join("macos/GhosttyKit.xcframework").join(slice).join("libghostty-internal.a");
        assert!(lib.exists(), "Run scripts/build-ghostty.sh before building --features ghostty");
        println!("cargo:rerun-if-changed={}", lib.display());
        println!("cargo:rerun-if-changed={}", upstream.join("include/ghostty.h").display());
        cmd.args(["-D", "GHOSTTY", "-import-objc-header"]).arg(upstream.join("include/ghostty.h")).arg(lib);
        for framework in ["AppKit", "Metal", "MetalKit", "QuartzCore", "CoreText", "CoreGraphics", "Carbon", "IOKit"] { cmd.args(["-framework", framework]); }
        cmd.arg("-lc++");
        println!("cargo:rustc-env=HARBOR_GHOSTTY_RESOURCES={}", upstream.join("zig-out/share/ghostty").display());
    }
    cmd.args(["-Xlinker", "-map", "-Xlinker"]).arg(out.join("Harbor-link-map.txt"));
    let status = cmd.arg("-o").arg(out.join("Harbor")).status().expect("Could not start Swift compiler");
    assert!(status.success(), "Native build failed");
}
