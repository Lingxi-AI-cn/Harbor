import AppKit

struct RecentConnection: Codable {
    var connection: Connection
    var openedAt: Date
}

enum SessionRules {
    static func validateMetadata(_ c: Connection) throws {
        for value in [c.name,c.folder ?? "",c.identity] {
            guard value.utf8.count <= 4096, !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw HarborError.message(L("Session fields contain control characters or exceed 4096 bytes.")) }
        }
        let folder = c.folder ?? ""
        guard folder.isEmpty || (folder.split(separator:"/").count <= 12 && !folder.hasPrefix("/") && !folder.hasSuffix("/") && folder.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })) else { throw HarborError.message(L("Use folder names such as Production/Databases, without empty, . or .. components.")) }
        let route = c.jumpHosts ?? ""
        guard route.isEmpty || ["SSH","SFTP"].contains(c.kind) else { throw HarborError.message(L("SSH gateways currently apply to SSH and SFTP sessions.")) }
        _ = try hops(route)
    }
    static func hops(_ text: String) throws -> [String] {
        if text.isEmpty { return [] }
        let values = text.split(separator:",",omittingEmptySubsequences:false).map(String.init)
        guard values.count <= 8, values.allSatisfy({ $0.range(of:#"^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?(?:[A-Za-z0-9_][A-Za-z0-9_.-]*|\[[A-Fa-f0-9:]+\])(?::[0-9]{1,5})?$"#,options:.regularExpression) != nil }) else { throw HarborError.message(L("Use up to 8 gateways: user@host:port,user@next:port. IPv6 addresses need brackets. Keys for gateways can be configured in ~/.ssh/config.")) }
        for value in values {
            let host = String(value.split(separator:"@").last!)
            let port: String?
            if host.hasPrefix("[") { port = host.range(of:"]:").map { String(host[$0.upperBound...]) } }
            else { port = host.contains(":") ? String(host.split(separator:":").last!) : nil }
            if let port { guard let n = Int(port), (1...65535).contains(n) else { throw HarborError.message(L("Gateway port must be between 1 and 65535.")) } }
        }
        guard Set(values).count == values.count else { throw HarborError.message(L("The gateway chain repeats the same hop.")) }
        return values
    }
    static func route(_ c: Connection) -> String {
        if c.kind == "Serial" { return c.serial?.summary ?? c.host }
        if ["RDP","VNC"].contains(c.kind), let gateway=c.desktop?.gateway { return route(gateway.connection)+" → "+DesktopConfiguration.address(c.host,c.port) }
        return ((try? hops(c.jumpHosts ?? "")) ?? []).appending(c.destination + ":\(c.port)").joined(separator:" → ")
    }
}
private extension Array { func appending(_ item: Element) -> [Element] { self + [item] } }

struct SessionArchive: Codable {
    var format = "harbor-sessions"
    var version = 1
    var connections: [Connection]
    static func decode(_ data: Data) throws -> [Connection] {
        guard data.count <= 4_194_304 else { throw HarborError.message(L("Session import exceeds 4 MiB.")) }
        let decoder = JSONDecoder()
        let values: [Connection]
        if let legacy = try? decoder.decode([Connection].self,from:data) { values = legacy }
        else {
            let archive = try decoder.decode(Self.self,from:data)
            guard archive.format == "harbor-sessions", archive.version == 1 else { throw HarborError.message(L("Unsupported session archive version.")) }
            values = archive.connections
        }
        guard values.count <= 2000 else { throw HarborError.message(L("Import at most 2000 sessions at a time.")) }
        for c in values { try c.validate(checkIdentity:false) }
        return values
    }
    func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(self)
    }
}

extension SessionStore {
    func recordOpened(_ c: Connection) throws {
        let before = recent
        recent.removeAll { $0.connection.id == c.id }
        recent.insert(RecentConnection(connection:c,openedAt:Date()),at:0)
        recent = Array(recent.prefix(30))
        do {
            try FileManager.default.createDirectory(at:recentURL.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONEncoder().encode(recent).write(to:recentURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:recentURL.path)
        } catch { recent = before; throw error }
    }
    func importCopies(_ values: [Connection]) throws -> Int {
        for c in values { try c.validate(checkIdentity:false) }
        let before = connections
        var names = Set(connections.map { ($0.folder ?? "") + "\u{1f}" + $0.name })
        for var c in values {
            try c.validate(checkIdentity:false)
            c.id = UUID()
            let base = c.name; var n = 2
            while names.contains((c.folder ?? "") + "\u{1f}" + c.name) { c.name = "\(base) (\(n))"; n += 1 }
            names.insert((c.folder ?? "") + "\u{1f}" + c.name); connections.append(c)
        }
        do { try save() } catch { connections = before; throw error }
        return values.count
    }
}

/// Declarative import only: never runs ssh, shell commands, Match exec or ProxyCommand.
/// Unsupported routing/conditional configuration fails closed instead of importing a direct connection.
enum SSHConfigImport {
    struct Result { var connections: [Connection]; var warnings: [String] }
    struct Directive { var key: String; var values: [String]; var patterns: [String] }
    static func tokens(_ line: String) throws -> [String] {
        var out = [String](), token = "", quoted = false, escape = false
        for ch in line {
            if escape { token.append(ch); escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { quoted.toggle(); continue }
            if ch == "#" && !quoted { break }
            if !quoted && (ch.isWhitespace || (ch == "=" && out.isEmpty)) {
                if !token.isEmpty { out.append(token); token = "" }
            } else { token.append(ch) }
        }
        guard !quoted && !escape else { throw HarborError.message(L("Unterminated quoting in SSH config.")) }
        if !token.isEmpty { out.append(token) }; return out
    }
    static func matches(_ alias: String,_ patterns: [String]) -> Bool {
        func match(_ pattern: String) -> Bool {
            let regex = "^" + NSRegularExpression.escapedPattern(for:pattern).replacingOccurrences(of:"\\*",with:".*").replacingOccurrences(of:"\\?",with:".") + "$"
            return alias.range(of:regex,options:.regularExpression) != nil
        }
        if patterns.contains(where:{ $0.hasPrefix("!") && match(String($0.dropFirst())) }) { return false }
        return patterns.contains { !$0.hasPrefix("!") && match($0) }
    }
    static func parse(_ text: String) throws -> Result {
        guard text.utf8.count <= 1_048_576 else { throw HarborError.message(L("SSH config exceeds 1 MiB.")) }
        var directives = [Directive](), patterns = ["*"], aliases = [String](), warnings = [String]()
        for (index,line) in text.components(separatedBy:.newlines).enumerated() {
            let tokens = try tokens(line); guard let first = tokens.first else { continue }
            let key = first.lowercased(), values = Array(tokens.dropFirst())
            guard !values.isEmpty else { throw HarborError.message(L("Missing value at SSH config line \(index+1).")) }
            if ["include","match"].contains(key) { throw HarborError.message(L("SSH config contains \(first) at line \(index+1). Import a flattened Host-only file; conditional rules and external files are not executed or silently ignored.")) }
            if key == "host" {
                patterns = values
                for a in values where !a.contains("*") && !a.contains("?") && !a.hasPrefix("!") && !aliases.contains(a) { aliases.append(a) }
            } else { directives.append(Directive(key:key,values:values,patterns:patterns)) }
        }
        guard aliases.count <= 2000 else { throw HarborError.message(L("Too many SSH aliases.")) }
        func settings(_ alias: String) -> [String:[String]] {
            var result = [String:[String]]()
            for d in directives where matches(alias,d.patterns) && result[d.key] == nil { result[d.key] = d.values }
            return result
        }
        let supported: Set<String> = ["hostname","user","port","identityfile","proxyjump","forwardagent","compression","forwardx11","serveraliveinterval"]
        var result = [Connection]()
        for alias in aliases {
            let fields = settings(alias)
            let unsupported = fields.keys.filter { !supported.contains($0) }.sorted()
            if !unsupported.isEmpty { warnings.append(L("\(alias): skipped (unsupported: \(unsupported.joined(separator:", ")))")); continue }
            func one(_ key: String) -> String? { fields[key]?.first }
            do {
                var c = Connection(name:alias,host:one("hostname") ?? alias,user:one("user") ?? "",port:Int(one("port") ?? "22") ?? 0)
                guard !fields.values.contains(where:{$0.count != 1}) else { throw HarborError.message(L("multiple directive values are not supported")) }
                c.folder = L("Imported SSH"); c.isolatedSSHConfig = true
                c.identity = one("identityfile") ?? ""
                guard !c.identity.contains("%"), !c.identity.contains("${"), !c.identity.hasPrefix("none") else { throw HarborError.message(L("IdentityFile tokens/none require manual review")) }
                for key in ["forwardagent","compression","forwardx11"] {
                    if let value = one(key), !["yes","no"].contains(value) { throw HarborError.message(L("unsupported \(key) value")) }
                }
                if directives.filter({$0.key == "identityfile" && matches(alias,$0.patterns)}).count > 1 { throw HarborError.message(L("multiple IdentityFile entries require manual review")) }
                c.forwardAgent = one("forwardagent") == "yes"; c.compression = one("compression") == "yes"; c.x11 = one("forwardx11") == "yes"
                if let interval = one("serveraliveinterval"), interval != "0" {
                    guard interval == String(HarborDefaults.sshKeepAliveSeconds) else { throw HarborError.message(L("custom ServerAliveInterval requires manual review")) }
                    c.keepAlive = true
                }
                if let jumps = one("proxyjump"), jumps.lowercased() != "none" {
                    let hops = try SessionRules.hops(jumps)
                    // Literal routes only. A hop alias may carry key/Match/proxy settings; don't silently flatten those away.
                    guard !hops.contains(where:{ hop in
                        let host = String(hop.split(separator:"@").last!).split(separator:":").first.map(String.init) ?? ""
                        return aliases.contains(host)
                    }) else { throw HarborError.message(L("ProxyJump references an alias; enter its verified route and gateway key configuration manually")) }
                    c.jumpHosts = jumps
                }
                try c.validate(checkIdentity:false)
                if !c.identity.isEmpty && !FileManager.default.fileExists(atPath:(c.identity as NSString).expandingTildeInPath) { warnings.append(L("\(alias): private key path is missing on this Mac; select it before connecting")) }
                result.append(c)
            } catch { warnings.append(L("\(alias): skipped (\(error.localizedDescription))")) }
        }
        if result.isEmpty { warnings.append(L("No supported literal Host entries were found.")) }
        return Result(connections:result,warnings:warnings)
    }
}

extension AppController {
    func sessionContextMenu(_ c: Connection) -> NSMenu {
        let menu = NSMenu()
        for (title,action) in [(L("Edit session…"),#selector(editSessionRecord(_:))),(L("Duplicate session…"),#selector(duplicateSession(_:))),(c.favorite == true ? L("Remove favorite") : L("Add favorite"),#selector(toggleFavorite(_:))),(L("Export this session…"),#selector(exportSession(_:)))] {
            let item = menu.addItem(withTitle:title,action:action,keyEquivalent:""); item.target = self; item.representedObject = c
        }
        if store.connections.contains(where:{$0.id == c.id}) {
            let item = menu.addItem(withTitle:L("Delete saved session…"),action:#selector(deleteSaved(_:)),keyEquivalent:""); item.target = self; item.representedObject = c.id.uuidString
        }
        return menu
    }
    @objc func editSessionRecord(_ item: NSMenuItem) { if let c = item.representedObject as? Connection { showConnection(kind:c.kind,existing:c) } }
    @objc func duplicateSession(_ item: NSMenuItem) {
        guard var c = item.representedObject as? Connection else { return }
        c.id = UUID(); c.name += L(" copy"); showConnection(kind:c.kind,existing:c)
    }
    @objc func toggleFavorite(_ item: NSMenuItem) {
        guard var c = item.representedObject as? Connection else { return }
        c.favorite = c.favorite != true
        do { try saveConnection(c) } catch { showError(error) }
    }
    func recordRecent(_ c: Connection) {
        do { try store.recordOpened(c); workspace.refreshSessions() }
        catch { showError(HarborError.message(L("The connection opened, but recent history could not be saved: \(error.localizedDescription)"))) }
    }
    @objc func clearRecentConnections() {
        let alert = NSAlert(); alert.messageText = L("Clear recent connections?"); alert.informativeText = L("Saved sessions and open terminals are kept.")
        alert.addButton(withTitle:L("Clear history")); alert.addButton(withTitle:L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if FileManager.default.fileExists(atPath:store.recentURL.path) { try FileManager.default.removeItem(at:store.recentURL) }
            store.recent = []; workspace.refreshSessions()
        } catch { showError(error) }
    }
    static func textArea(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:620,height:330)); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        let view = NSTextView(frame:NSRect(x:0,y:0,width:600,height:330))
        view.isEditable = false; view.isSelectable = true; view.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.string = text; scroll.documentView = view
        return scroll
    }
    @objc func importSessions() { chooseImport(ssh:false) }
    @objc func importSSHConfig() { chooseImport(ssh:true) }
    @objc func importMobaSessions() { chooseImport(ssh:false,moba:true) }
    func chooseImport(ssh: Bool, moba: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = moba ? L("Choose MobaXterm.ini, .mxtsessions or .moba. Preview supported bookmarks before importing.") : ssh ? L("Choose a declarative OpenSSH config. Import does not connect or execute commands.") : L("Choose a Harbor JSON session archive. Existing sessions are preserved.")
        if ssh { panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size <= 4_194_304 else { throw HarborError.message(L("Import file exceeds 4 MiB.")) }
            let data = try Data(contentsOf:url)
            let values: [Connection], warnings: [String]
            if moba {
                let result = try MobaSessionImport.parse(data); values = result.connections; warnings = result.warnings
            } else if ssh {
                guard let text = String(data:data,encoding:.utf8) else { throw HarborError.message(L("SSH config must be UTF-8 text.")) }
                let result = try SSHConfigImport.parse(text); values = result.connections; warnings = result.warnings
            } else { values = try SessionArchive.decode(data); warnings = [] }
            let alert = NSAlert(); alert.messageText = L("Import \(values.count) sessions?")
            alert.informativeText = L("Import creates new saved sessions only. Name conflicts receive a numeric suffix. No connection will be opened. Key files are referenced, not copied.")
            let lines = values.map { L("\($0.folder ?? L("Ungrouped")) / \($0.name)\n  \($0.kind): \(SessionRules.route($0))\n  Key: \($0.identity.isEmpty ? L("SSH default") : $0.identity)") }
            alert.accessoryView = Self.textArea((lines + (warnings.isEmpty ? [] : [L("\nIMPORT NOTES")] + warnings)).joined(separator:"\n"))
            alert.addButton(withTitle:L("Import")); alert.addButton(withTitle:L("Cancel")); alert.buttons[0].isEnabled = !values.isEmpty
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try store.importCopies(values); workspace.refreshSessions()
        } catch { showError(error) }
    }
    @objc func exportSessions() { exportConnections(store.connections) }
    @objc func exportSession(_ item: NSMenuItem) { if let c = item.representedObject as? Connection { exportConnections([c]) } }
    func exportConnections(_ values: [Connection]) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Harbor-sessions.json"
        panel.message = L("Exports connection settings and private-key paths, not key contents, passwords, recent history or terminal output.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SessionArchive(connections:values).data().write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        } catch { showError(error) }
    }
    @objc func renameSessionFolder(_ item: NSMenuItem) {
        guard let old = item.representedObject as? String else { return }
        let alert = NSAlert(); alert.messageText = L("Rename or move folder")
        let field = NSTextField(frame:NSRect(x:0,y:0,width:400,height:28)); field.stringValue = old
        alert.accessoryView = field; alert.addButton(withTitle:L("Save")); alert.addButton(withTitle:L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines), before = store.connections
        do {
            guard !new.isEmpty else { throw HarborError.message(L("Enter a folder path.")) }
            var changed = before
            for i in changed.indices {
                let folder = changed[i].folder ?? ""
                if folder == old || folder.hasPrefix(old + "/") { changed[i].folder = new + folder.dropFirst(old.count); try SessionRules.validateMetadata(changed[i]) }
            }
            store.connections = changed
            do { try store.save() } catch { store.connections = before; throw error }
            workspace.refreshSessions()
        } catch { showError(error) }
    }
    @objc func connectionDiagnostics() {
        guard tabs.indices.contains(selected), let c = tabs[selected].connection, ["SSH","SFTP"].contains(c.kind) else { showError(HarborError.message(L("Select an SSH or SFTP terminal first."))); return }
        let tab = tabs[selected]
        while true {
            let text = ConnectionDiagnostics.report(c,tab:tab)
            let alert = NSAlert(); alert.messageText = L("Connection diagnostics")
            alert.informativeText = L("A diagnostic reconnect opens a separate SSH session and records OpenSSH verbose messages locally. It does not close this session. Authentication stays in the terminal.")
            alert.accessoryView = Self.textArea(text)
            alert.addButton(withTitle:L("Close")); alert.addButton(withTitle:L("Refresh")); alert.addButton(withTitle:L("Reconnect with diagnostics"))
            alert.buttons[2].isEnabled = c.kind == "SSH"
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { continue }
            if response == .alertThirdButtonReturn { launchDiagnosticConnection(c) }
            break
        }
    }
    func launchDiagnosticConnection(_ c: Connection) {
        var directory: URL?
        do {
            try c.validate()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-diagnostics-\(UUID().uuidString)")
            directory = root
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let log = root.appendingPathComponent("ssh.log")
            guard FileManager.default.createFile(atPath:log.path,contents:Data(),attributes:[.posixPermissions:0o600]) else { throw HarborError.message(L("Cannot create diagnostic log.")) }
            let command = c.command()
            guard let tab = launch(title:L("Diagnostics · ") + c.name,executable:command.0,arguments:["-v","-E",log.path] + command.1,connection:c,browseRemoteFiles:true) else { try? FileManager.default.removeItem(at:root); return }
            tab.diagnosticDirectory = root
            tab.view.notice(L("\r\nOpen Session → Connection diagnostics to read this connection's OpenSSH log.\r\n"))
            workspace.status.stringValue = L("● Diagnostic SSH · Session → Connection diagnostics")
            workspace.status.toolTip = L("OpenSSH errors are recorded locally. Open Session → Connection diagnostics to inspect and refresh.")
        } catch { if let directory { try? FileManager.default.removeItem(at:directory) }; showError(error) }
    }
}

enum ConnectionDiagnostics {
    static func explanation(_ text: String) -> String {
        let text = text.lowercased()
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") { return L("Host-key verification failed. Verify the server identity before updating known_hosts.") }
        if text.contains("permission denied") || text.contains("no more authentication methods") { return L("Authentication failed. Check the username, key and server authorization; with gateways, inspect which hop reported the error.") }
        if text.contains("could not resolve hostname") { return L("A target or gateway hostname could not be resolved.") }
        if text.contains("connection refused") { return L("A host refused the connection. Check its SSH port and listener.") }
        if text.contains("timed out") || text.contains("no route to host") { return L("A target or gateway is unreachable or timed out. Check routing and firewall access.") }
        if text.contains("administratively prohibited") { return L("The gateway rejected forwarding. Check its AllowTcpForwarding / PermitOpen policy.") }
        return L("No recognized failure signature. Read the OpenSSH messages below; a closed connection alone does not establish the cause.")
    }
    static func report(_ c: Connection,tab: TerminalTab) -> String {
        var report = L("Protocol: \(c.kind)\nRoute: \(SessionRules.route(c))\nTarget key: \(c.identity.isEmpty ? L("SSH defaults/agent") : c.identity)\nGateway keys: \(c.isolatedSSHConfig == true ? L("default key locations (isolated config)") : L("~/.ssh/config or SSH defaults"))\nSSH configuration: \(c.isolatedSSHConfig == true ? L("isolated imported settings (-F /dev/null)") : L("system and user config also apply"))\nProcess: \(tab.running ? L("running (authentication not implied)") : L("ended"))\nSFTP socket: \(tab.remoteFiles?.authenticated == true ? L("available") : L("not available"))\n")
        guard let root = tab.diagnosticDirectory else { return report + L("\nThis is a normal connection. Actual OpenSSH errors remain in the terminal. Use Reconnect with diagnostics for a separate session with a local diagnostic log.") }
        let file = root.appendingPathComponent("ssh.log")
        let text: String
        if let handle = try? FileHandle(forReadingFrom:file) {
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset:end > 262144 ? end-262144 : 0)
            text = String(decoding:(try? handle.read(upToCount:262144)) ?? Data(),as:UTF8.self)
        } else { text = L("Diagnostic log is unavailable.") }
        report += L("\nAssessment: ") + explanation(text) + L("\n\nOpenSSH log (last 256 KiB; removed when this tab closes):\n") + text
        return report
    }
}

/// Reads declarative bookmark records only; no passwords, macros or commands are executed.
enum MobaSessionImport {
    static func decode(_ value: String) -> String {
        var result = value
        for (a,b) in [("__PIPE__","|"),("__PTVIRG__",";"),("__DBLQUO__","\""),("__DIEZE__","#"),("__PERCENT__","%")] { result = result.replacingOccurrences(of:a,with:b) }
        return result
    }
    static func parse(_ data: Data) throws -> (connections:[Connection],warnings:[String]) {
        guard data.count <= 4_194_304, let text = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.windowsCP1252), !text.contains("\0") else { throw HarborError.message(L("Choose a UTF-8 or Windows-1252 MobaXterm session export, up to 4 MiB.")) }
        var result = [Connection](), warnings = [String](), folder = "", section = "", records = 0
        // Folder metadata is scoped to its section even when SubRep follows records.
        let lines = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\u{feff}",with:"").components(separatedBy:"\n")
        var folders = [String:String](), current = ""
        for line in lines {
            let s = line.trimmingCharacters(in:.whitespaces)
            if s.hasPrefix("["), s.hasSuffix("]") { current = String(s.dropFirst().dropLast()) }
            else if s.hasPrefix("SubRep=") { folders[current] = decode(String(s.dropFirst(7))).replacingOccurrences(of:"\\",with:"/") }
        }
        for (index,line) in lines.enumerated() {
            let s = line.trimmingCharacters(in:.whitespaces)
            if s.hasPrefix("["), s.hasSuffix("]") { section = String(s.dropFirst().dropLast()); folder = folders[section] ?? ""; continue }
            guard section.isEmpty || section == "Bookmarks" || section.range(of:#"^Bookmarks_[0-9]+$"#,options:.regularExpression) != nil else { continue }
            guard !s.isEmpty, !s.hasPrefix(";"), let equal = s.firstIndex(of:"=") else { continue }
            let name = decode(String(s[..<equal])), raw = String(s[s.index(after:equal)...]).trimmingCharacters(in:.whitespaces)
            if name == "SubRep" || name == "ImgNum" { continue }
            records += 1
            guard records <= 2000 else { throw HarborError.message(L("Import at most 2000 bookmarks.")) }
            do {
                let groups = raw.components(separatedBy:"#")
                guard groups.count >= 3, Int(groups[1]) != nil else { throw HarborError.message(L("Malformed bookmark.")) }
                let f = groups[2].components(separatedBy:"%").map(decode)
                func field(_ n:Int) -> String { f.indices.contains(n) ? f[n] : "" }
                func inactive(_ n:Int) -> Bool { field(n).isEmpty || field(n) == "0" }
                guard let kind = ["0":"SSH","4":"RDP","5":"VNC","7":"SFTP"][field(0)], f.count >= 4, let port = Int(field(2)) else { throw HarborError.message(L("Unsupported protocol or invalid endpoint.")) }
                var c = Connection(name:name,host:field(1),user:kind == "VNC" ? "" : field(3),port:port,kind:kind)
                c.folder = folder.isEmpty ? nil : folder; c.forwardAgent = false; c.isolatedSSHConfig = true
                if c.user == "<default>" { c.user = ""; warnings.append(L("Line \(index+1): default Windows username must be reviewed on this Mac.")) }
                let keyIndex = kind == "SSH" ? 14 : kind == "SFTP" ? 9 : -1
                if keyIndex >= 0, !field(keyIndex).isEmpty {
                    guard field(keyIndex).hasPrefix("/") || field(keyIndex).hasPrefix("~/") else { throw HarborError.message(L("Windows private-key path requires manual relocation; bookmark skipped.")) }
                    c.identity = field(keyIndex)
                }
                if kind == "SSH" {
                    guard inactive(19), field(20).isEmpty, field(26).isEmpty, field(7).isEmpty, inactive(13), field(15).replacingOccurrences(of:"|",with:"").isEmpty else { throw HarborError.message(L("Proxy, login command, desktop environment or gateway key needs manual migration.")) }
                    guard field(27) != "2", [28,29,30,35,36].allSatisfy({ field($0).isEmpty }) else { throw HarborError.message(L("Custom SSH algorithms/certificates require manual migration.")) }
                    c.x11 = field(5) == "-1"; c.compression = field(6) == "-1"; c.forwardAgent = field(34) == "-1"
                    if !field(8).isEmpty {
                        let hosts = field(8).components(separatedBy:"|"), ports = field(9).components(separatedBy:"|"), users = field(10).components(separatedBy:"|")
                        guard hosts.count == ports.count, hosts.count == users.count else { throw HarborError.message(L("Gateway list lengths do not match.")) }
                        var hops = [String]()
                        for i in hosts.indices {
                            let user = users[i].isEmpty ? "" : users[i]+"@"
                            let host = hosts[i].contains(":") ? "[\(hosts[i])]" : hosts[i]
                            hops.append(user + host + ":" + ports[i])
                        }
                        c.jumpHosts = hops.joined(separator:",")
                    } else if !field(9).isEmpty || !field(10).isEmpty { throw HarborError.message(L("Incomplete gateway settings.")) }
                } else if kind == "SFTP" {
                    guard inactive(10), field(11).isEmpty, inactive(7) else { throw HarborError.message(L("SFTP proxy or ASCII transfer mode requires manual migration.")) }
                } else if kind == "RDP" {
                    guard field(12).isEmpty, field(13).isEmpty, field(14).isEmpty, field(15).isEmpty, field(18).isEmpty, field(20).isEmpty, field(31).isEmpty else { throw HarborError.message(L("RDP gateway, command or expert settings require manual migration.")) }
                    c.desktop = DesktopSettings(); c.desktop?.clipboard = field(19) == "-1"
                } else {
                    guard inactive(4), field(5).isEmpty, field(6).isEmpty, field(7).isEmpty, field(8).isEmpty, inactive(11), field(12).isEmpty, inactive(13), field(14).isEmpty else { throw HarborError.message(L("VNC gateway, view-only, SSL, Unix login or proxy requires manual migration.")) }
                    c.desktop = DesktopSettings()
                }
                try c.validate(checkIdentity:false); result.append(c)
            } catch { warnings.append(L("Line \(index+1) · \(name.prefix(100)): \(error.localizedDescription)")) }
        }
        warnings.insert(L("Imports supported connection settings only. Passwords, original macros, appearance, global defaults and startup folders are not migrated. Review imported settings before connecting."),at:0)
        return (result,warnings)
    }
}
