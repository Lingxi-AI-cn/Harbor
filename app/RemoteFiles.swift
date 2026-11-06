import AppKit
import UniformTypeIdentifiers
import Foundation
import Darwin

struct UploadFailure: LocalizedError {
    let cause: Error
    let stagingPath: String
    let needsCleanup: Bool
    let mayRemove: Bool
    var errorDescription: String? {
        L("Upload did not complete: \(cause.localizedDescription) ") +
        (needsCleanup ? L("Temporary file may remain at \(stagingPath). ") : L("Temporary file was removed. ")) +
        L("If cancellation occurred during rename, refresh to check whether the complete file was committed.")
    }
}

struct RemoteEntry {
    let name: String
    let permissions: UInt32
    var isDirectory: Bool { permissions & 0xf000 == 0x4000 }
    var isLink: Bool { permissions & 0xf000 == 0xa000 }
}

// SFTP v3 uses length-prefixed binary strings, so names with spaces, quotes and
// newlines never become shell commands or depend on parsing an `ls` display.
struct SFTPPacket {
    var bytes: [UInt8] = []
    var offset = 0
    init(_ data: Data = Data()) { bytes = Array(data) }
    mutating func put(_ n: UInt32) { bytes += [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)] }
    mutating func put64(_ n: UInt64) { put(UInt32(n >> 32)); put(UInt32(n & 0xffffffff)) }
    mutating func string(_ data: Data) { put(UInt32(data.count)); bytes += data }
    mutating func string(_ text: String) { string(Data(text.utf8)) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else { throw HarborError.message(L("Incomplete SFTP response.")) }
        defer { offset += count }; return Data(bytes[offset..<(offset + count)])
    }
    mutating func uint() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    mutating func string() throws -> Data { try take(Int(uint())) }
    mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }
    mutating func attributes() throws -> UInt32 {
        let flags = try uint()
        if flags & 1 != 0 { _ = try take(8) }
        if flags & 2 != 0 { _ = try take(8) }
        let mode: UInt32 = flags & 4 != 0 ? try uint() : 0
        if flags & 8 != 0 { _ = try take(8) }
        if flags & 0x80000000 != 0 {
            let count = try uint()
            guard count <= 100_000 else { throw HarborError.message(L("Invalid SFTP attributes.")) }
            for _ in 0..<count { _ = try string(); _ = try string() }
        }
        return mode
    }
}

