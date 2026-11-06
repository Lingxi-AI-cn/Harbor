import AppKit
let app=NSApplication.shared; app.setActivationPolicy(.regular)
let controller=AppController(); app.delegate=controller
var assertions=0,failures=0
func check(_ value: Bool,_ name: String) { assertions += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !value { failures += 1 } }
func rejects(_ name: String,_ work: () throws -> Void) { do { try work(); check(false,name) } catch { check(true,name) } }
func until(_ seconds: Double = 6,_ condition: ()->Bool) -> Bool { let end=Date().addingTimeInterval(seconds); while !condition() && Date()<end { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }; return condition() }
let root=FileManager.default.temporaryDirectory.appendingPathComponent("harbor-desktop-tests-\(UUID().uuidString)")
Timer.scheduledTimer(withTimeInterval:0.2,repeats:false) { _ in
    if controller.window == nil { controller.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification)) }
    var owned=[DesktopRun]()
    do {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        controller.store=try SessionStore(url:root.appendingPathComponent("sessions.json"))
        var rdp=Connection(name:"Desktop",host:"windows.example.invalid",user:"DOMAIN\\alice@example.com",port:3389,kind:"RDP")
        rdp.desktop=DesktopSettings(width:1920,height:1080,fullscreen:true,clipboard:true,domain:"DOMAIN")
        let config=try DesktopConfiguration.rdp(rdp)
        check(config.contains("desktopwidth:i:1920\r\n") && config.contains("desktopheight:i:1080\r\n") && config.contains("screen mode id:i:2"),"RDP dimensions and fullscreen are encoded")
        check(config.contains("domain:s:DOMAIN") && config.contains("username:s:DOMAIN\\alice@example.com"),"RDP domain and domain/email username preserved")
        check(config.contains("redirectclipboard:i:1") && config.contains("redirectdrives:i:0") && config.contains("authentication level:i:2") && !config.contains("password"),"clipboard explicit; drive sharing disabled; certificate policy and credential prompts retained")
        var invalid=rdp; invalid.host="host\nredirectdrives:i:1"
        rejects("host cannot inject RDP properties") { _=try DesktopConfiguration.rdp(invalid) }
        invalid=rdp; invalid.user="alice\r\npassword:s:bad"; rejects("username cannot inject properties") { try invalid.validate() }
        invalid=rdp; invalid.desktop?.domain="domain\nfoo"; rejects("domain cannot inject properties") { try invalid.validate() }
        invalid=rdp; invalid.desktop?.width=1; rejects("invalid resolution rejected") { try invalid.validate() }
        var vnc=Connection(name:"VNC",host:"2001:db8::1",user:"user name@domain",port:5901,kind:"VNC")
        let url=try DesktopConfiguration.vnc(vnc)
        check(url.absoluteString.contains("[2001:db8::1]:5901") && url.absoluteString.contains("user%20name%40domain"),"VNC URL encodes username and brackets IPv6")
        var gateway=Connection(name:"Gateway",host:"jump.example.invalid",user:"jumpuser",port:2222)
        gateway.jumpHosts="first,second"; gateway.isolatedSSHConfig=true
        rdp.desktop?.gateway=DesktopGateway(gateway); rdp.desktop?.localPort=23389
        try controller.saveConnection(rdp)
        let restored=try SessionStore(url:controller.store.url)
        check(restored.connections.first?.desktop == rdp.desktop,"desktop settings and gateway snapshot persist")
        check(try SessionArchive.decode(SessionArchive(connections:[rdp]).data()).first?.desktop == rdp.desktop,"desktop settings survive archive roundtrip")
        check(rdp.desktop?.gateway?.connection.command().1.contains("first,second") == true,"gateway retains multihop SSH route")
        check(try DesktopConfiguration.rdp(rdp).contains("full address:s:127.0.0.1:23389"),"tunneled RDP targets only loopback endpoint")
        vnc.desktop=rdp.desktop
        check(try DesktopConfiguration.vnc(vnc).port == 23389,"VNC tunnel endpoint uses configured local port")
        let form=DesktopOptionsForm(kind:"RDP",current:rdp.desktop!,connections:[])
        var expectedForm=rdp.desktop!;expectedForm.embedded=true
        check(try form.value() == expectedForm,"editor preserves saved gateway even if source SSH session is absent")
        rdp.desktop?.gateway=nil
        func makeRun(_ c: Connection) throws -> DesktopRun { let run=try DesktopRun(c,owner:controller); owned.append(run); run.resolveClient={ _ in URL(fileURLWithPath:"/Applications/Fixture.app") }; return run }
        let direct=try makeRun(rdp); var handoffs=0
        direct.openClient={ url,_,completion in handoffs += 1; check((try? String(contentsOf:url,encoding:.utf8))?.contains("windows.example.invalid:3389") == true,"client receives actual RDP file"); completion(nil) }
        try direct.start()
        check(handoffs == 1 && direct.state.contains("unverified"),"successful handoff does not claim desktop connected")
        check(try (FileManager.default.attributesOfItem(atPath:direct.directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700,"desktop directory is owner-only")
        check(try (FileManager.default.attributesOfItem(atPath:direct.target!.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,"RDP config is owner-only")
        direct.stop(); check(!FileManager.default.fileExists(atPath:direct.directory.path),"explicit stop removes temporary RDP config")
        vnc.desktop=nil
        let directVNC=try makeRun(vnc); var vncURL: URL?
        directVNC.openClient={ url,_,done in vncURL=url;done(nil) }; try directVNC.start()
        check(vncURL?.scheme == "vnc" && directVNC.target?.isFileURL == false,"VNC handoff uses URL without creating credential files")
        directVNC.stop()
        let pending=try makeRun(rdp); var completeLater: ((Error?)->Void)?
        pending.openClient={ _,_,done in completeLater=done }; try pending.start(); pending.stop(); completeLater?(nil)
        check(!pending.active && pending.state.hasPrefix("Stopped"),"late client callback cannot revive a stopped session")
        let missing=try makeRun(rdp); missing.resolveClient={ _ in nil }; let before=controller.tabs.count
        rejects("missing client produces actionable error") { try missing.start() }
        check(!missing.active && controller.tabs.count == before && !FileManager.default.fileExists(atPath:missing.directory.path),"missing client cleans files without starting SSH")
        let failed=try makeRun(rdp); failed.openClient={ _,_,completion in completion(HarborError.message("Fixture launch rejected")) }; try failed.start()
        check(!failed.active && failed.state.contains("Fixture launch rejected") && !FileManager.default.fileExists(atPath:failed.directory.path),"asynchronous client launch failure cleans configuration")
        check(!X11Support.validDisplay("") && !X11Support.validDisplay("display\ninvalid") && X11Support.validDisplay("/private/tmp/launchd/org.xquartz:0"),"X11 DISPLAY validation accepts socket form and rejects control characters")
        let report=X11Support.report(); check(report.contains("XQuartz:") && report.contains("DISPLAY:") && report.contains("Remote requirements:"),"local X11 diagnostics report dependencies and remote boundary")
        var x=Connection(name:"X11",host:"example.invalid",user:"test"); x.x11=true
        check(x.command().1.contains("-X") && x.command().1.contains("XAuthLocation=/opt/X11/bin/xauth") && !x.command().1.contains("-Y"),"X11 uses explicit xauth and untrusted forwarding")
        let env=ProcessInfo.processInfo.environment
        guard let sshConfig=env["HARBOR_P2_CONFIG"], let sshPort=Int(env["HARBOR_P2_PORT"] ?? ""), let httpPort=Int(env["HARBOR_P2_HTTP"] ?? "") else { throw HarborError.message("Missing loopback fixture") }
        let ports=env["HARBOR_P2_LISTEN"]!.split(separator:",").map { Int($0)! }
        gateway=Connection(name:"Ephemeral gateway",host:"127.0.0.1",user:env["HARBOR_P2_USER"]!,port:sshPort,identity:env["HARBOR_P2_KEY"]!)
        func fetch(_ port: Int) -> Bool { let p=Process(),pipe=Pipe(); p.executableURL=URL(fileURLWithPath:"/usr/bin/curl");p.arguments=["--silent","--max-time","2","--noproxy","*","http://127.0.0.1:\(port)/"];p.standardOutput=pipe;p.standardError=FileHandle.nullDevice;do { try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();return p.terminationStatus == 0 && String(decoding:data,as:UTF8.self)=="HARBOR_P2_FORWARD_OK" } catch { return false } }
        rdp.host="127.0.0.1"; rdp.port=httpPort; rdp.desktop?.gateway=DesktopGateway(gateway); rdp.desktop?.localPort=ports[0]
        let tunneled=try makeRun(rdp); var opened=false
        tunneled.openClient={ _,_,completion in opened=true; check(tunneled.tunnel?.forwarding == true && fetch(ports[0]),"external client opens only after real SSH forwarding carries traffic"); completion(nil) }
        try tunneled.start(configurationFile:sshConfig); controller.workspace.layoutSubtreeIfNeeded()
        check(!opened,"external client is deferred during SSH authentication")
        check(until(10) { opened || !tunneled.active } && opened,"SSH tunnel completion triggers client handoff")
        tunneled.stop(); check(!fetch(ports[0]) && !FileManager.default.fileExists(atPath:tunneled.directory.path),"stop closes desktop tunnel and removes RDP file")
        rdp.desktop?.localPort=ports[1]
        let cancelled=try makeRun(rdp); var cancelledHandoff=false; cancelled.openClient={ _,_,_ in cancelledHandoff=true }
        try cancelled.start(configurationFile:sshConfig); cancelled.stop(); _=until(0.5) { false }
        check(!cancelledHandoff && !cancelled.active,"stop before authentication prevents delayed client launch")
        rdp.desktop?.localPort=httpPort
        let conflict=try makeRun(rdp); var conflictHandoff=false; conflict.openClient={ _,_,_ in conflictHandoff=true }
        try conflict.start(configurationFile:sshConfig)
        check(until(10) { !conflict.active } && conflict.state.hasPrefix("Failed") && !conflictHandoff,"port conflict fails without opening external client")
        rdp.desktop?.localPort=ports[2]
        let lost=try makeRun(rdp); lost.openClient={ _,_,done in done(nil) }; try lost.start(configurationFile:sshConfig)
        check(until(10) { lost.handedOff },"second desktop tunnel reaches handoff")
        lost.tunnel?.stop()
        check(until { !lost.active } && lost.state.contains("Tunnel ended") && !FileManager.default.fileExists(atPath:lost.directory.path),"tunnel loss updates status and cleans temporary config")
        rdp.desktop?.localPort=ports[3]
        let tunnelFailure=try makeRun(rdp); tunnelFailure.openClient={ _,_,done in done(HarborError.message("Launch failed after tunnel")) }
        try tunnelFailure.start(configurationFile:sshConfig)
        check(until(10) { !tunnelFailure.active } && !fetch(ports[3]) && !FileManager.default.fileExists(atPath:tunnelFailure.directory.path),"client failure after forwarding removes owned tunnel and file")
        vnc.host="127.0.0.1"; vnc.port=httpPort; vnc.user=""; vnc.desktop=rdp.desktop
        let tunneledVNC=try makeRun(vnc); var vncTraffic=false
        tunneledVNC.openClient={ url,_,done in vncTraffic=url.scheme == "vnc" && url.port == ports[3] && fetch(ports[3]);done(nil) }
        try tunneledVNC.start(configurationFile:sshConfig)
        check(until(10) { tunneledVNC.handedOff } && vncTraffic,"VNC handoff follows an independently verified SSH tunnel")
        tunneledVNC.stop()
        print("CLIENT HANDLERS: "+DesktopConfiguration.clientReport().replacingOccurrences(of:"\n",with:" | "))
        print("LOCAL DEPENDENCIES: "+report.replacingOccurrences(of:"\n",with:" | "))
    } catch { check(false,error.localizedDescription) }
    owned.forEach { $0.stop() }; controller.tabs.forEach { $0.stopTerminal() }; try? FileManager.default.removeItem(at:root)
    print("RESULT assertions=\(assertions) failures=\(failures)");fflush(stdout);exit(failures == 0 ? 0 : 1)
}
app.run()
