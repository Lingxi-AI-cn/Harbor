import AppKit
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let controller = AppController(); app.delegate = controller
var failures = 0
func check(_ ok: Bool,_ name: String) { print("\(ok ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !ok { failures += 1 } }
func wait(_ seconds: Double,_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.025)) }
    return condition()
}
func perform<T>(_ session: SSHFileSession,_ body: @escaping (SFTPClient) throws -> T) throws -> T {
    var result: Result<T,Error>?
    session.perform(timeout:20,body) { result = $0 }
    guard wait(25,{ result != nil }) else { throw HarborError.message("Remote test operation timed out.") }
    return try result!.get()
}
func run(_ executable: String,_ arguments: [String],timeout: Double = 10) throws -> (Int32,String) {
    let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline:.now()+timeout,execute:watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); watchdog.cancel()
    return (process.terminationStatus,String(decoding:data,as:UTF8.self))
}
func terminal(_ view: NSView) -> GhosttyTerminalView? { if let view = view as? GhosttyTerminalView { return view }; return view.subviews.compactMap(terminal).first }
let out = URL(fileURLWithPath:CommandLine.arguments[1]); try! FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
var record: [String:Any] = [:]
Timer.scheduledTimer(withTimeInterval:1,repeats:false) { _ in
    do {
        guard var connection = controller.store.connections.first(where:{$0.name == "Legion_Ext"}) else { throw HarborError.message("Legion_Ext is missing") }
        controller.connect(connection)
        guard wait(45,{controller.tabs.first?.remoteFilesReady == true}), let anchor = controller.tabs.first?.remoteFiles else { throw HarborError.message("SSH anchor did not authenticate") }
        let sshArgs = ["-S",anchor.socket,"-o","BatchMode=yes","-o","ProxyCommand=/usr/bin/false","-T"] + connection.command().1 + [#"python3 -c 'import os; print(os.environ["SSH_CONNECTION"].split()[-1])'"#]
        let portResult = try run("/usr/bin/ssh",sshArgs)
        guard portResult.0 == 0, let serverPort = Int(portResult.1.trimmingCharacters(in:.whitespacesAndNewlines)), (1...65535).contains(serverPort) else { throw HarborError.message("Cannot identify SSH server port for loopback-only tunnel test") }
        let portText = try run("/usr/bin/python3",["-c","import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"])
        guard let localPort = Int(portText.1.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw HarborError.message("Cannot allocate local test port") }
        let descriptor = TunnelDescriptor(connection:connection,localPort:localPort,remote:"127.0.0.1:\(serverPort)")
        let id = UUID(); try controller.restoreWorkspaceSnapshot(WorkspaceSnapshot(groups:[.init(layout:.leaf(id),focused:id,panes:[.init(id:id,session:.tunnel(descriptor))])],selected:id))
        let tunnelTab = controller.tabs.last!
        var banner = ""
        let deadline = Date().addingTimeInterval(20)
        while banner.isEmpty && Date() < deadline {
            _ = wait(0.3,{false})
            let result = try run("/usr/bin/python3",["-c","import socket; s=socket.create_connection(('127.0.0.1',\(localPort)),2); print(s.recv(256).decode()); s.close()"])
            if result.0 == 0 { banner = result.1 }
        }
        check(banner.hasPrefix("SSH-2.0-"),"restored tunnel carries real SSH server bytes through local loopback port")
        record["local_port"] = localPort; record["remote_service_port"] = serverPort; record["ssh_banner_received"] = banner.hasPrefix("SSH-2.0-")
        var tunnelClosed = false; tunnelTab.stopTerminal { _ in tunnelClosed = true }; _ = wait(10,{tunnelClosed})
        let closed = try run("/usr/bin/python3",["-c","import socket; s=socket.socket(); s.settimeout(2); print(s.connect_ex(('127.0.0.1',\(localPort)))); s.close()"])
        check(closed.1.trimmingCharacters(in:.whitespacesAndNewlines) != "0","closing restored tunnel removes its local listener")
        connection.kind = "SFTP"
        let sftpID = UUID(); try controller.restoreWorkspaceSnapshot(WorkspaceSnapshot(groups:[.init(layout:.leaf(sftpID),focused:sftpID,panes:[.init(id:sftpID,session:.connection(connection))])],selected:sftpID))
        let sftpTab = controller.tabs.last!
        guard let view = terminal(sftpTab.view) else { throw HarborError.message("SFTP terminal surface missing") }
        check(wait(30,{view.readText()?.contains("sftp>") == true}),"restored standalone SFTP session reaches authenticated prompt")
        if let surface = view.surface { "pwd".withCString { ghostty_surface_text(surface,$0,3) } }
        let enter = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:controller.window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        view.sendKey(enter,action:GHOSTTY_ACTION_PRESS,text:nil)
        check(wait(15,{view.readText()?.contains("Remote working directory:") == true}),"restored SFTP terminal executes remote pwd")
        record["sftp_pwd_succeeded"] = view.readText()?.contains("Remote working directory:") == true
    } catch { check(false,error.localizedDescription); record["error"] = error.localizedDescription }
    let directories = controller.tabs.compactMap { $0.remoteFiles?.directory.path }
    var count = 0; controller.tabs.forEach { $0.stopTerminal { _ in count += 1 } }
    check(wait(15,{count == controller.tabs.count}) && directories.allSatisfy { !FileManager.default.fileExists(atPath:$0) },"restored connection types stop and remove owned socket directories")
    record["failures"] = failures
    try! JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("result.json"))
    print("RESULT failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1)
}
app.run()
