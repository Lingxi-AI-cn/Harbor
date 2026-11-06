import Foundation

enum TunnelMode: String, Codable, CaseIterable {
    case local, remote, dynamic
    var title: String { switch self { case .local: return L("Local forwarding"); case .remote: return L("Remote forwarding"); case .dynamic: return L("Dynamic SOCKS") } }
}
struct TunnelDescriptor: Codable {
    var connection: Connection
    var localPort: Int
    var remote: String
    var mode: TunnelMode? = nil
    var profileID: UUID? = nil
    var kind: TunnelMode { mode ?? .local }
    func validate(checkIdentity: Bool = true) throws {
        try connection.validate(checkIdentity:checkIdentity)
        guard connection.kind == "SSH", (1024...65535).contains(localPort) else { throw HarborError.message(L("Choose an SSH connection and a listen port between 1024 and 65535.")) }
        if kind != .dynamic {
            guard remote.range(of:#"^(?:[A-Za-z0-9_][A-Za-z0-9._\-]*|\[[A-Fa-f0-9:]+\]):[0-9]{1,5}$"#,options:.regularExpression) != nil,
                  let port = Int(remote.split(separator:":").last ?? ""), (1...65535).contains(port) else { throw HarborError.message(L("Enter a destination such as 127.0.0.1:8080 or [::1]:8080.")) }
        }
    }
    var forwardArguments: [String] {
        switch kind {
        case .local: return ["-L","127.0.0.1:\(localPort):\(remote)"]
        case .remote: return ["-R","127.0.0.1:\(localPort):\(remote)"]
        case .dynamic: return ["-D","127.0.0.1:\(localPort)"]
        }
    }
    var arguments: [String] {
        ["-N","-a","-x","-o","ExitOnForwardFailure=yes"] + forwardArguments + connection.command().1
    }
    var summary: String {
        let listener = kind == .remote ? L("server 127.0.0.1") : L("Mac 127.0.0.1")
        return L("\(kind.title): \(listener):\(localPort) → \(kind == .dynamic ? L("SOCKS destinations") : remote) via \(connection.destination)")
    }
}

enum WorkspaceSession: Codable {
    case local(String?)
    case connection(Connection)
    case tunnel(TunnelDescriptor)
    func validate() throws {
        switch self {
        case .local(let path):
            if let path, !path.hasPrefix("/") || path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) {
                throw HarborError.message(L("Invalid saved local directory."))
            }
        case .connection(let c):
            try c.validate()
            guard ["SSH","SFTP","Serial"].contains(c.kind) else { throw HarborError.message(L("Only terminal connections can be restored.")) }
        case .tunnel(let tunnel): try tunnel.validate()
        }
    }
}

struct WorkspaceSnapshot: Codable {
    struct Pane: Codable { let id: UUID; let session: WorkspaceSession }
    struct Group: Codable { let layout: PaneLayoutSnapshot; let focused: UUID?; let panes: [Pane] }
    var version = 1
    let groups: [Group]
    let selected: UUID?
    func validate() throws {
        guard version == 1, groups.count <= 32 else { throw HarborError.message(L("Unsupported workspace format or too many groups.")) }
        var all = Set<UUID>()
        for group in groups {
            guard group.layout.valid() else { throw HarborError.message(L("Invalid workspace split layout.")) }
            let ids = group.layout.ids, panes = group.panes.map(\.id)
            guard !panes.isEmpty, ids.count <= 64, Set(ids).count == ids.count,
                  Set(panes).count == panes.count, Set(ids) == Set(panes),
                  group.focused == nil || ids.contains(group.focused!),
                  all.isDisjoint(with:ids) else { throw HarborError.message(L("Invalid or duplicated workspace panes.")) }
            all.formUnion(ids)
            for pane in group.panes { try pane.session.validate() }
        }
        guard all.count <= 64, selected == nil || all.contains(selected!) else { throw HarborError.message(L("Invalid workspace selection or too many panes.")) }
    }
    func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(self).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func load(from url: URL) throws -> WorkspaceSnapshot {
        let data = try Data(contentsOf:url)
        guard data.count <= 1_048_576 else { throw HarborError.message(L("Workspace file exceeds its size limit.")) }
        let value = try JSONDecoder().decode(Self.self,from:data); try value.validate(); return value
    }
}
