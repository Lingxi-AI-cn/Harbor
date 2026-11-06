import Foundation

/// Shared defaults and connection policy for Harbor.
enum HarborDefaults {
    static let autoOpenRemoteFilesDefault = true
    static let sshKeepAliveSeconds = 36
    static let forwardAgentDefault = false
    static let scrollbackLines = 360_000

    static func shouldAutoOpenRemoteFiles(connected: Bool, isActiveSession: Bool, enabled: Bool) -> Bool {
        connected && isActiveSession && enabled
    }

    static func sshOptions(keepAlive: Bool, compression: Bool, forwardAgent: Bool = forwardAgentDefault) -> [String] {
        ["-o", "ServerAliveInterval=\(keepAlive ? sshKeepAliveSeconds : 0)"]
        + (compression ? ["-C"] : ["-o", "Compression=no"])
        + ["-o", "ForwardAgent=\(forwardAgent ? "yes" : "no")"]
    }
}
