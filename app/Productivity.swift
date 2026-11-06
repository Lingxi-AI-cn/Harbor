import AppKit
import Darwin

struct TunnelProfile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var tunnel: TunnelDescriptor
}
struct CommandSnippet: Codable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
}
struct ProductivityData: Codable {
    var version = 1
    var tunnels: [TunnelProfile] = []
    var snippets: [CommandSnippet] = []
    func validate() throws {
        guard version == 1, tunnels.count <= 500, snippets.count <= 1000,
              Set(tunnels.map(\.id)).count == tunnels.count, Set(snippets.map(\.id)).count == snippets.count else { throw HarborError.message(L("Unsupported or invalid productivity settings.")) }
        for p in tunnels { try InputDelivery.validateName(p.name); try p.tunnel.validate(checkIdentity:false) }
        for p in snippets { try InputDelivery.validateName(p.name); try InputDelivery.validate(p.text) }
    }
}
final class ProductivityStore {
    let url: URL
    private(set) var data = ProductivityData()
    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath:url.path) {
            let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size <= 8_388_608 else { throw HarborError.message(L("Productivity settings exceed 8 MiB.")) }
            data = try JSONDecoder().decode(ProductivityData.self,from:Data(contentsOf:url)); try data.validate()
        }
    }
    func update(_ change: (inout ProductivityData) -> Void) throws {
        var next = data; change(&next); try next.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let bytes = try encoder.encode(next)
        guard bytes.count <= 8_388_608 else { throw HarborError.message(L("Productivity settings exceed 8 MiB.")) }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try bytes.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        data = next
    }
}

enum InputDelivery {
    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw HarborError.message(L("Enter a name of 1–256 bytes without control characters.")) }
    }
    static func validate(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 65536,
              !text.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { throw HarborError.message(L("Enter up to 64 KiB of text. Only newline and tab control characters are accepted.")) }
    }
    static func eligible(_ tab: TerminalTab) -> Bool {
        tab.running && !tab.closing && tab.tunnel == nil && (tab.connection == nil || tab.connection?.kind == "SSH") && tab.view.acceptsProgrammaticInput
    }
    @discardableResult static func send(_ text: String, submit: Bool, ids: Set<UUID>, tabs: [TerminalTab]) throws -> Int {
        try validate(text)
        let targets = tabs.filter { ids.contains($0.id) }
        guard !ids.isEmpty, targets.count == ids.count, targets.allSatisfy(eligible) else { throw HarborError.message(L("A selected terminal has closed or is not ready. No input was sent; refresh the target list and select again.")) }
        var sent = 0
        for target in targets {
            guard target.view.input(text,submit:submit) else { throw HarborError.message(L("Input was sent to \(sent) terminals before a terminal became unavailable. Inspect them before sending again.")) }
            sent += 1
        }
        return sent
    }
}

enum SessionRecording {
    static func prepare(_ url: URL) throws {
        let fd = Darwin.open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw HarborError.message(L("Choose a new writable log file. Existing files are never overwritten: \(String(cString:strerror(errno)))")) }
        Darwin.close(fd)
    }
    static func command(_ executable: String, _ arguments: [String], log: URL) -> (String,[String]) {
        ("/usr/bin/script",["-q","-F",log.path,executable] + arguments)
    }
}

