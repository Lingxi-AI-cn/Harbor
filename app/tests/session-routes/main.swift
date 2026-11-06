import AppKit
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let controller = AppController(); app.delegate = controller
let env = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath:env["HARBOR_ROUTE_ROOT"]!)
let config = env["HARBOR_ROUTE_CONFIG"]!
var assertions = 0, failures = 0
func check(_ ok: Bool,_ name: String) { assertions += 1; print("\(ok ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !ok { failures += 1 } }
func done() { controller.tabs.forEach { $0.stopTerminal() }; print("RESULT assertions=\(assertions) failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1) }
var timer: Timer?
DispatchQueue.main.asyncAfter(deadline:.now()+1) {
 do {
    controller.store = try SessionStore(url:root.appendingPathComponent("ui-sessions.json"))
    var c = Connection(name:"Loopback two-hop",host:"127.0.0.1",user:env["HARBOR_ROUTE_USER"]!,port:Int(env["HARBOR_ROUTE_PORT"]!)!)
    c.jumpHosts = "hop1,hop2"; c.identity = root.appendingPathComponent("client_key").path
    try c.validate()
    guard let tab = controller.launch(title:c.name,executable:"/usr/bin/ssh",arguments:["-F",config,"-T"] + c.command().1 + ["printf HARBOR_ROUTE_READY; sleep 30"],connection:c,browseRemoteFiles:true), let files = tab.remoteFiles else { check(false,"launch routed terminal"); done(); return }
    let started = Date()
    timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { _ in
        if Date().timeIntervalSince(started)>15 { timer?.invalidate(); check(false,"routed terminal authenticates within deadline"); done(); return }
        guard files.authenticated, tab.remoteFilesReady else { return }
        timer?.invalidate()
        check(tab.running && files.authenticated,"real Harbor SSH terminal authenticates through two gateways")
        check(tab.remoteFilesReady && controller.workspace.fileBrowser === tab.remoteBrowser,"SFTP listing opens using the authenticated routed terminal")
        let payload = Data((0..<8193).map { UInt8($0%251) }), local = root.appendingPathComponent("payload.bin"), remote = root.appendingPathComponent("remote.bin"), download = root.appendingPathComponent("download.bin")
        do { try payload.write(to:local) } catch { check(false,error.localizedDescription); done(); return }
        files.perform { client -> Bool in
            try client.upload(local,to:remote.path); try client.download(remote.path,to:download)
            return try Data(contentsOf:download) == payload
        } completion: { result in
            switch result { case .success(let exact): check(exact,"SFTP upload/download through routed master preserves exact bytes"); case .failure(let error): check(false,error.localizedDescription) }
            let socketDirectory = files.directory
            controller.closePane(tab)
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                check(controller.tabs.isEmpty && controller.paneGroups.isEmpty,"closing routed tab removes terminal and pane group")
                check(!FileManager.default.fileExists(atPath:socketDirectory.path),"closing routed terminal cleans private control socket")
                files.perform({ try $0.list(root.path).0 }) { result in
                    if case .failure = result { check(true,"closed routed SFTP cannot silently establish a fresh connection") } else { check(false,"closed routed SFTP unexpectedly reconnected") }
                    // Real OpenSSH failure log: isolated loopback port already known to have no listener.
                    let log = root.appendingPathComponent("failure.log")
                    let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/ssh")
                    process.arguments = ["-F","/dev/null","-v","-E",log.path,"-o","BatchMode=yes","-o","ConnectTimeout=2","-p","1","127.0.0.1"]
                    process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    do {
                        try process.run(); process.waitUntilExit()
                        let text = try String(contentsOf:log,encoding:.utf8)
                        check(process.terminationStatus != 0 && ConnectionDiagnostics.explanation(text).contains("refused"),"diagnostics classify a real OpenSSH refused-connection log")
                    } catch { check(false,error.localizedDescription) }
                    done()
                }
            }
        }
    }
 } catch { check(false,error.localizedDescription); done() }
}
app.run()
