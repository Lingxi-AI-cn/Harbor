import AppKit
import Darwin
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let controller = AppController(); app.delegate = controller
var assertions = 0, failures = 0
func check(_ ok: @autoclosure () -> Bool,_ name: String) { assertions += 1; let passed = ok(); print("\(passed ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !passed { failures += 1 } }
func rejects(_ name: String,_ work: () throws -> Void) { do { try work(); check(false,name) } catch { check(true,name) } }
@discardableResult func until(_ seconds: Double = 5,_ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
    return condition()
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-productivity-test-\(UUID().uuidString)")
func runTests() {
 do {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    controller.store = try SessionStore(url:root.appendingPathComponent("sessions.json"))
    let store = try controller.p2Store()
    let c = Connection(name:"Test",host:"example.invalid",user:"tester")
    let old = TunnelDescriptor(connection:c,localPort:8080,remote:"127.0.0.1:80")
    let oldRoundtrip = try JSONDecoder().decode(TunnelDescriptor.self,from:JSONEncoder().encode(old))
    check(oldRoundtrip.kind == .local && oldRoundtrip.arguments.contains("127.0.0.1:8080:127.0.0.1:80"),"old local tunnel records preserve their meaning")
    for mode in TunnelMode.allCases {
        var d = old; d.mode = mode; try d.validate()
        let expected = mode == .local ? "-L" : mode == .remote ? "-R" : "-D"
        check(d.arguments.contains(expected) && d.arguments.contains("-a") && d.arguments.contains("-x"),"\(mode.rawValue) forwarding uses explicit mode and disables agent/X11 forwarding")
        if mode != .dynamic { d.remote = "[::1]:8080"; try d.validate(); check(d.forwardArguments.last!.contains("[::1]:8080"),"IPv6 destination supported for \(mode.rawValue)") }
    }
    var invalid = old; invalid.localPort = 0; rejects("zero listen port rejected") { try invalid.validate() }
    invalid = old; invalid.remote = "host:0"; rejects("zero target port rejected") { try invalid.validate() }
    invalid = old; invalid.remote = "host:22 -o ProxyCommand=x"; rejects("forwarding argument injection rejected") { try invalid.validate() }
    let profile = TunnelProfile(name:"Database",tunnel:old), snippet = CommandSnippet(name:"Status",text:"printf '中文测试\\n'")
    try store.update { $0.tunnels.append(profile); $0.snippets.append(snippet) }
    let restored = try ProductivityStore(url:store.url)
    check(restored.data.tunnels.first?.id == profile.id && restored.data.snippets.first?.text == snippet.text,"tunnels and Unicode snippets persist across store reload")
    let mode = try FileManager.default.attributesOfItem(atPath:store.url.path)[.posixPermissions] as? NSNumber
    check(mode?.intValue == 0o600,"productivity store is owner-only")
    let original = try Data(contentsOf:store.url)
    rejects("invalid snippet rejected before save") { try store.update { $0.snippets.append(CommandSnippet(name:"bad",text:"\u{1b}[31m")) } }
    check(store.data.snippets.count == 1 && (try? Data(contentsOf:store.url)) == original,"invalid edits preserve memory and file")
    rejects("duplicate profile identifiers rejected") { try store.update { $0.tunnels.append(profile) } }
    let bad = try ProductivityStore(url:root.appendingPathComponent("blocked")); try FileManager.default.createDirectory(at:bad.url,withIntermediateDirectories:false)
    rejects("disk write error reported") { try bad.update { $0.snippets.append(snippet) } }
    check(bad.data.snippets.isEmpty,"failed save does not mutate in-memory settings")
    rejects("oversized input rejected") { try InputDelivery.validate(String(repeating:"x",count:65537)) }
    rejects("NUL input rejected") { try InputDelivery.validate("bad\0input") }
    let echo = "stty -echo; printf 'READY\\n'; while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"
    var terminals = [TerminalTab]()
    for i in 0..<3 { terminals.append(controller.launch(title:"Receiver \(i)",executable:"/bin/sh",arguments:["-c",echo])!); controller.workspace.layoutSubtreeIfNeeded() }
    check(until { terminals.allSatisfy { $0.view.transcript()?.contains("READY") == true } },"three real terminal receivers become ready")
    let ids: Set<UUID> = [terminals[0].id,terminals[1].id]
    let sent = try InputDelivery.send("hello中文",submit:true,ids:ids,tabs:controller.tabs)
    check(sent == 2 && until { terminals[0].view.transcript()?.contains("GOT:hello中文") == true && terminals[1].view.transcript()?.contains("GOT:hello中文") == true },"broadcast sends Unicode text and Return to exactly the selected real terminals")
    if !(terminals[0].view.transcript()?.contains("GOT:hello中文") == true && terminals[1].view.transcript()?.contains("GOT:hello中文") == true) { print("RECEIVER TRANSCRIPTS: \(terminals.map { $0.view.transcript() ?? "nil" })") }
    check(terminals[2].view.transcript()?.contains("hello中文") == false,"unselected terminal receives no broadcast input")
    _ = try InputDelivery.send("draftonly",submit:false,ids:[terminals[0].id],tabs:controller.tabs)
    _ = until(0.2) { false }
    check(terminals[0].view.transcript()?.contains("GOT:draftonly") == false,"snippet insertion does not add Return")
    terminals[0].view.input("",submit:true)
    check(until { terminals[0].view.transcript()?.contains("GOT:draftonly") == true },"inserted draft executes only after a later Return")
    controller.closePane(terminals[1])
    rejects("stale target aborts the whole broadcast") { _ = try InputDelivery.send("MUST_NOT_SEND",submit:true,ids:ids,tabs:controller.tabs) }
    check(terminals[0].view.transcript()?.contains("MUST_NOT_SEND") == false,"surviving target receives no partial broadcast after preflight failure")
    terminals[2].tunnel = old
    rejects("tunnel terminal excluded from input delivery") { _ = try InputDelivery.send("test",submit:true,ids:[terminals[2].id],tabs:controller.tabs) }
    terminals[2].tunnel = nil
    rejects("no selected targets cannot send") { _ = try InputDelivery.send("test",submit:true,ids:[],tabs:controller.tabs) }
    let composer = BroadcastComposer(hostController:controller,text:"printf x")
    check(composer.targets.allSatisfy { $0.1.state == .off },"broadcast composer starts with no recipients selected")
    composer.targets.first?.1.state = .on; composer.refreshTargets()
    check(composer.targets.allSatisfy { $0.1.state == .off },"refreshing target list explicitly disarms all recipients")
    let log = root.appendingPathComponent("session space ' $ unicode 中.log")
    try SessionRecording.prepare(log)
    let pidFile = root.appendingPathComponent("recorded-child.pid")
    let recordCommand = "printf '%s' \"$$\" > \"$1\"; stty -echo; printf 'LOG_READY\\n'; IFS= read -r hidden; printf 'ACCEPTED中文\\n'; while IFS= read -r line; do printf 'OUT:%s\\n' \"$line\"; done"
    let recording = controller.launch(title:"Recording",executable:"/bin/sh",arguments:["-c",recordCommand,"harbor-test",pidFile.path],recordingURL:log)!
    check(until { recording.view.transcript()?.contains("LOG_READY") == true },"recorded terminal starts through script with exact quoted arguments")
    recording.view.input("NOT_ECHOED_SECRET",submit:true)
    check(until { ((try? String(contentsOf:log,encoding:.utf8)) ?? "").contains("ACCEPTED中文") },"recording flushes actual UTF-8 output while session remains live")
    check(((try? String(contentsOf:log,encoding:.utf8)) ?? "").contains("NOT_ECHOED_SECRET") == false,"script recording does not enable input logging when the application disables echo")
    check(recording.title.contains("REC") && recording.recordingURL == log,"recording has an explicit tab marker and owned log path")
    let logMode = try FileManager.default.attributesOfItem(atPath:log.path)[.posixPermissions] as? NSNumber
    check(logMode?.intValue == 0o600,"recorded transcript is owner-only")
    let beforeLog = try Data(contentsOf:log)
    rejects("existing log cannot be overwritten") { try SessionRecording.prepare(log) }
    check((try? Data(contentsOf:log)) == beforeLog,"existing log contents survive rejected overwrite")
    let childPID = Int32((try String(contentsOf:pidFile,encoding:.utf8)).trimmingCharacters(in:.whitespacesAndNewlines))!
    controller.closePane(recording)
    check(until { Darwin.kill(childPID,0) != 0 },"closing recorded terminal terminates its inner shell")
    check(FileManager.default.fileExists(atPath:log.path),"closing recorded terminal preserves the chosen log")
    let env = ProcessInfo.processInfo.environment
    if let config = env["HARBOR_P2_CONFIG"], let port = Int(env["HARBOR_P2_PORT"] ?? ""), let httpPort = env["HARBOR_P2_HTTP"] {
        let ports = env["HARBOR_P2_LISTEN"]!.split(separator:",").map { Int($0)! }
        let connection = Connection(name:"Disposable SSH",host:"127.0.0.1",user:env["HARBOR_P2_USER"]!,port:port,identity:env["HARBOR_P2_KEY"]!)
        func fetch(_ port: Int, socks: Bool = false) -> Bool {
            let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
            p.arguments = ["--silent","--max-time","3","--noproxy",socks ? "" : "*"] + (socks ? ["--socks5-hostname","127.0.0.1:\(port)"] : []) + ["http://127.0.0.1:\(socks ? httpPort : String(port))/"]
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return p.terminationStatus == 0 && String(decoding:data,as:UTF8.self) == "HARBOR_P2_FORWARD_OK" } catch { return false }
        }
        for (index,mode) in TunnelMode.allCases.enumerated() {
            var descriptor = TunnelDescriptor(connection:connection,localPort:ports[index],remote:"127.0.0.1:"+httpPort); descriptor.mode = mode
            let profile = TunnelProfile(name:"Probe \(mode.rawValue)",tunnel:descriptor)
            let tab = try controller.startTunnel(profile,configurationFile:config)
            let run = controller.managedTunnels[profile.id]!
            check(until(10) { run.forwarding || !run.active } && run.forwarding,"\(mode.rawValue) forwarding acknowledged by OpenSSH")
            check(fetch(ports[index],socks:mode == .dynamic),"\(mode.rawValue) passes actual HTTP traffic")
            rejects("duplicate active profile cannot start") { _ = try controller.startTunnel(profile,configurationFile:config) }
            run.stop()
            check(until { !controller.tabs.contains(where:{$0 === tab}) } && !run.active && !FileManager.default.fileExists(atPath:run.directory.path),"\(mode.rawValue) stop cleans terminal and private control socket")
            check(!fetch(ports[index],socks:mode == .dynamic),"\(mode.rawValue) listener no longer accepts traffic after stop")
        }
        let conflict = TunnelProfile(name:"Occupied port",tunnel:TunnelDescriptor(connection:connection,localPort:Int(httpPort)!,remote:"127.0.0.1:"+httpPort))
        let failedTab = try controller.startTunnel(conflict,configurationFile:config), failedRun = controller.managedTunnels[conflict.id]!
        check(until(10) { !failedRun.active } && failedRun.state.hasPrefix("Failed") && !failedRun.forwarding,"occupied listener is reported as failed, never active")
        check(until { !controller.tabs.contains(where:{$0 === failedTab}) },"failed forwarding closes its authentication terminal")
    }
    controller.tabs.forEach { $0.stopTerminal() }
 } catch { check(false,error.localizedDescription); controller.tabs.forEach { $0.stopTerminal() } }
 try? FileManager.default.removeItem(at:root)
 print("RESULT assertions=\(assertions) failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1)
}
// Explicit bootstrap: command-line AppKit runners may not receive the GUI launch event.
Timer.scheduledTimer(withTimeInterval:0.2,repeats:false) { _ in
    if controller.window == nil { controller.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification)) }
    runTests()
}
app.run()