/// A dedicated terminal owns authentication; forwarding is installed only after the
/// private master socket is ready. -O forward acknowledges the actual listener.
final class TunnelRun {
    let profile: TunnelProfile
    let directory: URL
    var socket: String { directory.appendingPathComponent("s").path }
    weak var owner: AppController?
    weak var tab: TerminalTab?
    private(set) var state = "Starting · authenticate in terminal"
    var localizedState: String {
        if state.hasPrefix("Failed · ") { return L("Failed · \(String(state.dropFirst("Failed · ".count)))") }
        return L10n.text(state)
    }
    private(set) var active = true
    private(set) var forwarding = false
    private var timer: Timer?
    private var operation: TransferOperation?
    private let configurationFile: String?
    init(profile: TunnelProfile, owner: AppController, configurationFile: String? = nil) throws {
        self.profile = profile; self.owner = owner; self.configurationFile = configurationFile
        directory = URL(fileURLWithPath:"/private/tmp/hbt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    var masterArguments: [String] {
        let options = ["-N","-a","-x","-o","ClearAllForwardings=yes","-o","ControlMaster=yes","-o","ControlPersist=no","-o","ControlPath=\(socket)"]
        return options + (configurationFile.map { ["-F",$0] } ?? []) + profile.tunnel.connection.command().1
    }
    func observe(_ tab: TerminalTab) {
        self.tab = tab
        timer = Timer(timeInterval:0.2,repeats:true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer,forMode:.common) }
    }
    private func tick() {
        guard active else { return }
        guard let tab, tab.running, !tab.closing else { didStop(); return }
        guard !forwarding, operation == nil, FileManager.default.fileExists(atPath:socket) else { return }
        state = "Installing forwarding…"
        let task = TransferOperation(); operation = task
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/ssh")
        process.arguments = ["-S",socket,"-O","forward","-o","ControlMaster=no","-o","BatchMode=yes","-o","ProxyCommand=/usr/bin/false"] + profile.tunnel.forwardArguments + (configurationFile.map { ["-F",$0] } ?? []) + profile.tunnel.connection.command(includeJump:false).1
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result: Result<Void,Error> = Result {
                try task.attach(process)
                let timeout = DispatchWorkItem { task.cancel(L("Forwarding setup timed out.")) }
                DispatchQueue.global().asyncAfter(deadline:.now()+8,execute:timeout)
                defer { timeout.cancel(); task.terminateTransport(); process.waitUntilExit(); task.finish() }
                let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); try task.check()
                guard process.terminationStatus == 0 else { throw HarborError.message(String(decoding:bytes.suffix(8192),as:UTF8.self)) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.operation = nil
                guard self.active else { return }
                switch result {
                case .success:
                    self.forwarding = true
                    self.state = self.profile.tunnel.kind == .remote ? "Active · server confirmed remote forwarding" : "Active · local listener installed"
                case .failure(let error):
                    self.state = "Failed · " + error.localizedDescription
                    self.stop(preserveFailure:true)
                }
            }
        }
    }
    func stopObservation() {
        active = false; forwarding = false; timer?.invalidate(); timer = nil
        operation?.cancel(L("Tunnel stopped.")); operation = nil
        if !state.hasPrefix("Failed") { state = "Stopping…" }
    }
    func didStop() {
        let wasStarting = active && !forwarding
        stopObservation()
        if !state.hasPrefix("Failed") { state = wasStarting ? "Failed · SSH ended before forwarding was ready; inspect its terminal" : "Stopped" }
        try? FileManager.default.removeItem(at:directory)
    }
    func stop(preserveFailure: Bool = false) {
        stopObservation()
        if let tab, let owner, owner.tabs.contains(where:{$0 === tab}) { owner.closePane(tab) }
        else { didStop() }
    }
    deinit { timer?.invalidate(); operation?.cancel(); try? FileManager.default.removeItem(at:directory) }
}

