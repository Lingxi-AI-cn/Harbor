import AppKit

struct DesktopGateway: Codable, Equatable {
    var name: String, host: String, user: String, identity: String
    var port: Int
    var jumpHosts: String?
    var isolatedSSHConfig: Bool?
    init(_ c: Connection) { name=c.name; host=c.host; user=c.user; identity=c.identity; port=c.port; jumpHosts=c.jumpHosts; isolatedSSHConfig=c.isolatedSSHConfig }
    var connection: Connection {
        var c = Connection(name:name,host:host,user:user,port:port,identity:identity)
        c.jumpHosts=jumpHosts; c.isolatedSSHConfig=isolatedSSHConfig; c.forwardAgent=false; c.keepAlive=true
        return c
    }
}
struct DesktopSettings: Codable, Equatable {
    var embedded: Bool? = nil
    var width = 1440, height = 900
    var fullscreen = false
    var clipboard = false
    var domain = ""
    var gateway: DesktopGateway? = nil
    var localPort = 13389
    func validate(checkIdentity: Bool = true) throws {
        guard (640...8192).contains(width), (480...8192).contains(height), (1024...65535).contains(localPort),
              domain.utf8.count <= 256, !domain.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw HarborError.message(L("Desktop dimensions must be 640–8192 × 480–8192; local port 1024–65535. Domain cannot contain control characters.")) }
        if embedded == true && width*height > 16*1024*1024 { throw HarborError.message(L("Embedded desktops are limited to 16 million pixels (64 MiB).")) }
        if let gateway { try gateway.connection.validate(checkIdentity:checkIdentity) }
    }
}
enum DesktopConfiguration {
    static func clientReport() -> String {
        let rdp=NSWorkspace.shared.urlForApplication(toOpen:URL(fileURLWithPath:"/tmp/Harbor-client-probe.rdp"))
        let vnc=NSWorkspace.shared.urlForApplication(toOpen:URL(string:"vnc://127.0.0.1:5900")!)
        return L("Default RDP handler: \(rdp?.lastPathComponent ?? L("Not found"))\nDefault VNC handler: \(vnc?.lastPathComponent ?? L("Not found"))")
    }
    static func endpoint(_ c: Connection) -> (String,Int) { c.desktop?.gateway == nil ? (c.host,c.port) : ("127.0.0.1",c.desktop!.localPort) }
    static func address(_ host: String,_ port: Int) -> String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }
    static func rdp(_ c: Connection) throws -> String {
        try c.validate(checkIdentity:false)
        guard c.kind == "RDP" else { throw HarborError.message(L("Not an RDP session.")) }
        let d = c.desktop ?? DesktopSettings(), (host,port) = endpoint(c)
        return ["full address:s:\(address(host,port))","username:s:\(c.user)","domain:s:\(d.domain)",
                "screen mode id:i:\(d.fullscreen ? 2 : 1)","desktopwidth:i:\(d.width)","desktopheight:i:\(d.height)",
                "redirectclipboard:i:\(d.clipboard ? 1 : 0)","redirectdrives:i:0","drivestoredirect:s:","redirectprinters:i:0","audiomode:i:2",
                "prompt for credentials:i:1","authentication level:i:2","enablecredsspsupport:i:1"].joined(separator:"\r\n")+"\r\n"
    }
    static func vnc(_ c: Connection) throws -> URL {
        try c.validate(checkIdentity:false)
        let (host,port) = endpoint(c)
        guard var parts = URLComponents(string:"vnc://\(address(host,port))") else { throw HarborError.message(L("Invalid VNC endpoint.")) }
        if !c.user.isEmpty { parts.user = c.user }
        guard let url = parts.url else { throw HarborError.message(L("Invalid VNC address.")) }; return url
    }
}

