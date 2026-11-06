import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController(); app.delegate = controller
var failures = 0, assertions = 0
func check(_ condition: @autoclosure () -> Bool,_ name: String) { assertions += 1; let ok = condition(); print("\(ok ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !ok { failures += 1 } }
func rejects(_ name: String,_ work: () throws -> Void) { do { try work(); check(false,name) } catch { check(true,name) } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-sessions-test-\(UUID().uuidString)")
func config(_ args: [String]) throws -> String {
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath:"/usr/bin/ssh"); p.arguments = ["-G","-F","/dev/null"] + args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    check(p.terminationStatus == 0,"OpenSSH accepts generated arguments without connecting")
    return String(decoding:data,as:UTF8.self)
}
DispatchQueue.main.asyncAfter(deadline:.now()+1) {
 do {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let legacy = Data(#"[{"id":"12345678-1234-1234-1234-123456789abc","name":"Legacy","host":"example.invalid","user":"tester","port":22,"kind":"SSH","identity":"","x11":false}]"#.utf8)
    let old = try SessionArchive.decode(legacy).first!
    check(old.folder == nil && old.favorite == nil && old.jumpHosts == nil,"old saved-session schema remains readable")
    var c = old; c.folder = "Production/Databases"; c.favorite = true; c.jumpHosts = "alice@gateway.invalid:2200,bob@[::1]:2201"
    try c.validate()
    let decoded = try SessionArchive.decode(SessionArchive(connections:[c]).data()).first!
    check(decoded.folder == c.folder && decoded.favorite == true && decoded.jumpHosts == c.jumpHosts,"archive preserves folder favorite and ordered gateways")
    let effective = try config(c.command().1)
    check(effective.contains("proxyjump alice@gateway.invalid:2200,bob@[::1]:2201"),"OpenSSH resolves ordered multi-hop route")
    var sftp = c; sftp.kind = "SFTP"
    check(sftp.command().1.contains("-J") && sftp.command().1.contains("-P"),"interactive SFTP receives the same gateway chain")
    let files = try SSHFileSession(connection:c); defer { files.stop() }
    check(!files.slaveArguments.contains("-J") && files.slaveArguments.contains("ProxyCommand=/usr/bin/false"),"SFTP multiplex slave suppresses a second route and forbids fallback")
    let slave = try config(files.slaveArguments)
    check(slave.contains("proxycommand /usr/bin/false") && slave.contains("controlpath \(files.socket)"),"OpenSSH confirms slave uses exact private socket with fail-closed fallback")
    for route in ["-oProxyCommand=bad", "x;touch /tmp/bad", "host:0", "host:65536", "user@host,,other", "same,same", "user@[::1]:0"] {
        var bad = c; bad.jumpHosts = route; rejects("invalid gateway rejected: \(route)") { try bad.validate() }
    }
    var bad = c; bad.folder = "a/../b"; rejects("invalid folder path rejected") { try bad.validate() }
    bad = c; bad.kind = "RDP"; rejects("unsupported RDP gateway cannot be silently ignored") { try bad.validate() }
    var unsupported = SessionArchive(connections:[c]); unsupported.version = 99
    rejects("unknown import version rejected") { _ = try SessionArchive.decode(unsupported.data()) }
    let store = try SessionStore(url:root.appendingPathComponent("sessions.json")); store.connections = [c]; try store.save()
    _ = try store.importCopies([c,c])
    check(store.connections.count == 3 && Set(store.connections.map(\.id)).count == 3,"import assigns new identifiers without replacing existing sessions")
    check(store.connections.map(\.name) == ["Legacy","Legacy (2)","Legacy (3)"],"import deterministically resolves name collisions within folder")
    let before = try Data(contentsOf:store.url)
    var invalid = c; invalid.port = -1
    rejects("invalid import rejected as a whole") { _ = try store.importCopies([c,invalid]) }
    check(store.connections.count == 3 && (try? Data(contentsOf:store.url)) == before,"invalid import leaves memory and disk unchanged")
    let failing = try SessionStore(url:root.appendingPathComponent("bad.json")); try FileManager.default.createDirectory(at:failing.url,withIntermediateDirectories:false)
    rejects("failed persistence returns import error") { _ = try failing.importCopies([c]) }
    check(failing.connections.isEmpty,"failed persistence rolls back imported sessions")
    for i in 0..<35 { var recent = c; recent.id = UUID(); recent.name = "Recent \(i)"; try store.recordOpened(recent) }
    check(store.recent.count == 30 && store.recent.first?.connection.name == "Recent 34","recent history includes unsaved sessions and retains newest 30")
    let latest = store.recent[0].connection; try store.recordOpened(latest)
    check(store.recent.count == 30 && store.recent.filter({$0.connection.id == latest.id}).count == 1,"reopening session updates recency without duplicate identifiers")
    let loaded = try SessionStore(url:store.url)
    check(loaded.recent.count == 30 && loaded.connections.count == 3,"saved sessions and recent history survive reopening")
    let mode = try FileManager.default.attributesOfItem(atPath:store.recentURL.path)[.posixPermissions] as? NSNumber
    check(mode?.intValue == 0o600,"recent connection file has owner-only permissions")
    let parsed = try SSHConfigImport.parse("""
    Host production prod-copy
      HostName db.example.invalid
      User alice
      Port=2222
      IdentityFile "~/keys/key with spaces"
    Host * !excluded
      Compression yes
      Port 22
    Host excluded
      HostName localhost
    """)
    check(parsed.connections.count == 3,"SSH config imports multiple literal aliases")
    check(parsed.connections[0].port == 2222 && parsed.connections[0].compression == true,"first value wins and wildcard defaults apply")
    check(parsed.connections[2].compression == false,"negated Host pattern excludes wildcard defaults")
    check(parsed.connections[0].identity == "~/keys/key with spaces" && parsed.connections[0].isolatedSSHConfig == true,"quoted key path preserved and imported config isolated")
    let danger = try SSHConfigImport.parse("Host danger\n HostName example.invalid\n ProxyCommand touch /tmp/never-execute")
    check(danger.connections.isEmpty && !danger.warnings.isEmpty,"ProxyCommand is reported and skipped without executing")
    rejects("Match exec is not executed") { _ = try SSHConfigImport.parse("Host x\n Match exec \"touch /tmp/never-execute\"\n User root") }
    rejects("Include is not silently ignored") { _ = try SSHConfigImport.parse("Include other.conf\nHost x") }
    let gatewayAlias = try SSHConfigImport.parse("Host app\n ProxyJump gateway\nHost gateway\n HostName jump.example.invalid\n IdentityFile ~/key")
    check(!gatewayAlias.connections.contains(where:{$0.name == "app"}),"gateway alias with separate settings requires explicit review instead of losing key/route")
    check(ConnectionDiagnostics.explanation("Permission denied (publickey).").contains("Authentication failed"),"diagnostics classify authentication failure")
    check(ConnectionDiagnostics.explanation("channel 0: open failed: administratively prohibited").contains("gateway rejected"),"diagnostics identify forwarding policy failure")
    check(ConnectionDiagnostics.explanation("Connection closed").contains("does not establish"),"unknown failures are not assigned an invented cause")
    controller.store = store; controller.workspace.refreshSessions(); controller.workspace.layoutSubtreeIfNeeded()
    check(controller.workspace.connectionButtons.count == 5,"nested folders render alongside saved session rows")
    controller.workspace.collapsedFolders.insert("Production"); controller.workspace.refreshSessions()
    check(controller.workspace.connectionButtons.count == 1,"collapsing parent hides descendants")
    controller.workspace.search.stringValue = "Legacy (2)"; controller.workspace.refreshSessions()
    check(controller.workspace.connectionButtons.count == 3,"search reveals matching session through collapsed folders")
    controller.workspace.search.stringValue = ""; controller.workspace.sessionScope.selectItem(at:1); controller.workspace.collapsedFolders = []; controller.workspace.refreshSessions()
    check(controller.workspace.connectionButtons.count == 5,"favorites retain their folder hierarchy")
    controller.workspace.sessionScope.selectItem(at:2); controller.workspace.refreshSessions(); controller.workspace.layoutSubtreeIfNeeded()
    check(controller.workspace.connectionButtons.count == 30 && controller.workspace.sessionDocument.frame.height > controller.workspace.sessionScroll.contentSize.height,"recent connections are ordered and scroll independently of local tools")
    for style in [NSScroller.Style.legacy,.overlay] {
        controller.workspace.sessionScroll.scrollerStyle = style
        controller.workspace.needsLayout = true; controller.workspace.layoutSubtreeIfNeeded()
        check(controller.workspace.connectionButtons.allSatisfy { $0.frame.maxX <= controller.workspace.sessionScroll.contentSize.width },"session rows fit visible width with \(style == .legacy ? "legacy" : "overlay") scrollers")
    }
    let editor = ConnectionEditor(owner:controller,kind:"SSH",existing:c)
    check(editor.folder.stringValue == c.folder && editor.gateways.stringValue == c.jumpHosts && editor.favorite.state == .on,"editor loads all P1 metadata")
    check(!editor.save.isEnabled && editor.window.contentView!.bounds.height == 710,"editing always saves and expanded form fits controls")
 } catch { check(false,error.localizedDescription) }
 print("RESULT assertions=\(assertions) failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1)
}
app.run()
