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
func masterPID(_ session: SSHFileSession) throws -> Int32 {
    let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath:"/usr/bin/ssh")
    process.arguments = ["-S",session.socket,"-O","check","-o","BatchMode=yes","-o","ProxyCommand=/usr/bin/false"] + session.connection.command().1
    process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = pipe
    try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let output = String(decoding:data,as:UTF8.self)
    guard process.terminationStatus == 0, let range = output.range(of:#"pid=[0-9]+"#,options:.regularExpression), let pid = Int32(output[range].dropFirst(4)), pid > 1 else { throw HarborError.message("Cannot identify owned SSH master") }
    return pid
}
let out = URL(fileURLWithPath:CommandLine.arguments[1])
try! FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let remote = "/tmp/harbor-disconnect-" + UUID().uuidString.lowercased()
var record: [String:Any] = ["remote_directory":remote,"scope":"Legion_Ext abrupt client SSH termination, original preservation and reconnect retry"]
func saveRecord() { if let data = try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:out.appendingPathComponent("result.json")) } }
Timer.scheduledTimer(withTimeInterval:1,repeats:false) { _ in
    var observer: SSHFileSession?, madeDirectory = false
    do {
        guard let connection = controller.store.connections.first(where:{ $0.name == "Legion_Ext" }), connection.kind == "SSH" else { throw HarborError.message("Authorized saved session Legion_Ext was not found.") }
        let a = UUID(), b = UUID()
        let snapshot = WorkspaceSnapshot(groups:[.init(layout:.split(.right,0.5,.leaf(a),.leaf(b)),focused:b,panes:[.init(id:a,session:.connection(connection)),.init(id:b,session:.connection(connection))])],selected:b)
        try controller.restoreWorkspaceSnapshot(snapshot)
        guard controller.tabs.count == 2, wait(45,{ controller.tabs.allSatisfy { $0.remoteFilesReady } }) else { throw HarborError.message("Restored SSH sessions did not both authenticate and load their file browsers.") }
        let closing = controller.tabs[0], surviving = controller.tabs[1]
        let writer = closing.remoteFiles!, reader = surviving.remoteFiles!; observer = reader
        record["sockets"] = [writer.socket,reader.socket]; saveRecord()
        check(writer.socket != reader.socket && controller.paneGroups.count == 1,"restored SSH split uses two independent authenticated masters")
        let firstDirectory = try perform(writer) { try $0.list(".").0 }
        let secondDirectory = try perform(reader) { try $0.list("/tmp").0 }
        check(!firstDirectory.isEmpty && secondDirectory == "/tmp","both restored panels browse remote directories independently")
        try perform(reader) { client in
            var body = SFTPPacket(); body.string(remote); body.put(4); body.put(0o700)
            _ = try client.request(14,body,expecting:101)
        }
        madeDirectory = true; record["created_directory"] = true; saveRecord()
        let small = out.appendingPathComponent("original.bin"), downloaded = out.appendingPathComponent("download.bin")
        let original = Data("harbor-remote-workspace-original\n".utf8); try original.write(to:small)
        let target = remote + "/target.bin"
        try perform(reader) { try $0.upload(small,to:target); try $0.download(target,to:downloaded) }
        check(try Data(contentsOf:downloaded) == original,"restored SSH session performs real upload/download byte roundtrip")
        let large = out.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath:large.path,contents:nil)
        let file = try FileHandle(forWritingTo:large); try file.truncate(atOffset:64*1024*1024); try file.close()
        let ownedMaster = try masterPID(writer); record["terminated_client_master_pid"] = ownedMaster
        var staleCompletion = false
        writer.perform(timeout:300,{ try $0.upload(large,to:target) }) { _ in staleCompletion = true }
        var staging: [String] = []
        let deadline = Date().addingTimeInterval(20)
        while staging.isEmpty && Date() < deadline {
            staging = try perform(reader) { try $0.list(remote).1.map(\.name).filter { $0.hasPrefix("target.bin.harbor-") } }
        }
        check(!staging.isEmpty && !staleCompletion,"remote staging exists while original upload is still active")
        guard !staging.isEmpty && !staleCompletion else { throw HarborError.message("Could not close during an active staged upload.") }
        record["staging_before_close"] = staging; saveRecord()
        guard kill(ownedMaster,SIGKILL) == 0 else { throw HarborError.message("Cannot terminate owned SSH test master") }
        check(wait(15,{!closing.running}),"abrupt SSH client loss is detected by terminal lifecycle")
        var closed = false, closeError: Error?
        closing.stopTerminal { closeError = $0; closed = true }
        _ = wait(15,{closed})
        let failure = closeError as? UploadFailure
        check(closed && failure?.needsCleanup == true && staging.contains(where:{ failure?.stagingPath == remote + "/" + $0 }),"disconnect retains exact owned staging path for recovery warning")
        let names = try perform(reader) { try $0.list(remote).1.map(\.name) }
        try perform(reader) { try $0.download(target,to:downloaded) }
        let remainingData = try Data(contentsOf:downloaded)
        check(names.contains("target.bin") && remainingData == original && names.contains(where:{$0.hasPrefix("target.bin.harbor-")}),"abrupt disconnect preserves original and exposes remaining staging without claiming cleanup")
        check(!FileManager.default.fileExists(atPath:writer.directory.path) && reader.authenticated && surviving.running && !staleCompletion,"disconnect cleans local socket and preserves independent panel")
        controller.connect(connection)
        let retryTab = controller.tabs.last!
        guard wait(45,{retryTab.remoteFilesReady}), let retry = retryTab.remoteFiles else { throw HarborError.message("Reconnect did not authenticate") }
        let replacement = Data("harbor-reconnect-retry\n".utf8); try replacement.write(to:small)
        try perform(retry) { try $0.upload(small,to:target); try $0.download(target,to:downloaded) }
        let retriedData = try Data(contentsOf:downloaded)
        check(retriedData == replacement,"fresh connection retries upload atomically after abrupt loss")
        record["original_preserved_after_loss"] = remainingData == original
        record["retry_bytes_match"] = retriedData == replacement
        record["recovery_warning"] = failure?.localizedDescription ?? "missing"
        record["files_after_disconnect"] = names; saveRecord()
    } catch { check(false,error.localizedDescription); record["error"] = error.localizedDescription; saveRecord() }
    if madeDirectory, let observer, observer.authenticated {
        do {
            try perform(observer) { client in
                let names = try client.list(remote).1.map(\.name)
                guard names.allSatisfy({ $0 == "target.bin" || $0.hasPrefix("target.bin.harbor-") }) else { throw HarborError.message("Unexpected files in test directory; cleanup stopped.") }
                for name in names { try client.removeTemporaryUpload(remote + "/" + name) }
                var body = SFTPPacket(); body.string(remote); _ = try client.request(15,body,expecting:101)
            }
            record["remote_directory_removed"] = true; check(true,"dedicated remote test directory cleaned")
        } catch { check(false,"Cleanup: " + error.localizedDescription); record["cleanup_error"] = error.localizedDescription }
    }
    let paths = controller.tabs.compactMap { $0.remoteFiles?.directory.path }
    var stopped = 0
    controller.tabs.forEach { $0.stopTerminal { error in if let error, !(error is UploadFailure) { check(false,error.localizedDescription) }; stopped += 1 } }
    check(wait(15,{stopped == controller.tabs.count}) && paths.allSatisfy { !FileManager.default.fileExists(atPath:$0) },"all restored SSH sessions close and remove control socket directories")
    record["failures"] = failures; saveRecord()
    print("RESULT failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1)
}
app.run()