extension AppController {
    func p2Store() throws -> ProductivityStore {
        if let productivityStore { return productivityStore }
        let loaded = try ProductivityStore(url:store.url.deletingLastPathComponent().appendingPathComponent("productivity.json"))
        productivityStore = loaded; return loaded
    }
    @objc func tunnelManagerAction() { showTunnel() }
    @discardableResult func startTunnel(_ profile: TunnelProfile, configurationFile: String? = nil) throws -> TerminalTab {
        try profile.tunnel.validate()
        if let existing = managedTunnels[profile.id], existing.active { throw HarborError.message(L("This tunnel is already starting or active.")) }
        let descriptor = profile.tunnel
        if descriptor.kind != .remote, managedTunnels.values.contains(where: { $0.active && $0.profile.tunnel.kind != .remote && $0.profile.tunnel.localPort == descriptor.localPort }) { throw HarborError.message(L("Another Harbor tunnel already owns local port \(descriptor.localPort).")) }
        let run = try TunnelRun(profile:profile,owner:self,configurationFile:configurationFile)
        guard let tab = launch(title:L("Tunnel · ") + profile.name,executable:"/usr/bin/ssh",arguments:run.masterArguments,connection:descriptor.connection) else { throw HarborError.message(L("Could not start tunnel authentication.")) }
        var snapshot = descriptor; snapshot.profileID = profile.id; tab.tunnel = snapshot
        managedTunnels[profile.id] = run
        tab.onStopping = { [weak run] in run?.stopObservation() }
        tab.onStopped = { [weak run] in run?.didStop() }
        tab.onProcessEnded = { [weak run] in run?.didStop() }
        run.observe(tab); workspace.refreshTabs()
        return tab
    }
    @objc func broadcastInput() { openBroadcast(text:"") }
    func openBroadcast(text: String) {
        if let broadcastComposer { broadcastComposer.window?.makeKeyAndOrderFront(nil); return }
        let composer = BroadcastComposer(hostController:self,text:text); broadcastComposer = composer; composer.showWindow(nil)
    }
    @objc func commandSnippets() {
        do {
            if let snippetManager { snippetManager.window?.makeKeyAndOrderFront(nil); return }
            let manager = SnippetManager(hostController:self,store:try p2Store()); snippetManager = manager; manager.showWindow(nil)
        } catch { showError(error) }
    }
    @objc func newRecordedTerminal() { chooseRecording(copyCurrent:false) }
    @objc func recordedCopy() { chooseRecording(copyCurrent:true) }
    func chooseRecording(copyCurrent: Bool) {
        let source = copyCurrent && tabs.indices.contains(selected) ? tabs[selected] : nil
        if copyCurrent && (source == nil || source?.tunnel != nil || source?.connection?.kind == "Serial") { showError(HarborError.message(L("Select a local, SSH or SFTP terminal. Tunnels cannot be recorded here; a serial port cannot be opened by a second recording session."))); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Harbor-\(Int(Date().timeIntervalSince1970)).log"
        panel.message = L("Open a new recorded session. The original stays open. Output, terminal escape sequences and echoed input are saved from startup; existing files are not overwritten.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let connection = source?.connection { try connection.validate() }
            try SessionRecording.prepare(url)
            let connection = source?.connection
            let executable: String, arguments: [String]
            if let connection { (executable,arguments) = connection.command() }
            else { let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"; executable = FileManager.default.isExecutableFile(atPath:shell) ? shell : "/bin/zsh"; arguments = ["-l"] }
            _ = launch(title:connection?.name ?? L("Recorded terminal"),executable:executable,arguments:arguments,connection:connection,browseRemoteFiles:connection?.kind == "SSH",workingDirectory:connection == nil ? source?.reportedWorkingDirectory : nil,recordingURL:url)
        } catch { showError(error) }
    }
    @objc func revealSessionLog() {
        guard tabs.indices.contains(selected), let url = tabs[selected].view.liveLog.url ?? tabs[selected].recordingURL else { showError(HarborError.message(L("This terminal is not recording. Use Session → Open recorded copy to start a new logged session."))); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private func toolWindow(_ title: String,width: CGFloat,height: CGFloat) -> NSWindow {
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.title = title; window.isReleasedWhenClosed = false; window.appearance = nil; window.contentView = Canvas(); window.center()
    return window
}

final class TunnelEditorForm: NSObject {
    let content = Canvas()
    let name = NSTextField(), port = NSTextField(), destination = NSTextField()
    let connection = NSPopUpButton(frame:.zero,pullsDown:false), mode = NSPopUpButton(frame:.zero,pullsDown:false)
    let explanation = label("",size:11,color:muted)
    let connections: [Connection]
    init(connections: [Connection], profile: TunnelProfile?) {
        self.connections = connections; super.init()
        content.frame = NSRect(x:0,y:0,width:560,height:285)
        connection.addItems(withTitles:connections.map { "\($0.name) · \($0.destination)" })
        mode.addItems(withTitles:TunnelMode.allCases.map(\.title)); mode.target = self; mode.action = #selector(changed)
        for (i,pair) in [(L("Name"),name as NSView),(L("SSH connection"),connection),(L("Forwarding type"),mode),(L("Listen port"),port),(L("Destination host:port"),destination)].enumerated() {
            let text = label(pair.0,size:11,color:muted); text.frame = NSRect(x:0,y:CGFloat(i)*44+5,width:160,height:20)
            pair.1.frame = NSRect(x:165,y:CGFloat(i)*44,width:385,height:28); content.addSubview(text); content.addSubview(pair.1)
        }
        explanation.frame = NSRect(x:0,y:226,width:550,height:55); content.addSubview(explanation)
        name.stringValue = profile?.name ?? L("New tunnel"); port.stringValue = String(profile?.tunnel.localPort ?? 8080); destination.stringValue = profile?.tunnel.remote ?? "127.0.0.1:80"
        if let profile { mode.selectItem(at:TunnelMode.allCases.firstIndex(of:profile.tunnel.kind)!); if let index = connections.firstIndex(where:{$0.id == profile.tunnel.connection.id}) { connection.selectItem(at:index) } }
        changed()
    }
    @objc func changed() {
        let selected = TunnelMode.allCases[mode.indexOfSelectedItem]
        destination.isEnabled = selected != .dynamic
        switch selected {
        case .local: explanation.stringValue = L("Listen on this Mac's loopback address. The destination is reached from the SSH server.")
        case .remote: explanation.stringValue = L("Request a loopback listener on the SSH server; its GatewayPorts policy controls binding. The destination is reached from this Mac.")
        case .dynamic: explanation.stringValue = L("Create a loopback SOCKS4/5 proxy on this Mac. Applications choose their own destinations through the SSH server.")
        }
    }
    func value(id: UUID) throws -> TunnelProfile {
        try InputDelivery.validateName(name.stringValue)
        var tunnel = TunnelDescriptor(connection:connections[connection.indexOfSelectedItem],localPort:Int(port.stringValue) ?? 0,remote:destination.stringValue.trimmingCharacters(in:.whitespacesAndNewlines))
        tunnel.mode = TunnelMode.allCases[mode.indexOfSelectedItem]; tunnel.profileID = id
        try tunnel.validate(checkIdentity:false)
        return TunnelProfile(id:id,name:name.stringValue,tunnel:tunnel)
    }
}

final class TunnelManager: NSWindowController, NSWindowDelegate {
    weak var hostController: AppController?
    let store: ProductivityStore
    let chooser = NSPopUpButton(frame:.zero,pullsDown:false)
    let details = NSTextView()
    var profiles: [TunnelProfile] = []
    var timer: Timer?
    var startButton: ActionButton!, stopButton: ActionButton!
    init(hostController: AppController, store: ProductivityStore) {
        self.hostController = hostController; self.store = store
        super.init(window:toolWindow(L("SSH tunnels"),width:760,height:430)); window?.delegate = self
        guard let content = window?.contentView else { return }
        chooser.frame = NSRect(x:20,y:20,width:720,height:30); chooser.target = self; chooser.action = #selector(selectionChanged); content.addSubview(chooser)
        let scroll = NSScrollView(frame:NSRect(x:20,y:65,width:720,height:235)); scroll.hasVerticalScroller = true
        details.isEditable = false; details.font = .monospacedSystemFont(ofSize:12,weight:.regular); details.textContainer?.widthTracksTextView = true
        details.autoresizingMask = [.width]; details.frame = NSRect(x:0,y:0,width:700,height:235); scroll.documentView = details; content.addSubview(scroll)
        let items: [(String,()->Void)] = [(L("New"),{ [weak self] in self?.edit(new:true) }),(L("Edit"),{ [weak self] in self?.edit(new:false) }),(L("Delete"),{ [weak self] in self?.deleteSelected() }),(L("Show terminal"),{ [weak self] in self?.showTerminal() })]
        for (i,item) in items.enumerated() { let b = ActionButton(item.0,handler:item.1); b.frame = NSRect(x:20+CGFloat(i)*130,y:320,width:120,height:32); content.addSubview(b) }
        startButton = ActionButton(L("Start"),primary:true) { [weak self] in self?.startSelected() }; startButton.frame = NSRect(x:500,y:375,width:110,height:32)
        stopButton = ActionButton(L("Stop")) { [weak self] in self?.stopSelected() }; stopButton.frame = NSRect(x:630,y:375,width:110,height:32)
        content.addSubview(startButton); content.addSubview(stopButton)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval:0.3,repeats:true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder:NSCoder) { fatalError() }
    var selectedProfile: TunnelProfile? { profiles.indices.contains(chooser.indexOfSelectedItem) ? profiles[chooser.indexOfSelectedItem] : nil }
    func refresh() {
        guard let hostController else { return }
        let selectedID = selectedProfile?.id
        var values = store.data.tunnels
        values += hostController.managedTunnels.values.map(\.profile).filter { p in !values.contains(where:{$0.id == p.id}) }.sorted { $0.name < $1.name }
        if values.map({$0.id.uuidString+$0.name}) != profiles.map({$0.id.uuidString+$0.name}) {
            profiles = values; chooser.removeAllItems(); chooser.addItems(withTitles:values.map(\.name))
            if let index = values.firstIndex(where:{$0.id == selectedID}) { chooser.selectItem(at:index) }
        } else { profiles = values }
        guard let profile = selectedProfile else { details.string = L("No tunnel profiles. Create an SSH session, then choose New to save a tunnel."); startButton.isEnabled = false; stopButton.isEnabled = false; return }
        let run = hostController.managedTunnels[profile.id]
        details.string = L("\(profile.tunnel.summary)\n\nRoute: \(SessionRules.route(profile.tunnel.connection))\nStatus: \(run?.localizedState ?? L("Stopped"))\n\nAuthentication runs in a dedicated terminal. Other SSH terminals are independent. Stop or close the tunnel terminal to remove its listener. A successful forwarding setup does not guarantee the destination service is reachable.")
        startButton.isEnabled = run?.active != true; stopButton.isEnabled = run?.active == true
    }
    @objc func selectionChanged() { refresh() }
    func edit(new: Bool) {
        guard let hostController else { return }
        let previous = new ? nil : selectedProfile
        if !new && previous == nil { return }
        if let previous, hostController.managedTunnels[previous.id]?.active == true { hostController.showError(HarborError.message(L("Stop this tunnel before editing its configuration."))); return }
        var connections = hostController.store.connections.filter { $0.kind == "SSH" }
        if let previous, !connections.contains(where:{$0.id == previous.tunnel.connection.id}) { connections.append(previous.tunnel.connection) }
        if let current = hostController.currentConnection, current.kind == "SSH", !connections.contains(where:{$0.id == current.id}) { connections.append(current) }
        guard !connections.isEmpty else { hostController.showError(HarborError.message(L("Save an SSH session first, including its key or gateway settings."))); return }
        let form = TunnelEditorForm(connections:connections,profile:previous)
        let alert = NSAlert(); alert.messageText = new ? L("Save a tunnel profile") : L("Edit tunnel profile"); alert.window.appearance = nil; alert.accessoryView = form.content; alert.addButton(withTitle:L("Save")); alert.addButton(withTitle:L("Cancel"))
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let value = try form.value(id:previous?.id ?? UUID())
                try store.update { data in if let i = data.tunnels.firstIndex(where:{$0.id == value.id}) { data.tunnels[i] = value } else { data.tunnels.append(value) } }
                if let previous { hostController.managedTunnels.removeValue(forKey:previous.id) }
                refresh(); if let i = profiles.firstIndex(where:{$0.id == value.id}) { chooser.selectItem(at:i) }; refresh(); return
            } catch { hostController.showError(error) }
        }
    }
    func deleteSelected() {
        guard let hostController, let p = selectedProfile else { return }
        guard hostController.managedTunnels[p.id]?.active != true else { hostController.showError(HarborError.message(L("Stop this tunnel before deleting it."))); return }
        let alert = NSAlert(); alert.messageText = L("Delete \(p.name)?"); alert.addButton(withTitle:L("Delete profile")); alert.addButton(withTitle:L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            do { try store.update { $0.tunnels.removeAll { $0.id == p.id } }; hostController.managedTunnels.removeValue(forKey:p.id); refresh() } catch { hostController.showError(error) }
        }
    }
    func startSelected() { guard let hostController, let p = selectedProfile else { return }; do { _ = try hostController.startTunnel(p); refresh() } catch { hostController.showError(error) } }
    func stopSelected() { guard let p = selectedProfile else { return }; hostController?.managedTunnels[p.id]?.stop(); refresh() }
    func showTerminal() { guard let hostController, let p = selectedProfile, let tab = hostController.managedTunnels[p.id]?.tab, let i = hostController.tabs.firstIndex(where:{$0 === tab}) else { return }; hostController.window.makeKeyAndOrderFront(nil); hostController.selectTab(i) }
    func windowWillClose(_ notification:Notification) { timer?.invalidate(); timer = nil; hostController?.tunnelManager = nil }
}

private func editableText(_ view: NSTextView) {
    view.isRichText = false; view.font = .monospacedSystemFont(ofSize:13,weight:.regular)
    view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
}
final class BroadcastComposer: NSWindowController, NSWindowDelegate {
    weak var hostController: AppController?
    let targetScroll = NSScrollView(), targetContent = Canvas()
    let text = NSTextView(), status = label(L("Choose receiving terminals explicitly."),size:12,color:accent)
    var targets: [(UUID,NSButton)] = []
    init(hostController: AppController,text: String) {
        self.hostController = hostController
        super.init(window:toolWindow(L("Broadcast input — selected terminals only"),width:760,height:630)); window?.delegate = self
        guard let content = window?.contentView else { return }
        let heading = label(L("Receiving terminals"),size:14,weight:.semibold); heading.frame = NSRect(x:20,y:18,width:500,height:24); content.addSubview(heading)
        let refresh = ActionButton(L("Refresh targets")) { [weak self] in self?.refreshTargets() }; refresh.frame = NSRect(x:580,y:14,width:160,height:30); content.addSubview(refresh)
        targetScroll.frame = NSRect(x:20,y:55,width:720,height:185); targetScroll.hasVerticalScroller = true; targetScroll.documentView = targetContent; content.addSubview(targetScroll)
        let scroll = NSScrollView(frame:NSRect(x:20,y:255,width:720,height:230)); scroll.hasVerticalScroller = true
        self.text.frame = NSRect(x:0,y:0,width:700,height:230); editableText(self.text); self.text.string = text; scroll.documentView = self.text; content.addSubview(scroll)
        let note = label(L("Only this window sends to multiple terminals. Normal terminal typing stays local.\nEmbedded newlines may execute commands even without an added Return."),size:11,color:muted)
        note.frame = NSRect(x:20,y:495,width:720,height:44); content.addSubview(note)
        status.frame = NSRect(x:20,y:540,width:720,height:22); content.addSubview(status)
        let send = ActionButton(L("Send text")) { [weak self] in self?.send(submit:false) }; send.frame = NSRect(x:415,y:580,width:145,height:32)
        let execute = ActionButton(L("Send + Return"),primary:true) { [weak self] in self?.send(submit:true) }; execute.frame = NSRect(x:575,y:580,width:165,height:32)
        content.addSubview(send); content.addSubview(execute)
        refreshTargets()
    }
    required init?(coder:NSCoder) { fatalError() }
    func refreshTargets() {
        targets.forEach { $0.1.removeFromSuperview() }; targets = []
        guard let hostController else { return }
        for (i,tab) in hostController.tabs.filter(InputDelivery.eligible).enumerated() {
            let checkbox = NSButton(checkboxWithTitle:"\(tab.title)  [\(tab.connection?.destination ?? L("local")) · \(tab.id.uuidString.prefix(6))]",target:self,action:#selector(selectionChanged))
            checkbox.frame = NSRect(x:5,y:CGFloat(i)*30,width:680,height:28); checkbox.cell?.lineBreakMode = .byTruncatingTail
            checkbox.toolTip = checkbox.title; checkbox.state = .off; targets.append((tab.id,checkbox)); targetContent.addSubview(checkbox)
        }
        targetContent.frame = NSRect(x:0,y:0,width:700,height:max(185,CGFloat(targets.count)*30))
        status.stringValue = L("0 targets selected · refresh clears the selection")
    }
    @objc func selectionChanged() { status.stringValue = L("\(targets.filter {$0.1.state == .on}.count) targets selected") }
    func send(submit: Bool) {
        guard let hostController else { return }
        let ids = Set(targets.filter {$0.1.state == .on}.map(\.0))
        let value = text.string.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        do {
            let count = try InputDelivery.send(value,submit:submit,ids:ids,tabs:hostController.tabs)
            status.stringValue = L("Sent to \(count) terminals\(submit ? L(" + Return") : "") · command completion is not implied")
        } catch { status.stringValue = error.localizedDescription; status.toolTip = error.localizedDescription; hostController.showError(error) }
    }
    func windowWillClose(_ notification:Notification) { hostController?.broadcastComposer = nil }
}

final class SnippetManager: NSWindowController, NSWindowDelegate {
    weak var hostController: AppController?
    let store: ProductivityStore
    let chooser = NSPopUpButton(frame:.zero,pullsDown:false), name = NSTextField(), body = NSTextView()
    let status = label(L("Insert sends text without adding Return."),size:11,color:muted)
    private var loaded: CommandSnippet?
    init(hostController: AppController,store: ProductivityStore) {
        self.hostController = hostController; self.store = store
        super.init(window:toolWindow(L("Command snippets"),width:760,height:550)); window?.delegate = self
        guard let content = window?.contentView else { return }
        chooser.frame = NSRect(x:20,y:20,width:720,height:30); chooser.target = self; chooser.action = #selector(selected); content.addSubview(chooser)
        name.frame = NSRect(x:20,y:65,width:720,height:28); name.placeholderString = L("Snippet name"); content.addSubview(name)
        let scroll = NSScrollView(frame:NSRect(x:20,y:110,width:720,height:300)); scroll.hasVerticalScroller = true
        body.frame = NSRect(x:0,y:0,width:700,height:300); editableText(body); scroll.documentView = body; content.addSubview(scroll)
        status.frame = NSRect(x:20,y:420,width:720,height:40); content.addSubview(status)
        let items: [(String,()->Void)] = [(L("New"),{ [weak self] in self?.newSnippet() }),(L("Save"),{ [weak self] in self?.save() }),(L("Delete"),{ [weak self] in self?.delete() }),(L("Insert into current"),{ [weak self] in self?.insert() }),(L("Broadcast…"),{ [weak self] in guard let self else { return }; self.hostController?.openBroadcast(text:self.body.string) })]
        let widths: [CGFloat] = [85,85,85,180,150]; var x:CGFloat = 20
        for (i,item) in items.enumerated() { let b = ActionButton(item.0,handler:item.1); b.frame = NSRect(x:x,y:485,width:widths[i],height:32); x += widths[i]+10; content.addSubview(b) }
        reload(nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    var dirty: Bool { name.stringValue != (loaded?.name ?? "") || body.string != (loaded?.text ?? "") }
    func discard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = L("Discard unsaved snippet edits?"); alert.addButton(withTitle:L("Discard")); alert.addButton(withTitle:L("Keep editing"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func reload(_ id: UUID?) {
        chooser.removeAllItems(); chooser.addItem(withTitle:L("New snippet")); chooser.addItems(withTitles:store.data.snippets.map(\.name))
        loaded = store.data.snippets.first { $0.id == id }
        if let i = store.data.snippets.firstIndex(where:{$0.id == id}) { chooser.selectItem(at:i+1) }
        name.stringValue = loaded?.name ?? ""; body.string = loaded?.text ?? ""
    }
    @objc func selected() {
        let i = chooser.indexOfSelectedItem-1
        let id = store.data.snippets.indices.contains(i) ? store.data.snippets[i].id : nil
        if discard() { reload(id) }
        else { chooser.selectItem(at:loaded.flatMap { p in store.data.snippets.firstIndex(where:{$0.id == p.id}).map {$0+1} } ?? 0) }
    }
    func newSnippet() { if discard() { reload(nil) } }
    func save() {
        let value = CommandSnippet(id:loaded?.id ?? UUID(),name:name.stringValue,text:body.string)
        do {
            try store.update { data in if let i = data.snippets.firstIndex(where:{$0.id == value.id}) { data.snippets[i] = value } else { data.snippets.append(value) } }
            reload(value.id); status.stringValue = L("Saved · Insert does not add Return; embedded newlines may execute commands.")
        } catch { hostController?.showError(error) }
    }
    func delete() {
        guard let loaded else { return }
        let alert = NSAlert(); alert.messageText = L("Delete \(loaded.name)?"); alert.addButton(withTitle:L("Delete snippet")); alert.addButton(withTitle:L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.update { $0.snippets.removeAll { $0.id == loaded.id } }; reload(nil) } catch { hostController?.showError(error) }
    }
    func insert() {
        guard let hostController, hostController.tabs.indices.contains(hostController.selected) else { hostController?.showError(HarborError.message(L("Select a running local or SSH terminal first."))); return }
        let tab = hostController.tabs[hostController.selected]
        do { _ = try InputDelivery.send(body.string,submit:false,ids:[tab.id],tabs:hostController.tabs); status.stringValue = L("Inserted into \(tab.title) · Return was not added") }
        catch { hostController.showError(error) }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { discard() }
    func windowWillClose(_ notification:Notification) { hostController?.snippetManager = nil }
}

// Private FIFO taps script's output without retaining it until logging is requested.
// Legacy already exposes output directly. No engine modifications are needed.
final class LiveOutputTap {
    let directory: URL, fifo: URL
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var receive: ((Data)->Void)?
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-output-\(UUID().uuidString)")
        fifo = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        guard mkfifo(fifo.path,0o600) == 0 else { try? FileManager.default.removeItem(at:directory); throw HarborError.message(L("Cannot create terminal output pipe.")) }
        fd = Darwin.open(fifo.path,O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { try? FileManager.default.removeItem(at:directory); throw HarborError.message(L("Cannot open terminal output pipe.")) }
        let descriptor = fd
        let reader = DispatchSource.makeReadSource(fileDescriptor:fd,queue:.main)
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.setCancelHandler { Darwin.close(descriptor) }; source = reader; reader.resume()
    }
    func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating:0,count:32768)
        // Bounded work per dispatch keeps stop/cancel responsive under sustained output.
        for _ in 0..<128 {
            let n = Darwin.read(fd,&buffer,buffer.count)
            if n > 0 { receive?(Data(buffer.prefix(n))) }
            else if n < 0 && errno == EINTR { continue }
            else { break }
        }
    }
    func close() { guard fd >= 0 else { return }; drain(); source?.cancel(); source = nil; fd = -1; try? FileManager.default.removeItem(at:directory) }
    deinit { close() }
}

final class CurrentSessionLog {
    private var handle: FileHandle?
    private(set) var url: URL?
    var active: Bool { handle != nil }
    func start(_ url: URL) throws {
        guard !active else { throw HarborError.message(L("This terminal is already logging.")) }
        let fd = Darwin.open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw HarborError.message(L("Choose a new log file; existing files are never overwritten.")) }
        handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true); self.url = url
    }
    func append(_ data: Data) throws {
        guard let handle else { return }
        do { try handle.write(contentsOf:data) } catch { try? stop(); throw error }
    }
    func stop() throws {
        guard let file = handle else { return }; handle = nil
        defer { try? file.close() }; try file.synchronize()
    }
    deinit { try? stop() }
}


struct TerminalMacro: Codable {
    var format = "harbor-terminal-macro", version = 2
    var backend: String
    var events: [TerminalMacroEvent]
    func validate() throws {
        guard format == "harbor-terminal-macro", (1...2).contains(version), ["ghostty","legacy"].contains(backend), !events.isEmpty, events.count <= 10000 else { throw HarborError.message(L("Invalid or empty Harbor macro (maximum 10000 events).")) }
        var total = 0.0, bytes = 0
        for e in events {
            guard e.delay.isFinite, (0...60).contains(e.delay), ["text","raw","key"].contains(e.kind), !e.text.contains("\0"), e.text.utf8.count <= 65536,
                  e.key <= 127, e.action <= 2, e.modifiers <= 255, e.consumed <= 255, e.codepoint <= 0x10ffff,
                  !(backend == "legacy" && e.kind == "key"), !(backend == "ghostty" && e.kind == "raw") else { throw HarborError.message(L("Invalid macro input event.")) }
            total += e.delay; bytes += e.text.utf8.count
        }
        guard total <= 3600, bytes <= 1_048_576 else { throw HarborError.message(L("Macro exceeds one hour or 1 MiB of input.")) }
    }
    static func load(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 4_194_304 else { throw HarborError.message(L("Macro file exceeds 4 MiB.")) }
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url)); try value.validate(); return value
    }
    func save(_ url: URL) throws {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let fd = Darwin.open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw HarborError.message(L("Choose a new macro file; existing files are preserved.")) }
        let file = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? file.close() }
        try file.write(contentsOf:encoder.encode(self)); try file.synchronize()
    }
}

extension AppController {
    func automationTerminal() throws -> TerminalTab {
        guard tabs.indices.contains(selected), selectedDesktop == nil else { throw HarborError.message(L("Select a terminal first.")) }
        let tab = tabs[selected]
        guard tab.tunnel == nil, !tab.closing else { throw HarborError.message(L("Select a terminal, not a tunnel.")) }
        return tab
    }
    @objc func startCurrentLog() {
        do {
            let tab = try automationTerminal()
            guard tab.view.acceptsProgrammaticInput, !tab.view.liveLog.active, tab.recordingURL == nil else { throw HarborError.message(L("Select a running terminal that is not already logging.")) }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Harbor-current-\(Int(Date().timeIntervalSince1970)).log"
            panel.message = L("Save raw output from this point onward, including echoed input and escape sequences. The connection stays open.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard tab.running, !tab.closing else { throw HarborError.message(L("The terminal ended while choosing a file.")) }
            try tab.view.startLiveLog(url); workspace.refreshTabs()
            workspace.status.stringValue = L("● Logging · \(tab.title)"); workspace.status.toolTip = url.path
        } catch { showError(error) }
    }
    @objc func stopCurrentLog() {
        do { let tab = try automationTerminal(); try tab.view.stopLiveLog(); workspace.refreshTabs(); workspace.status.stringValue = L("Log stopped · \(tab.title)") } catch { showError(error) }
    }
    @objc func exportTerminalHistory() {
        do {
            let tab = try automationTerminal()
            guard let text = tab.view.transcript() else { throw HarborError.message(L("Terminal history is unavailable.")) }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Harbor-history.txt"
            panel.message = L("Export the currently retained scrollback and screen as UTF-8 text. Evicted history and alternate-screen history cannot be recovered.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let file = CurrentSessionLog(); try file.start(url); try file.append(Data(text.utf8)); try file.stop()
            workspace.status.stringValue = L("History exported · \(tab.title)")
        } catch { showError(error) }
    }
    @objc func startMacroRecording() {
        do {
            let tab = try automationTerminal()
            guard macroSource == nil else { throw HarborError.message(L("Save or discard the previous recording first.")) }
            guard tab.view.acceptsProgrammaticInput, !tab.view.macroPlaying else { throw HarborError.message(L("Select a running terminal that is not replaying a macro.")) }
            let alert = NSAlert(); alert.messageText = L("Record input in \(tab.title)?")
            alert.informativeText = L("Records keyboard input and pasted text, including passwords if you type them. Start after authentication. Mouse actions are not recorded. Switching tabs does not change the recording target.")
            alert.addButton(withTitle:L("Record")); alert.addButton(withTitle:L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try tab.view.beginMacro(); macroSource = tab.view
            workspace.status.stringValue = L("● Macro recording · \(tab.title)"); workspace.refreshTabs()
        } catch { showError(error) }
    }
    @objc func saveMacroRecording() {
        guard let source = macroSource else { showError(HarborError.message(L("No pending macro recording."))); return }
        source.endMacro()
        do {
            let value = TerminalMacro(backend:source.backend.rawValue,events:source.macroEvents); try value.validate()
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Harbor-macro.json"; panel.message = L("Input is stored as readable JSON. Cancel keeps this stopped recording available for Save or Discard.")
            guard panel.runModal() == .OK, let url = panel.url else { workspace.refreshTabs(); return }
            try value.save(url); source.clearMacro(); macroSource = nil; workspace.refreshTabs(); workspace.status.stringValue = L("Macro saved")
        } catch { workspace.refreshTabs(); showError(error) }
    }
    @objc func discardMacroRecording() { macroSource?.clearMacro(); macroSource = nil; workspace.refreshTabs(); workspace.status.stringValue = L("Macro discarded") }
    @objc func replayMacro() {
        do {
            let tab = try automationTerminal()
            guard macroSource == nil else { throw HarborError.message(L("Save or discard the recording before playback.")) }
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let value = try TerminalMacro.load(url)
            guard value.backend == tab.view.backend.rawValue else { throw HarborError.message(L("This macro requires the \(value.backend) terminal engine.")) }
            let alert = NSAlert(); alert.messageText = L("Replay \(value.events.count) events in \(tab.title)?")
            alert.informativeText = L("Playback can execute commands. The target stays fixed even if you switch tabs. Session → Cancel macro playback stops future events; commands already sent keep running. Review the input below.")
            alert.accessoryView = Self.textArea(value.events.map { L("\(L10n.text($0.kind)) key=\($0.key) mods=\($0.modifiers) action=\($0.action) text=\(String(reflecting:$0.text))") }.joined(separator:"\n"))
            alert.addButton(withTitle:L("Replay")); alert.addButton(withTitle:L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try tab.view.playMacro(value); workspace.status.stringValue = L("▶ Macro playback · \(tab.title)"); workspace.refreshTabs()
        } catch { showError(error) }
    }
    @objc func cancelMacroPlayback() { for tab in tabs { tab.view.cancelMacro() }; workspace.refreshTabs(); workspace.status.stringValue = L("Macro playback stopped") }
}
