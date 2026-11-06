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
let out = URL(fileURLWithPath:CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : Bundle.main.bundleURL.deletingLastPathComponent().path)
try! FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let recordURL = out.appendingPathComponent("result.json")
var record = ((try? Data(contentsOf:recordURL)).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]) ?? [:]
func saveRecord() { let data = try! JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]); try! data.write(to:recordURL,options:.atomic) }
func connect(_ count: Int) throws -> [TerminalTab] {
    guard let c = controller.store.connections.first(where:{$0.name == "Legion_Ext"}) else { throw HarborError.message("Legion_Ext is missing") }
    for _ in 0..<count { controller.connect(c) }
    guard controller.tabs.count == count, wait(45,{controller.tabs.allSatisfy { $0.remoteFilesReady }}) else { throw HarborError.message("SSH authentication/file browser timed out") }
    return controller.tabs
}
Timer.scheduledTimer(withTimeInterval:1,repeats:false) { _ in
    do {
        if record["phase"] as? String == "awaiting_quit" {
            let sockets = record["sockets"] as! [String]
            check(sockets.allSatisfy { !FileManager.default.fileExists(atPath:URL(fileURLWithPath:$0).deletingLastPathComponent().path) },"whole-app quit removed both control socket directories")
            let tabs = try connect(1), reader = tabs[0].remoteFiles!
            let remote = record["remote_directory"] as! String
            guard remote.hasPrefix("/tmp/harbor-quit-"), UUID(uuidString:String(remote.dropFirst("/tmp/harbor-quit-".count))) != nil else { throw HarborError.message("Unexpected test directory") }
            let names = try perform(reader) { try $0.list(remote).1.map(\.name) }
            let download = out.appendingPathComponent("after-quit.bin")
            try perform(reader) { try $0.download(remote + "/target.bin",to:download) }
            let bytes = try Data(contentsOf:download)
            check(names == ["target.bin"] && bytes == Data("harbor-quit-original\n".utf8),"application quit during upload cleaned staging and preserved original bytes")
            record["after_quit_files"] = names; record["original_preserved"] = bytes == Data("harbor-quit-original\n".utf8); saveRecord()
            guard names == ["target.bin"] else { throw HarborError.message("Unexpected files remain; preserve for investigation") }
            try perform(reader) { client in
                try client.removeTemporaryUpload(remote + "/target.bin")
                var body = SFTPPacket(); body.string(remote); _ = try client.request(15,body,expecting:101)
            }
            check(true,"dedicated whole-quit remote test directory removed")
            record["remote_directory_removed"] = true
            let path = reader.directory.path
            var closed = false; tabs[0].stopTerminal { error in check(error == nil,"verification connection closes cleanly"); closed = true }
            check(wait(15,{closed}) && !FileManager.default.fileExists(atPath:path),"verification socket directory removed")
            record["phase"] = "complete"; record["failures"] = failures; saveRecord()
            print("RESULT failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1)
        }
        guard record.isEmpty else { throw HarborError.message("Existing test state is not awaiting verification; refusing to repeat remote writes") }
        let tabs = try connect(2), writer = tabs[0].remoteFiles!, reader = tabs[1].remoteFiles!
        let remote = "/tmp/harbor-quit-" + UUID().uuidString.lowercased()
        record = ["phase":"preparing","remote_directory":remote,"sockets":[writer.socket,reader.socket]]; saveRecord()
        try perform(reader) { client in var body = SFTPPacket(); body.string(remote); body.put(4); body.put(0o700); _ = try client.request(14,body,expecting:101) }
        let original = out.appendingPathComponent("original.bin"); try Data("harbor-quit-original\n".utf8).write(to:original)
        try perform(reader) { try $0.upload(original,to:remote + "/target.bin") }
        let large = out.appendingPathComponent("large.bin"); FileManager.default.createFile(atPath:large.path,contents:nil)
        let file = try FileHandle(forWritingTo:large); try file.truncate(atOffset:64*1024*1024); try file.close()
        var uploadFinished = false
        writer.perform(timeout:300,{try $0.upload(large,to:remote + "/target.bin")}) { _ in uploadFinished = true }
        var staging: [String] = []; let deadline = Date().addingTimeInterval(20)
        while staging.isEmpty && Date() < deadline { staging = try perform(reader) { try $0.list(remote).1.map(\.name).filter { $0.hasPrefix("target.bin.harbor-") } } }
        guard !staging.isEmpty && !uploadFinished else { throw HarborError.message("Did not observe active staged upload") }
        check(true,"active staged upload observed before application termination")
        record["phase"] = "awaiting_quit"; record["staging_before_quit"] = staging; saveRecord()
        print("READY_FOR_QUIT_CONFIRMATION"); fflush(stdout)
        NSApp.terminate(nil)
    } catch {
        check(false,error.localizedDescription); record["error"] = error.localizedDescription; saveRecord()
        var stopped = 0; controller.tabs.forEach { $0.stopTerminal { _ in stopped += 1 } }
        _ = wait(15,{stopped == controller.tabs.count}); exit(1)
    }
}
app.run()