final class DesktopRun {
    let id = UUID(), connection: Connection, directory: URL
    var state = L("Preparing")
    var active = true
    var closed=false
    private(set) var handedOff = false
    private(set) var target: URL?
    var viewer: EmbeddedDesktop?
    private var password = ""
    var tunnel: TunnelRun?
    weak var owner: AppController?
    private var timer: Timer?
    // Injection points are used by acceptance tests; production uses LaunchServices.
    var resolveClient: (URL)->URL? = { NSWorkspace.shared.urlForApplication(toOpen:$0) }
    var openClient: (URL,URL,@escaping(Error?)->Void)->Void = { url,client,completion in
        NSWorkspace.shared.open([url],withApplicationAt:client,configuration:NSWorkspace.OpenConfiguration()) { _,error in DispatchQueue.main.async { completion(error) } }
    }
    init(_ connection: Connection, owner: AppController) throws {
        self.connection=connection; self.owner=owner
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("harbor-desktop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    func start(configurationFile: String? = nil) throws {
        do {
            try connection.validate()
            let embedded=connection.desktop?.embedded == true
            if embedded {
                guard FileManager.default.isExecutableFile(atPath:EmbeddedDesktop.helper.path) else { throw HarborError.message(L("Embedded desktop engine is missing from this build.")) }
                let alert=NSAlert();alert.messageText=L("Connect to \(connection.name)")
                alert.informativeText=connection.kind == "VNC" ? L("VNC password (maximum 8 bytes). RFB traffic is unencrypted; use the SSH route for untrusted networks. TLS/VeNCrypt and Apple authentication are not supported.") : L("RDP password for \(connection.user). Credentials are used for this connection only.")
                let field=NSSecureTextField(frame:NSRect(x:0,y:0,width:350,height:28));alert.accessoryView=field;alert.addButton(withTitle:L("Connect"));alert.addButton(withTitle:L("Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { throw HarborError.message(L("Connection cancelled.")) }
                password=field.stringValue;field.stringValue=""
                guard password.utf8.count <= (connection.kind == "VNC" ? 8:4096) else { throw HarborError.message(L("Password exceeds the supported length.")) }
                target=EmbeddedDesktop.helper
            } else if connection.kind == "RDP" {
                let url=directory.appendingPathComponent("connection.rdp")
                try Data(DesktopConfiguration.rdp(connection).utf8).write(to:url,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path); target=url
            } else if connection.kind == "VNC" { target=try DesktopConfiguration.vnc(connection) }
            else { throw HarborError.message(L("Choose an RDP or VNC session.")) }
            guard let target, let client=embedded ? EmbeddedDesktop.helper : resolveClient(target) else { throw HarborError.message(connection.kind == "RDP" ? L("No installed application handles .rdp files. Install or select a compatible RDP client in macOS, then retry. No SSH tunnel was started.") : L("No installed application handles vnc:// addresses. Enable an appropriate Screen Sharing/VNC client, then retry. No SSH tunnel was started.")) }
            if let d=connection.desktop, let gateway=d.gateway, let owner {
                var descriptor=TunnelDescriptor(connection:gateway.connection,localPort:d.localPort,remote:DesktopConfiguration.address(connection.host,connection.port))
                descriptor.mode = .local
                let profile=TunnelProfile(name:"\(connection.kind) · \(connection.name)",tunnel:descriptor)
                _ = try owner.startTunnel(profile,configurationFile:configurationFile)
                tunnel=owner.managedTunnels[profile.id]; state=L("Waiting for SSH authentication and forwarding")
                timer=Timer(timeInterval:0.2,repeats:true) { [weak self] _ in self?.advance(client:client) }
                if let timer { RunLoop.main.add(timer,forMode:.common) }
            } else { handoff(client:client) }
        } catch { fail(error); throw error }
    }
    private func advance(client: URL) {
        guard active, let tunnel else { return }
        if !tunnel.active {
            if handedOff { state=L("Tunnel ended"); active=false; viewer?.stop(closeWindow:false); cleanup() }
            else { fail(HarborError.message(tunnel.localizedState)) }
        } else if tunnel.forwarding && !handedOff { handoff(client:client) }
    }
    private func handoff(client: URL) {
        guard active, !handedOff, let target else { return }
        handedOff=true
        if connection.desktop?.embedded == true {
            do { let view=EmbeddedDesktop(run:self);viewer=view;try view.start(password:password);password="";state=L("Connecting embedded desktop…") }
            catch { password="";fail(error) };return
        }
        state=L("Opening external client…")
        openClient(target,client) { [weak self] error in
            guard let self, self.active else { return }
            if let error { self.fail(error) }
            else { self.state=L("Handed to \(client.deletingPathExtension().lastPathComponent) · desktop connection unverified") }
        }
    }
    func fail(_ error: Error) { password="";viewer?.stop();state=L("Failed · \(error.localizedDescription)"); active=false; tunnel?.stop(); cleanup() }
    func stop() { active=false; password="";viewer?.stop();tunnel?.stop(); state=connection.desktop?.embedded == true ? L("Stopped") : L("Stopped · external client is not closed by Harbor"); cleanup() }
    func cleanup() { timer?.invalidate(); timer=nil; try? FileManager.default.removeItem(at:directory) }
    deinit { timer?.invalidate(); try? FileManager.default.removeItem(at:directory) }
}

final class DesktopManager: NSWindowController, NSWindowDelegate {
    weak var hostController: AppController?
    let chooser=NSPopUpButton(frame:.zero,pullsDown:false), details=NSTextView()
    let stopButton=ActionButton(L("Stop and clean up"),handler:{})
    var runs: [DesktopRun]=[], timer: Timer?
    init(owner: AppController) {
        hostController=owner
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:440),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title=L("Desktop sessions"); w.isReleasedWhenClosed=false; w.appearance=nil; w.contentView=Canvas(); w.center()
        super.init(window:w); w.delegate=self
        chooser.frame=NSRect(x:20,y:20,width:720,height:30); chooser.target=self; chooser.action = #selector(changed); w.contentView?.addSubview(chooser)
        let scroll=NSScrollView(frame:NSRect(x:20,y:65,width:720,height:285)); scroll.hasVerticalScroller=true
        details.isEditable=false; details.font = .monospacedSystemFont(ofSize:12,weight:.regular); details.frame=NSRect(x:0,y:0,width:700,height:285); details.autoresizingMask = [.width]; details.textContainer?.widthTracksTextView=true
        scroll.documentView=details; w.contentView?.addSubview(scroll)
        stopButton.frame=NSRect(x:490,y:380,width:250,height:32); stopButton.handler={ [weak self] in self?.stopSelected() }; w.contentView?.addSubview(stopButton)
        refresh(); timer=Timer.scheduledTimer(withTimeInterval:0.3,repeats:true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder:NSCoder) { fatalError() }
    var selected: DesktopRun? { runs.indices.contains(chooser.indexOfSelectedItem) ? runs[chooser.indexOfSelectedItem] : nil }
    @objc func changed() { refresh() }
    func refresh() {
        let id=selected?.id; let values=hostController?.desktopRuns ?? []
        if values.map(\.id) != runs.map(\.id) { runs=values; chooser.removeAllItems(); chooser.addItems(withTitles:runs.map { "\($0.connection.kind) · \($0.connection.name)" }); if let i=runs.firstIndex(where:{$0.id == id}) { chooser.selectItem(at:i) } }
        guard let run=selected else { details.string=L("No external desktop sessions. Create an RDP or VNC session, configure Desktop options, then connect.\n\n")+DesktopConfiguration.clientReport(); stopButton.isEnabled=false; return }
        let c=run.connection, e=DesktopConfiguration.endpoint(c)
        details.string=L("Target: \(c.host):\(c.port)\nClient endpoint: \(DesktopConfiguration.address(e.0,e.1))\nRoute: \(c.desktop?.gateway.map { SessionRules.route($0.connection) } ?? L("Direct"))\nStatus: \(run.state)\nTunnel: \(run.tunnel?.localizedState ?? L("Not used"))\n\nHarbor confirms client handoff only, not successful login or desktop display. Stop releases this session's SSH tunnel and temporary configuration; it does not quit an external client or its other sessions.\n\nFor tunneled RDP, the client connects to localhost. Check the remote server identity in the client's certificate prompt; Harbor does not disable certificate checks.")
        if c.desktop?.embedded == true { details.string=L("Embedded \(c.kind) · \(c.name)\nTarget: \(c.host):\(c.port)\nStatus: \(run.state)\nTunnel: \(run.tunnel?.localizedState ?? L("Not used"))\n\nClose the viewer or Stop to disconnect. Text clipboard is available through the desktop toolbar. Audio and drive redirection are not supported.") }
        stopButton.isEnabled=run.active
    }
    func stopSelected() { guard let run=selected, run.active else { return }; run.stop(); refresh() }
    func windowWillClose(_ n:Notification) { timer?.invalidate(); timer=nil; hostController?.desktopManager=nil }
}

final class DesktopOptionsForm: NSObject {
    let view=Canvas(), width=NSTextField(), height=NSTextField(), domain=NSTextField(), port=NSTextField()
    let fullscreen=NSButton(checkboxWithTitle:L("Full screen"),target:nil,action:nil), clipboard=NSButton(checkboxWithTitle:L("Share clipboard with remote desktop"),target:nil,action:nil)
    let embedded=NSButton(checkboxWithTitle:L("Embedded viewer (text clipboard via toolbar)"),target:nil,action:nil)
    let route=NSPopUpButton(frame:.zero,pullsDown:false)
    let gateways: [DesktopGateway]
    var isRDP=false
    init(kind: String, current: DesktopSettings, connections: [Connection]) {
        var values=connections.filter { $0.kind == "SSH" }.map(DesktopGateway.init)
        if let saved=current.gateway, !values.contains(saved) { values.append(saved) }
        gateways=values; super.init();isRDP=kind == "RDP"
        view.frame=NSRect(x:0,y:0,width:570,height:400)
        route.addItem(withTitle:L("Direct connection")); route.addItems(withTitles:values.map { "\($0.name) · \($0.host):\($0.port)" })
        if let saved=current.gateway, let i=values.firstIndex(of:saved) { route.selectItem(at:i+1) }
        width.stringValue=String(current.width); height.stringValue=String(current.height); domain.stringValue=current.domain; port.stringValue=String(current.localPort)
        embedded.state=current.embedded != false ? .on:.off
        embedded.target=self;embedded.action = #selector(modeChanged)
        embedded.frame=NSRect(x:165,y:280,width:395,height:24);view.addSubview(embedded)
        fullscreen.state=current.fullscreen ? .on : .off; clipboard.state=current.clipboard ? .on : .off
        let rows: [(String,NSView)] = [(L("SSH route"),route),(L("Local tunnel port"),port),(L("RDP width"),width),(L("RDP height"),height),(L("RDP domain"),domain)]
        for (i,row) in rows.enumerated() { let y=CGFloat(i*43); let title=label(row.0,size:12,color:muted); title.frame=NSRect(x:0,y:y+5,width:155,height:24); row.1.frame=NSRect(x:165,y:y,width:395,height:28); view.addSubview(title); view.addSubview(row.1) }
        fullscreen.frame=NSRect(x:165,y:220,width:250,height:24); clipboard.frame=NSRect(x:165,y:250,width:395,height:24); view.addSubview(fullscreen); view.addSubview(clipboard)
        for control in [width,height,domain] { control.isEnabled=kind == "RDP" }; fullscreen.isEnabled=kind == "RDP"; clipboard.isEnabled=kind == "RDP"
        let note=label(L("SSH route saves a snapshot of the selected SSH session, including gateways.\nDesktop target host is resolved from the SSH server. Client settings and\ncertificate prompts depend on the selected viewer."),size:11,color:muted)
        note.frame=NSRect(x:0,y:325,width:560,height:60); view.addSubview(note);modeChanged()
    }
    @objc func modeChanged() { clipboard.isEnabled=isRDP && embedded.state == .off }
    func value() throws -> DesktopSettings {
        let i=route.indexOfSelectedItem-1
        let value=DesktopSettings(embedded:embedded.state == .on,width:Int(width.stringValue) ?? 0,height:Int(height.stringValue) ?? 0,fullscreen:fullscreen.state == .on,clipboard:clipboard.state == .on,domain:domain.stringValue,gateway:gateways.indices.contains(i) ? gateways[i] : nil,localPort:Int(port.stringValue) ?? 0)
        try value.validate(checkIdentity:false); return value
    }
}

extension ConnectionEditor {
    @objc func desktopOptions() {
        let form=DesktopOptionsForm(kind:type.titleOfSelectedItem ?? "RDP",current:desktopSettings,connections:owner?.store.connections ?? [])
        let alert=NSAlert(); alert.window.appearance=nil; alert.messageText=L("Desktop options"); alert.accessoryView=form.view
        alert.addButton(withTitle:L("Apply")); alert.addButton(withTitle:L("Cancel"))
        while alert.runModal() == .alertFirstButtonReturn { do { desktopSettings=try form.value(); return } catch { owner?.showError(error) } }
    }
}
extension AppController {
    func connectDesktop(_ c: Connection) throws {
        var selected=c
        if selected.desktop == nil { selected.desktop=DesktopSettings() }
        if selected.desktop?.embedded == nil { selected.desktop?.embedded=true }
        let run=try DesktopRun(selected,owner:self)
        desktopRuns.removeAll { $0.closed || (!$0.active && $0.viewer == nil) }
        desktopRuns.append(run)
        do { try run.start(); recordRecent(c); if selected.desktop?.embedded != true || run.viewer == nil { showDesktopSessions() } }
        catch { showDesktopSessions(); throw error }
    }
    func selectDesktop(_ run:DesktopRun) {
        guard let viewer=run.viewer,!run.closed else{return}
        if let previous=selectedDesktop,previous !== run{previous.viewer?.surface.releaseKeys()}
        selectedDesktop=run;selected = -1;workspace.showFiles(nil);workspace.showTerminal(viewer.content);workspace.refreshTabs();window.makeKeyAndOrderFront(nil);window.makeFirstResponder(viewer.surface)
    }
    func removeDesktop(_ run:DesktopRun) {
        run.closed=true
        if selectedDesktop === run {selectedDesktop=nil;if let next=desktopRuns.last(where:{$0 !== run && !$0.closed && $0.viewer != nil}){selectDesktop(next)}else{selectTab(tabs.isEmpty ? -1:tabs.count-1)}}
        workspace.refreshTabs()
    }
    @objc func showDesktopSessions() {
        if let desktopManager { desktopManager.showWindow(nil); return }
        let manager=DesktopManager(owner:self); desktopManager=manager; manager.showWindow(nil)
    }
    @objc func x11Diagnostics() {
        while true {
            let alert=NSAlert(); alert.messageText=L("X11 environment"); alert.informativeText=X11Support.report()
            alert.addButton(withTitle:L("Close")); alert.addButton(withTitle:L("Refresh")); alert.addButton(withTitle:L("Open XQuartz"))
            alert.buttons[2].isEnabled=X11Support.application != nil
            let answer=alert.runModal()
            if answer == .alertFirstButtonReturn { return }
            if answer == .alertThirdButtonReturn, let url=X11Support.application { NSWorkspace.shared.open(url); return }
        }
    }
}
enum X11Support {
    static var application: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier:"org.xquartz.X11") ?? ["/Applications/Utilities/XQuartz.app","/Applications/XQuartz.app"].first(where: { FileManager.default.fileExists(atPath:$0) }).map { URL(fileURLWithPath:$0) }
    }
    static var xauthAvailable: Bool { FileManager.default.isExecutableFile(atPath:"/opt/X11/bin/xauth") }
    static func display() -> String? {
        if let value=ProcessInfo.processInfo.environment["DISPLAY"], validDisplay(value) { return value }
        let p=Process(), pipe=Pipe(); p.executableURL=URL(fileURLWithPath:"/bin/launchctl"); p.arguments=["getenv","DISPLAY"]; p.standardOutput=pipe; p.standardError=FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timeout=DispatchWorkItem { if p.isRunning { p.terminate() } }; DispatchQueue.global().asyncAfter(deadline:.now()+2,execute:timeout)
        p.waitUntilExit(); timeout.cancel()
        let value=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        return p.terminationStatus == 0 && validDisplay(value) ? value : nil
    }
    static func validDisplay(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) }
    static func preflight() throws -> String {
        guard application != nil else { throw HarborError.message(L("X11 requires XQuartz. See Session → X11 environment…; Harbor does not install it automatically.")) }
        guard xauthAvailable else { throw HarborError.message(L("XQuartz xauth is missing at /opt/X11/bin/xauth. Repair the XQuartz installation before connecting.")) }
        guard let display=display() else { throw HarborError.message(L("No DISPLAY is available for X11 forwarding. Open XQuartz and refresh Session → X11 environment… before reconnecting.")) }
        return display
    }
    static func report() -> String {
        L("XQuartz: \(application?.path ?? L("Not installed"))\nxauth: \(xauthAvailable ? "/opt/X11/bin/xauth" : L("Not found"))\nDISPLAY: \(display() ?? L("Not available"))\n\nSSH uses untrusted X11 forwarding (-X). Harbor does not enable trusted forwarding (-Y), change xhost access or edit server settings. Open XQuartz if DISPLAY is missing; after a new installation a login restart may be needed.\n\nRemote requirements: sshd permits X11 forwarding, remote xauth is available, and an X11 application is installed. Local checks do not establish that a remote window can be displayed. Remote OpenSSH errors can be inspected through Connection diagnostics.")
    }
}