final class SFTPClient {
    let input: FileHandle, output: FileHandle
    private var requestID: UInt32 = 0
    private var posixRename = false
    init(input: FileHandle, output: FileHandle) throws {
        self.input = input; self.output = output
        // A server disconnect during a write must become an error, not SIGPIPE.
        _ = fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1)
        var hello = SFTPPacket(); hello.bytes = [1]; hello.put(3); try send(hello)
        var version = try receive()
        guard try version.take(1) == Data([2]), try version.uint() == 3 else { throw HarborError.message(L("The server does not support SFTP version 3.")) }
        while version.offset < version.bytes.count {
            let name = try version.text(), value = try version.text()
            if name == "posix-rename@openssh.com", value == "1" { posixRename = true }
        }
    }
    private func exact(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try input.read(upToCount: count - data.count), !part.isEmpty else {
                throw HarborError.message(L("Remote file connection closed. Check that this server supports SFTP, then refresh."))
            }
            data.append(part)
        }
        return data
    }
    private func send(_ packet: SFTPPacket) throws {
        var frame = SFTPPacket(); frame.put(UInt32(packet.bytes.count)); frame.bytes += packet.bytes
        try output.write(contentsOf: Data(frame.bytes))
    }
    private func receive() throws -> SFTPPacket {
        var header = SFTPPacket(try exact(4)); let count = try header.uint()
        guard count > 0 && count <= 16 * 1024 * 1024 else { throw HarborError.message(L("Invalid SFTP packet length.")) }
        return SFTPPacket(try exact(Int(count)))
    }
    // A returned status 1 is EOF only where explicitly accepted by the caller.
    func request(_ type: UInt8, _ body: SFTPPacket, expecting: UInt8, allowEOF: Bool = false, allowMissing: Bool = false) throws -> SFTPPacket? {
        requestID &+= 1
        var packet = SFTPPacket(); packet.bytes = [type]; packet.put(requestID); packet.bytes += body.bytes; try send(packet)
        var reply = try receive(); let kind = try reply.take(1).first!
        guard try reply.uint() == requestID else { throw HarborError.message(L("Mismatched SFTP response.")) }
        if kind == 101 {
            let status = try reply.uint()
            if status == 1 && allowEOF { return nil }
            if status == 2 && allowMissing { return nil }
            if status == 0 && expecting == 101 { return reply }
            let message = try reply.text()
            throw HarborError.message(message.isEmpty ? L("Remote file operation failed (\(status)).") : message)
        }
        guard kind == expecting else { throw HarborError.message(L("Unexpected SFTP response.")) }
        return reply
    }
    private func close(_ handle: Data) throws { var body = SFTPPacket(); body.string(handle); _ = try request(4, body, expecting: 101) }
    func list(_ directory: String) throws -> (String, [RemoteEntry]) {
        var body = SFTPPacket(); body.string(directory)
        var resolved = try request(16, body, expecting: 104)!
        guard try resolved.uint() == 1 else { throw HarborError.message(L("Cannot resolve remote directory.")) }
        let canonical = try resolved.text()
        body = SFTPPacket(); body.string(canonical)
        var opened = try request(11, body, expecting: 102)!; let handle = try opened.string()
        defer { try? close(handle) }
        body = SFTPPacket(); body.string(handle)
        var entries: [RemoteEntry] = []
        while var reply = try request(12, body, expecting: 104, allowEOF: true) {
            let count = try reply.uint()
            guard count > 0 && count <= 100_000 && entries.count + Int(count) <= 100_000 else { throw HarborError.message(L("Remote directory is too large to display.")) }
            for _ in 0..<count {
                let name = try reply.text(); _ = try reply.text(); let mode = try reply.attributes()
                if name != "." && name != ".." { entries.append(RemoteEntry(name: name, permissions: mode)) }
            }
        }
        return (canonical, entries.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    func download(_ remote: String, to local: URL, maxBytes: UInt64 = UInt64.max) throws {
        var body = SFTPPacket(); body.string(remote); body.put(1); body.put(0)
        var opened = try request(3, body, expecting: 102)!; let handle = try opened.string()
        var closed = false; defer { if !closed { try? close(handle) } }
        // Stage beside the destination; a failed transfer preserves any existing file.
        let staging = local.deletingLastPathComponent().appendingPathComponent(".harbor-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw HarborError.message(L("Cannot create download file.")) }
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = try FileHandle(forWritingTo: staging); defer { try? file.close() }
        var offset: UInt64 = 0
        while true {
            body = SFTPPacket(); body.string(handle); body.put64(offset); body.put(32_768)
            guard var reply = try request(5, body, expecting: 103, allowEOF: true) else { break }
            let data = try reply.string()
            guard !data.isEmpty else { throw HarborError.message(L("Empty SFTP file response.")) }
            guard UInt64(data.count) <= maxBytes-offset else { throw HarborError.message(L("Remote file exceeds the permitted size.")) }
            try file.write(contentsOf: data); offset += UInt64(data.count)
        }
        try close(handle); closed = true
        try file.close()
        if rename(staging.path, local.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    func upload(_ local: URL, to remote: String) throws {
        let file = try FileHandle(forReadingFrom: local); defer { try? file.close() }
        var stat = SFTPPacket(); stat.string(remote)
        var attributes = try? request(17,stat,expecting:105)
        let previousMode = try? attributes?.attributes()
        let fileMode: UInt32 = (previousMode ?? 0) & 0o777
        let staged = remote + ".harbor-" + UUID().uuidString
        var created = false
        do {
            // EXCL prevents accidentally truncating an unrelated staging file.
            var body = SFTPPacket(); body.string(staged); body.put(2 | 8 | 32); body.put(4); body.put(0o100000 | (previousMode == nil ? 0o600 : fileMode))
            var opened = try request(3, body, expecting: 102)!; let handle = try opened.string(); created = true
            var closed = false; defer { if !closed { try? close(handle) } }
            var offset: UInt64 = 0
            while let data = try file.read(upToCount: 32_768), !data.isEmpty {
                body = SFTPPacket(); body.string(handle); body.put64(offset); body.string(data)
                _ = try request(6, body, expecting: 101); offset += UInt64(data.count)
            }
            try close(handle); closed = true
            body = SFTPPacket()
            if posixRename { body.string("posix-rename@openssh.com") }
            body.string(staged); body.string(remote)
            _ = try request(posixRename ? 200 : 18,body,expecting:101)
        } catch {
            var needsCleanup = true
            if created { do { try removeTemporaryUpload(staged); needsCleanup = false } catch {} }
            throw UploadFailure(cause:error,stagingPath:staged,needsCleanup:needsCleanup,mayRemove:created)
        }
    }

    func removeTemporaryUpload(_ path: String) throws {
        var body = SFTPPacket(); body.string(path)
        _ = try request(13,body,expecting:101,allowMissing:true)
    }

}

// One private control socket per terminal, created by OpenSSH only after auth.
// File operations require this socket and cannot prompt or reconnect separately.
final class SSHFileSession {
    let connection: Connection
    let directory: URL
    var socket: String { directory.appendingPathComponent("s").path }
    var masterOptions: [String] { ["-o", "ControlMaster=auto", "-o", "ControlPersist=no", "-o", "ControlPath=\(socket)"] }
    var slaveArguments: [String] {
        ["-T", "-o", "ControlMaster=no", "-o", "ControlPath=\(socket)", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false", "-o", "ClearAllForwardings=yes", "-o", "ForwardX11=no", "-o", "RemoteCommand=none", "-o", "LogLevel=ERROR", "-s"] + connection.command(includeJump:false).1 + ["sftp"]
    }
    private let queue = DispatchQueue(label: "harbor.remote-files", qos: .userInitiated)
    private let lock = NSLock()
    private var active: TransferOperation?
    private var stopped = false
    private var closing = false
    private var cleanupFailure: Error?
    private let testTransport: (() -> Process)?
    init(connection: Connection, testTransport: (() -> Process)? = nil) throws {
        self.testTransport = testTransport
        self.connection = connection
        directory = URL(fileURLWithPath: "/private/tmp/hbr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var authenticated: Bool { FileManager.default.fileExists(atPath: socket) }
    func perform<T>(timeout: TimeInterval = 30, deliverAfterClose: Bool = false, _ operation: @escaping (SFTPClient) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        let task = TransferOperation()
        lock.lock()
        guard !stopped, !closing, active == nil else {
            lock.unlock(); DispatchQueue.main.async { completion(.failure(HarborError.message(L("File service is disconnected or busy.")))) }; return
        }
        active = task; lock.unlock()
        queue.async {
            var result: Result<T, Error> = Result {
                try self.withTransport(task:task,timeout:timeout,operation)
            }
            let uploadFailure: UploadFailure?
            if case .failure(let error) = result { uploadFailure = error as? UploadFailure } else { uploadFailure = nil }
            var cancellation: Error?
            do { try task.check() } catch { cancellation = error }
            if let failure = uploadFailure {
                var cleaned = !failure.needsCleanup
                if failure.needsCleanup && failure.mayRemove {
                    let cleanup = TransferOperation()
                    self.lock.lock()
                    let canClean = !self.stopped
                    if canClean { self.active = cleanup }
                    self.lock.unlock()
                    if canClean {
                        do { try self.withTransport(task:cleanup,timeout:5) { try $0.removeTemporaryUpload(failure.stagingPath) }; cleaned = true }
                        catch { /* Preserve exact path for manual recovery below. */ }
                    }
                }
                let detail = UploadFailure(cause:cancellation ?? failure.cause,stagingPath:failure.stagingPath,needsCleanup:!cleaned,mayRemove:failure.mayRemove)
                result = .failure(detail)
            } else if let cancellation {
                if case .success = result {
                    result = .failure(HarborError.message(L("The operation completed while cancellation was requested. Refresh to confirm the result.")))
                } else { result = .failure(cancellation) }
            }
            self.lock.lock()
            if case .failure(let error) = result, let failure = error as? UploadFailure, failure.needsCleanup { self.cleanupFailure = failure }
            self.active = nil; self.lock.unlock()
            DispatchQueue.main.async {
                self.lock.lock(); let cancelled = self.stopped || self.closing; self.lock.unlock()
                if !cancelled || deliverAfterClose { completion(result) }
            }
        }
    }
    private func withTransport<T>(task: TransferOperation, timeout: TimeInterval, _ operation: (SFTPClient) throws -> T) throws -> T {
        let process = testTransport?() ?? Process(), input = Pipe(), output = Pipe()
        if testTransport == nil { process.executableURL = URL(fileURLWithPath:"/usr/bin/ssh"); process.arguments = slaveArguments }
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard testTransport != nil || authenticated else { throw HarborError.message(L("SSH is disconnected. Reconnect to browse remote files.")) }
        try task.attach(process)
        let watchdog = DispatchWorkItem { task.cancel(L("File operation timed out. Refresh or retry when ready.")) }
        DispatchQueue.global().asyncAfter(deadline:.now()+timeout,execute:watchdog)
        defer {
            watchdog.cancel(); try? input.fileHandleForWriting.close()
            task.terminateTransport(); process.waitUntilExit(); task.finish()
        }
        let client = try SFTPClient(input:output.fileHandleForReading,output:input.fileHandleForWriting)
        return try operation(client)
    }
    func cancelCurrentOperation() { lock.lock(); let task = active; lock.unlock(); task?.cancel() }
    // Keep the authenticated master alive until the cancelled operation has had
    // its bounded opportunity to remove its owned staging file.
    func prepareToClose(completion: @escaping (Error?) -> Void) {
        lock.lock(); closing = true; let task = active; lock.unlock()
        task?.cancel(L("Terminal is closing."))
        queue.async {
            self.lock.lock(); self.stopped = true; let error = self.cleanupFailure; self.lock.unlock()
            DispatchQueue.main.async { completion(error) }
        }
    }
    func stop(removeDirectory: Bool = true) {
        lock.lock(); stopped = true; let task = active; lock.unlock(); task?.cancel(L("SSH disconnected."))
        if removeDirectory { cleanup() }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    deinit { stop() }
}

final class RemoteFileBrowser: Canvas, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate {
    let session: SSHFileSession
    let heading = label(L("REMOTE FILES · SFTP"), size: 10, color: accent, weight: .semibold)
    let server = label("", size: 10, color: muted)
    let path = NSTextField()
    let table = NSTableView(), scroll = NSScrollView()
    let note = label(L("Loading remote files…"), size: 10, color: muted)
    var up: ActionButton!, refresh: ActionButton!, upload: ActionButton!, download: ActionButton!
    private(set) var entries: [RemoteEntry] = []
    private(set) var directory = "."
    var busy = false, ended = false
    let follow = NSButton(checkboxWithTitle:L("Follow terminal (OSC 7)"),target:nil,action:nil)
    var reportingAction: (() -> Void)?
    var reportedPath:String?, pendingPath:String?
    var editors:[RemoteTextEditor]=[]
    var completedItems=0
    var promiseReplies:[FilePromiseReply]=[]
    private var followTimer:Timer?
    private var didConnect = false
    private let onConnected: () -> Void
    init(session: SSHFileSession, onConnected: @escaping () -> Void = {}) {
        self.session = session; self.onConnected = onConnected
        super.init(interfaceColor(0x141e29))
        server.stringValue = session.connection.destination; server.toolTip = server.stringValue
        up = ActionButton(L("Up"), symbol: "arrow.up") { [weak self] in guard let self else { return }; self.reload((self.directory as NSString).deletingLastPathComponent.isEmpty ? "/" : (self.directory as NSString).deletingLastPathComponent) }
        refresh = ActionButton(L("Refresh"), symbol: "arrow.clockwise") { [weak self] in
            guard let self else { return }
            if self.busy { self.note.stringValue = L("Cancelling…"); self.session.cancelCurrentOperation() }
            else { self.reload() }
        }
        upload = ActionButton(L("Upload"), symbol: "arrow.up.doc") { [weak self] in self?.chooseUpload() }
        download = ActionButton(L("Download"), symbol: "arrow.down.doc") { [weak self] in self?.chooseDownload() }
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular); path.target = self; path.action = #selector(changePath)
        let column = NSTableColumn(identifier: .init("name")); column.width = 240
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 29; table.backgroundColor = interfaceColor(0x141e29)
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openEntry)
        table.allowsMultipleSelection=true;table.registerForDraggedTypes([.fileURL]);table.setDraggingSourceOperationMask(.copy,forLocal:false)
        follow.state = .off;follow.target=self;follow.action = #selector(followChanged);follow.frame=NSRect(x:12,y:172,width:250,height:24)
        let menu=NSMenu();menu.addItem(withTitle:L("Edit UTF-8 file…"),action:#selector(editSelected),keyEquivalent:"").target=self;menu.addItem(withTitle:L("Set up shell path reporting…"),action:#selector(setupReporting),keyEquivalent:"").target=self;table.menu=menu
        addSubview(follow)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        [heading, server, path, up, refresh, upload, download, scroll, note].forEach(addSubview)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    func setBusy(_ value: Bool, _ message: String) {
        if value && !busy {completedItems=0}
        busy = value; note.stringValue = message; note.toolTip = message
        [up, upload].forEach { $0?.isEnabled = !value && !ended }
        refresh.isEnabled = !ended; refresh.title = value ? L("Cancel") : L("Refresh")
        path.isEnabled = !value && !ended
        if !value, let pending=pendingPath { pendingPath=nil;DispatchQueue.main.async { [weak self] in self?.receiveDirectory(pending) } }
        download.isEnabled = !value && !ended && entries.indices.contains(table.selectedRow)
    }
    func disconnected() { ended = true;followTimer?.invalidate();editors.forEach{$0.disconnected()};promiseReplies.forEach{$0.finish(HarborError.message(L("SSH disconnected.")))};promiseReplies.removeAll();promised.removeAll();setBusy(false, L("SSH disconnected. Reconnect to browse files.")) }
    func reload(_ requested: String? = nil) {
        guard !busy && !ended else { return }
        let target = requested ?? directory
        setBusy(true, L("Loading remote files…"))
        session.perform({ try $0.list(target) }) { [weak self] result in
            guard let self, !self.ended else { return }
            switch result {
            case .success(let (resolved, entries)):
                self.directory = resolved; self.path.stringValue = resolved; self.entries = entries; self.table.reloadData()
                self.setBusy(false, L("\(entries.count) items · Double-click files to edit."))
                if !self.didConnect { self.didConnect = true; self.onConnected() }
            case .failure(let error): self.path.stringValue = self.directory; self.setBusy(false, error.localizedDescription)
            }
        }
    }
    @objc func changePath() { reload(path.stringValue) }
    func childPath(_ name: String) -> String { (directory == "/" ? "/" : directory + "/") + name }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row], cell = NSTableCellView()
        let text = label((entry.isDirectory ? "▸  " : entry.isLink ? "↗  " : "   ") + entry.name, size: 11, color: entry.isDirectory ? accent : ink)
        text.frame = NSRect(x: 8, y: 4, width: 240, height: 20); text.toolTip = entry.name; cell.addSubview(text); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { setBusy(busy, note.stringValue) }
    @objc func openEntry() {
        guard !busy && !ended, entries.indices.contains(table.clickedRow) else { return }
        let entry = entries[table.clickedRow]
        if entry.isDirectory || entry.isLink { reload(childPath(entry.name)) } else { editSelected() }
    }
    func chooseDownload() {
        let selected=table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? childPath(entries[$0].name):nil }
        guard !busy,!ended,!selected.isEmpty else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt=L("Download here")
        guard panel.runModal() == .OK,let folder=panel.url else{return}
        guard confirmTransfer(L("Download \(selected.count) selected item(s)?"),L("Folders are copied recursively. Existing regular files with the same names will be replaced; completed items remain if cancelled.")) else{return}
        downloadPaths(selected,to:folder)
    }
    func chooseUpload() {
        guard !busy,!ended else{return};let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=true;panel.allowsMultipleSelection=true
        if panel.runModal() == .OK {uploadURLs(panel.urls)}
    }
    func confirmTransfer(_ title:String,_ message:String)->Bool {let a=NSAlert();a.messageText=title;a.informativeText=message;a.addButton(withTitle:L("Continue"));a.addButton(withTitle:L("Cancel"));return a.runModal() == .alertFirstButtonReturn}
    func uploadURLs(_ urls:[URL]) {
        guard !busy,!ended,!urls.isEmpty,confirmTransfer(L("Upload \(urls.count) item(s)?"),L("Destination: \(session.connection.destination):\(directory). Folders merge recursively; existing files are replaced. Symbolic links are rejected. Completed items remain if cancelled.")) else{return}
        let target=directory;setBusy(true,L("Planning upload…"))
        session.perform(timeout:3600,deliverAfterClose:true,{client in let plan=try RemoteTransferPlan.upload(urls,to:target);try client.transfer(plan,uploading:true) {i,path in DispatchQueue.main.async { [weak self] in self?.completedItems=i;self?.note.stringValue=L("\(i)/\(plan.count) complete · \(path)") } }}) { [weak self] in self?.transferFinished($0) }
    }
    func downloadPaths(_ paths:[String],to folder:URL,exactName:String?=nil,completion:((Error?)->Void)?=nil) {
        guard !busy,!ended else{completion?(HarborError.message(L("File service is busy or disconnected.")));return};setBusy(true,L("Planning download…"))
        session.perform(timeout:3600,deliverAfterClose:true,{client in let plan=try client.planDownload(paths,to:folder,names:exactName.map{[$0]});try client.transfer(plan,uploading:false){i,path in DispatchQueue.main.async { [weak self] in self?.completedItems=i;self?.note.stringValue=L("\(i)/\(plan.count) complete · \(path)") } }}) { [weak self] result in self?.transferFinished(result);switch result{case .success:completion?(nil);case .failure(let e):completion?(e)} }
    }
    @objc func followChanged(){if follow.state == .on,let reportedPath {receiveDirectory(reportedPath)}}
    @objc func setupReporting(){reportingAction?()}
    func receiveDirectory(_ value:String) {
        guard value.hasPrefix("/"),!value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{return}
        reportedPath=value;guard follow.state == .on,!ended,value != directory else{return}
        if busy {pendingPath=value;return}
        followTimer?.invalidate();followTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:false){[weak self] _ in self?.reload(value)}
    }
    @objc func editSelected() {
        let row=table.clickedRow>=0 ? table.clickedRow:table.selectedRow
        guard !busy,!ended,entries.indices.contains(row),!entries[row].isDirectory,!entries[row].isLink else{return}
        let remote=childPath(entries[row].name),folder=FileManager.default.temporaryDirectory.appendingPathComponent("harbor-edit-\(UUID().uuidString)")
        setBusy(true,L("Opening text…"))
        session.perform(timeout:60,deliverAfterClose:true,{client -> Data in
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);let file=folder.appendingPathComponent("original")
            guard try client.mode(remote).map({$0&0xf000 == 0x8000}) == true else{throw HarborError.message(L("Choose a regular text file."))}
            try client.download(remote,to:file,maxBytes:8*1024*1024);return try Data(contentsOf:file)
        }) { [weak self] result in
            guard let self,!self.ended else{try? FileManager.default.removeItem(at:folder);return};self.setBusy(false,"")
            do {let editor=try RemoteTextEditor(session:self.session,remote:remote,folder:folder,data:result.get());self.editors.append(editor);editor.onClosed={ [weak self,weak editor] in self?.editors.removeAll{$0 === editor} };editor.showWindow(nil)}catch{try? FileManager.default.removeItem(at:folder);self.setBusy(false,error.localizedDescription)}
        }
    }
    func tableView(_ tableView:NSTableView,validateDrop info:NSDraggingInfo,proposedRow:Int,proposedDropOperation:NSTableView.DropOperation)->NSDragOperation {
        tableView.setDropRow(-1,dropOperation:.on);return !busy && !ended && info.draggingPasteboard.canReadObject(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) ? .copy:[]
    }
    func tableView(_ tableView:NSTableView,acceptDrop info:NSDraggingInfo,row:Int,dropOperation:NSTableView.DropOperation)->Bool {
        guard let urls=info.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty else{return false}
        DispatchQueue.main.async{[weak self] in self?.uploadURLs(urls)};return true
    }
    func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int)->NSPasteboardWriting? {
        guard !busy,!ended,entries.indices.contains(row),!entries[row].isLink else{return nil}
        let entry=entries[row],promise=NSFilePromiseProvider(fileType:entry.isDirectory ? UTType.folder.identifier:UTType.data.identifier,delegate:self)
        promise.userInfo=childPath(entry.name);return promise
    }
    func filePromiseProvider(_ provider:NSFilePromiseProvider,fileNameForType:String)->String {(provider.userInfo as? String).map{($0 as NSString).lastPathComponent} ?? "download"}
    func filePromiseProvider(_ provider:NSFilePromiseProvider,writePromiseTo url:URL,completionHandler:@escaping(Error?)->Void) {
        guard let remote=provider.userInfo as? String else{completionHandler(HarborError.message(L("Missing remote source.")));return}
        DispatchQueue.main.async { [weak self] in
            guard let self else{completionHandler(HarborError.message(L("Remote browser closed.")));return}
            // Finder supplies the final path. A file promise never overwrites an existing item.
            guard !FileManager.default.fileExists(atPath:url.path) else{completionHandler(HarborError.message(L("The destination already exists.")));return}
            let reply=FilePromiseReply(completionHandler);self.promiseReplies.append(reply);self.enqueuePromise(remote,to:url,completion:{error in reply.finish(error)})
        }
    }
    private var promised:[(String,URL,(Error?)->Void)]=[]
    private func enqueuePromise(_ remote:String,to url:URL,completion:@escaping(Error?)->Void){promised.append((remote,url,completion));drainPromises()}
    private func drainPromises(){guard !busy,!promised.isEmpty else{return};let item=promised.removeFirst();downloadPaths([item.0],to:item.1.deletingLastPathComponent(),exactName:item.1.lastPathComponent){[weak self] error in item.2(error);self?.drainPromises()}}
    private func transferFinished(_ result: Result<Void, Error>) {
        guard !ended else { return }
        switch result {
        case .success: setBusy(false, L("Transfer complete."));if promised.isEmpty {reload()}
        case .failure(let error): setBusy(false, L("\(completedItems) item(s) completed. ")+error.localizedDescription)
        }
    }
    override func layout() {
        heading.frame = NSRect(x: 16, y: 18, width: 214, height: 18)
        server.frame = NSRect(x: 16, y: 39, width: 240, height: 20)
        path.frame = NSRect(x: 14, y: 66, width: 242, height: 25)
        up.frame = NSRect(x: 12, y: 101, width: 72, height: 29)
        refresh.frame = NSRect(x: 91, y: 101, width: 166, height: 29)
        upload.frame = NSRect(x: 12, y: 139, width: 112, height: 29)
        download.frame = NSRect(x: 131, y: 139, width: 126, height: 29)
        scroll.frame = NSRect(x: 8, y: 207, width: 254, height: max(20, bounds.height - 271))
        note.frame = NSRect(x: 17, y: bounds.height - 53, width: 237, height: 42)
    }
}

func remoteFilesSelfTest() throws {
    func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw HarborError.message("FAIL: \(description)") }; print("PASS: \(description)")
    }
    func canonical(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }; return String(cString: resolved)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-sftp-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("folder with spaces")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let name = "中文 \"quoted\" 'file'\nsecond-line.bin"
    let source = root.appendingPathComponent(name)
    let payload = Data((0..<131_333).map { UInt8($0 % 251) })
    try payload.write(to: source)
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked folder").path, withDestinationPath: folder.path)
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server"); process.arguments = ["-d", root.path]
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
    let client = try SFTPClient(input: output.fileHandleForReading, output: input.fileHandleForWriting)
    let (home, entries) = try client.list(".")
    try require(home == canonical(root) && entries.contains { $0.name == name }, "real SFTP handshake, home resolution and exact Unicode/quoted/newline filenames")
    try require(entries.first?.name == folder.lastPathComponent && entries.first?.isDirectory == true && entries.contains { $0.name == ".hidden" } && !entries.contains { $0.name == "." || $0.name == ".." }, "SFTP attributes, folders first, hidden files and dot entry filtering")
    let (nested, empty) = try client.list(folder.path)
    try require(nested == canonical(folder) && empty.isEmpty, "remote directory navigation and empty directory EOF")
    let (linked, _) = try client.list(root.appendingPathComponent("linked folder").path)
    try require(linked == nested && entries.contains { $0.name == "linked folder" && $0.isLink }, "remote symbolic directory links resolve without local filesystem assumptions")
    let downloaded = root.appendingPathComponent("download.bin")
    try client.download(source.path, to: downloaded)
    let downloadData = try Data(contentsOf: downloaded)
    try require(downloadData == payload, "SFTP binary download preserves multiple chunks and final partial chunk")
    let uploaded = folder.appendingPathComponent(name)
    try client.upload(downloaded, to: uploaded.path)
    let uploadData = try Data(contentsOf: uploaded)
    try require(uploadData == payload, "SFTP binary upload and close acknowledgement preserve exact content")
    try Data("existing destination".utf8).write(to:uploaded)
    try FileManager.default.setAttributes([.posixPermissions:0o750],ofItemAtPath:uploaded.path)
    try client.upload(source,to:uploaded.path)
    let replaced = try Data(contentsOf:uploaded)
    try require(replaced == payload,"SFTP atomic replacement preserves complete uploaded content")
    let mode = try FileManager.default.attributesOfItem(atPath:uploaded.path)[.posixPermissions] as? NSNumber
    try require(mode?.intValue == 0o750,"SFTP atomic replacement preserves existing permission bits")
    var renameFailed = false
    do { try client.upload(source,to:folder.path) } catch { renameFailed = true }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0.contains(".harbor-") }
    try require(renameFailed && FileManager.default.fileExists(atPath:uploaded.path) && leftovers.isEmpty,"failed upload rename preserves existing directory and removes staging file")
    // Break a real SFTP upload after a write has reached disk, then clean its
    // exact staging path over the independent still-live SFTP connection.
    let large = root.appendingPathComponent("large-source.bin")
    FileManager.default.createFile(atPath:large.path,contents:nil)
    let largeHandle = try FileHandle(forWritingTo:large); try largeHandle.truncate(atOffset:64 * 1024 * 1024); try largeHandle.close()
    let destination = root.appendingPathComponent("cancel-target.bin")
    try Data("original target".utf8).write(to:destination)
    let broken = Process(), brokenInput = Pipe(), brokenOutput = Pipe(), brokenTask = TransferOperation()
    broken.executableURL = URL(fileURLWithPath:"/usr/libexec/sftp-server"); broken.arguments = ["-d",root.path]
    broken.standardInput = brokenInput; broken.standardOutput = brokenOutput; broken.standardError = FileHandle.nullDevice
    try brokenTask.attach(broken)
    let brokenClient = try SFTPClient(input:brokenOutput.fileHandleForReading,output:brokenInput.fileHandleForWriting)
    let monitorDone = DispatchSemaphore(value:0)
    DispatchQueue.global().async {
        defer { monitorDone.signal() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let paths = (try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? []
            if paths.contains(where: { name in
                guard name.hasPrefix("cancel-target.bin.harbor-") else { return false }
                let attrs = try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(name).path)
                return ((attrs?[.size] as? NSNumber)?.intValue ?? 0) > 0
            }) { brokenTask.cancel(); return }
            Thread.sleep(forTimeInterval:0.002)
        }
        brokenTask.cancel("Test transport timeout")
    }
    var interrupted: UploadFailure?
    do { try brokenClient.upload(large,to:destination.path) } catch { interrupted = error as? UploadFailure }
    try? brokenInput.fileHandleForWriting.close(); brokenTask.terminateTransport(); broken.waitUntilExit(); brokenTask.finish()
    _ = monitorDone.wait(timeout:.now()+6)
    let original = try Data(contentsOf:destination)
    try require(interrupted?.needsCleanup == true && interrupted?.mayRemove == true && original == Data("original target".utf8),"interrupted real SFTP upload preserves target and records owned staging path")
    if let interrupted {
        try require(interrupted.localizedDescription.contains(interrupted.stagingPath),"failed cleanup error retains exact staging path")
        try client.removeTemporaryUpload(interrupted.stagingPath)
        try client.removeTemporaryUpload(interrupted.stagingPath)
        try require(!FileManager.default.fileExists(atPath:interrupted.stagingPath) && FileManager.default.fileExists(atPath:destination.path),"independent SFTP cleanup is idempotent and removes only staging file")
    }
    let closingTarget = root.appendingPathComponent("close-target.bin")
    try Data("keep original".utf8).write(to:closingTarget)
    let closingSession = try SSHFileSession(connection:Connection(name:"local test",host:"unused.invalid",user:"test"),testTransport: {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/libexec/sftp-server"); process.arguments = ["-d",root.path]; return process
    })
    var closeDone = false, closeError: Error?, callbackAfterClose = false, sawStaging = false
    closingSession.perform(timeout:10,{ try $0.upload(large,to:closingTarget.path) }) { _ in callbackAfterClose = true }
    let closeDeadline = Date().addingTimeInterval(12)
    while Date() < closeDeadline && !closeDone {
        if !sawStaging {
            let names = (try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? []
            if names.contains(where: { $0.hasPrefix("close-target.bin.harbor-") }) {
                sawStaging = true
                closingSession.prepareToClose { closeError = $0; closeDone = true }
            }
        }
        RunLoop.main.run(until:Date().addingTimeInterval(0.001))
    }
    closingSession.stop()
    let residual = try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0.hasPrefix("close-target.bin.harbor-") }
    try require(sawStaging && closeDone && closeError == nil && residual.isEmpty,"graceful close waits for real SFTP staging cleanup")
    let closingOriginal = try Data(contentsOf:closingTarget)
    try require(closingOriginal == Data("keep original".utf8) && !callbackAfterClose,"graceful close preserves target and suppresses stale UI completion")
    let cancellation = TransferOperation(), unaffected = TransferOperation()
    let blocked = Process(), survivor = Process(), readPipe = Pipe()
    blocked.executableURL = URL(fileURLWithPath:"/bin/sleep"); blocked.arguments = ["60"]; blocked.standardOutput = readPipe
    survivor.executableURL = URL(fileURLWithPath:"/bin/sleep"); survivor.arguments = ["60"]
    try cancellation.attach(blocked); try unaffected.attach(survivor)
    let started = Date()
    DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { cancellation.cancel() }
    _ = readPipe.fileHandleForReading.readDataToEndOfFile(); blocked.waitUntilExit()
    var wasCancelled = false
    do { try cancellation.check() } catch { wasCancelled = true }
    try require(wasCancelled && Date().timeIntervalSince(started) < 5 && survivor.isRunning,"cancelling blocked transport unblocks IO without stopping another operation")
    unaffected.cancel(); survivor.waitUntilExit(); cancellation.finish(); unaffected.finish()
    let preCancelled = TransferOperation(); preCancelled.cancel()
    let never = Process(); never.executableURL = URL(fileURLWithPath:"/bin/sleep"); never.arguments = ["60"]
    var startRejected = false
    do { try preCancelled.attach(never) } catch { startRejected = true }
    try require(startRejected && !never.isRunning,"cancellation before launch prevents a new subprocess")

    try Data("keep existing".utf8).write(to: downloaded)
    do { try client.download(root.appendingPathComponent("missing").path, to: downloaded); throw HarborError.message("FAIL: missing remote file accepted") }
    catch HarborError.message(let message) where !message.hasPrefix("FAIL:") { print("PASS: SFTP missing file is an error") }
    let preserved = try Data(contentsOf: downloaded)
    try require(preserved == Data("keep existing".utf8), "failed download preserves existing destination")
    do { _ = try client.list(root.appendingPathComponent("missing-folder").path); throw HarborError.message("FAIL: missing remote directory accepted") }
    catch HarborError.message(let message) where !message.hasPrefix("FAIL:") { print("PASS: SFTP directory errors remain recoverable") }
    let (_, recovered) = try client.list(".")
    try require(recovered.contains { $0.name == name }, "SFTP browsing still works after a server status error")
    var short = SFTPPacket(Data([0, 0, 0, 4, 65]))
    do { _ = try short.string(); throw HarborError.message("FAIL: truncated packet accepted") }
    catch HarborError.message(let message) where !message.hasPrefix("FAIL:") { print("PASS: truncated SFTP strings are rejected") }
    let closedPipe = Pipe(), unusedPipe = Pipe()
    try closedPipe.fileHandleForReading.close()
    do {
        _ = try SFTPClient(input: unusedPipe.fileHandleForReading, output: closedPipe.fileHandleForWriting)
        throw HarborError.message("FAIL: disconnected SFTP writer accepted")
    } catch HarborError.message(let message) where message.hasPrefix("FAIL:") { throw HarborError.message(message) }
    catch { print("PASS: disconnected SFTP writes report an error without terminating the app") }
    let one = try SSHFileSession(connection: Connection(name: "one", host: "example.invalid", user: "operator", port: 2222))
    let two = try SSHFileSession(connection: Connection(name: "two", host: "example.invalid", user: "operator"))
    defer { one.stop(); two.stop() }
    let permissions = try FileManager.default.attributesOfItem(atPath: one.directory.path)
    try require(one.socket != two.socket && one.socket.utf8.count < 104 && (permissions[.posixPermissions] as? NSNumber)?.intValue == 0o700 && !one.authenticated, "SSH tabs have private short sockets and do not browse before authentication")
    let config = Process(), configOutput = Pipe()
    config.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); config.arguments = ["-G", "-F", "/dev/null"] + one.slaveArguments
    config.standardOutput = configOutput; config.standardError = FileHandle.nullDevice; try config.run()
    let effective = String(decoding: configOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); config.waitUntilExit()
    try require(config.terminationStatus == 0 && effective.contains("batchmode yes\n") && effective.contains("controlmaster false\n") && effective.contains("proxycommand /usr/bin/false\n") && effective.contains("port 2222\n") && effective.contains("controlpath \(one.socket)\n"), "OpenSSH confirms file operations reuse the exact socket and cannot start a fresh login")
    one.stop()
    try require(!FileManager.default.fileExists(atPath: one.directory.path) && FileManager.default.fileExists(atPath: two.directory.path), "closing one SSH tab cleans only its own file session")
}
