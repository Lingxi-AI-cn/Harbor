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
let out = URL(fileURLWithPath:CommandLine.arguments[1])
try! FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let remote = "/tmp/harbor-workspace-" + UUID().uuidString.lowercased()
var record: [String:Any] = ["remote_directory":remote,"scope":"Legion_Ext restore, dedicated temporary file, split upload close cleanup"]
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
        var closed = false, closeError: Error?
        closing.stopTerminal { closeError = $0; closed = true }
        check(wait(15,{closed}) && closeError == nil,"split pane close waits for remote upload cleanup")
        let names = try perform(reader) { try $0.list(remote).1.map(\.name) }
        try perform(reader) { try $0.download(target,to:downloaded) }
        let remainingData = try Data(contentsOf:downloaded)
        check(names == ["target.bin"] && remainingData == original,"closing uploading pane removes staging and preserves original target bytes")
        check(!FileManager.default.fileExists(atPath:writer.directory.path) && reader.authenticated && surviving.running && !staleCompletion,"closed master socket directory is removed and surviving panel remains connected")
        record["after_close_files"] = names; record["original_preserved"] = true; record["closed_socket_removed"] = !FileManager.default.fileExists(atPath:writer.directory.path); saveRecord()
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
    controller.tabs.forEach { $0.stopTerminal { error in if let error { check(false,error.localizedDescription) }; stopped += 1 } }
    check(wait(15,{stopped == controller.tabs.count}) && paths.allSatisfy { !FileManager.default.fileExists(atPath:$0) },"all restored SSH sessions close and remove control socket directories")
    record["failures"] = failures; saveRecord()
    print("RESULT failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1)
}
app.run()
