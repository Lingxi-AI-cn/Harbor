import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController(); app.delegate = controller
var failures = 0, assertions = 0
func check(_ ok: Bool,_ name: String) { assertions += 1; print("\(ok ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !ok { failures += 1 } }
func until(_ seconds:Double = 5,_ condition:()->Bool) -> Bool { let end=Date().addingTimeInterval(seconds); while !condition() && Date()<end { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }; return condition() }
func rejects(_ body:()throws->Void) -> Bool { do { try body(); return false } catch { return true } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-automation-test-\(UUID().uuidString)")
func bookmark(_ type:String,_ changes:[Int:String] = [:]) -> String {
    var fields = Array(repeating:"",count:39); fields[0]=type; fields[1]="example.invalid"; fields[2]=type == "4" ? "3389" : type == "5" ? "5900" : "2222";fields[3]=type == "5" ? "-1" : "tester"
    for (i,v) in changes {fields[i]=v};return "#109#"+fields.joined(separator:"%")+"#MobaFont%10#0# #-1"
}
Timer.scheduledTimer(withTimeInterval:0.5,repeats:false) { _ in
 do {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let valid = "[Bookmarks]\r\nSubRep=Team\\Prod\r\n" + ["0","4","5","7"].map { "Session\($0)="+bookmark($0) }.joined(separator:"\r\n")
    let parsed = try MobaSessionImport.parse(Data(valid.utf8))
    check(parsed.connections.map(\.kind)==["SSH","RDP","VNC","SFTP"],"Moba bookmark protocol IDs map independently of icons")
    check(parsed.connections.allSatisfy{$0.folder == "Team/Prod" && $0.host == "example.invalid"},"Moba nested folders and endpoints preserved")
    check(parsed.connections.first?.command().1.contains("/dev/null") == true,"Moba SSH settings isolated from user SSH config")
    let gateways = try MobaSessionImport.parse(Data(("Jump="+bookmark("0",[8:"jump1__PIPE__jump2",9:"22__PIPE__2222",10:"a__PIPE__b"])).utf8))
    check(gateways.connections.first?.jumpHosts == "a@jump1:22,b@jump2:2222","Moba multi-hop lists preserved")
    for (type,changes) in [("0",[19:"2"]),("0",[7:"touch /tmp/never-execute"]),("0",[14:"C:\\key.ppk"]),("0",[8:"jump",9:"22__PIPE__22"]),("4",[20:"gateway"]),("5",[11:"-1"]),("5",[4:"-1"]),("7",[10:"2"]),("8",[:]),("0",[2:"bad"])] {
        let value = try MobaSessionImport.parse(Data(("Skipped="+bookmark(type,changes)).utf8));check(value.connections.isEmpty && value.warnings.count>1,"unsupported or malformed Moba settings skipped · \(type) \(changes.keys.sorted())")
    }
    let foreign = try MobaSessionImport.parse(Data(("[Passwords]\nSecret="+bookmark("0")+"\n[Bookmarks]\nGood="+bookmark("0")).utf8))
    check(foreign.connections.count == 1 && foreign.connections[0].name == "Good","non-bookmark sections are ignored")
    let cp = ("Café="+bookmark("0")).data(using:.windowsCP1252)!
    check(try MobaSessionImport.parse(cp).connections.first?.name == "Café","Windows-1252 export decoding")
    let store = try SessionStore(url:root.appendingPathComponent("sessions.json"));_ = try store.importCopies(parsed.connections);_ = try store.importCopies(parsed.connections)
    check(store.connections.count == 8 && Set(store.connections.map(\.id)).count == 8 && store.connections[4].name.hasSuffix("(2)"),"migration preserves duplicate sessions with fresh IDs and suffixed names")
    let command = "stty -echo; printf 'READY\\n'; while IFS= read -r line; do if [ \"$line\" = end ]; then printf 'FINAL\\n'; exit 0; fi; printf 'OUT:%s\\n' \"$line\"; done"
    let tab = controller.launch(title:"Automation fixture",executable:"/bin/sh",arguments:["-c",command])!
    controller.workspace.layoutSubtreeIfNeeded()
    check(until{tab.view.transcript()?.contains("READY") == true},"running terminal ready through output tap · \(tab.view.backend.rawValue)")
    let host=tab.view, log=root.appendingPathComponent("current.log")
    try host.startLiveLog(log);_ = host.input("first-中文",submit:true)
    check(until{(try? String(contentsOf:log,encoding:.utf8).contains("OUT:first-中文")) == true},"current-session log receives exact Unicode output without reconnect")
    try host.stopLiveLog();let stopped = try Data(contentsOf:log)
    _ = host.input("not-logged",submit:true);check(until{host.transcript()?.contains("OUT:not-logged") == true},"terminal remains usable after stopping log")
    check(try Data(contentsOf:log)==stopped,"stopped log receives no subsequent output")
    check(!String(decoding:stopped,as:UTF8.self).contains("READY"),"current log excludes output before start")
    check(rejects{try host.startLiveLog(log)},"current log refuses overwrite")
    let attrs=try FileManager.default.attributesOfItem(atPath:log.path);check((attrs[.posixPermissions] as? Int)==0o600,"log file permissions are 0600")
    try host.beginMacro();_ = host.input("macro-中文",submit:true)
    check(until{host.transcript()?.contains("OUT:macro-中文") == true},"recorded programmatic input reaches original terminal")
    host.endMacro();let macro=TerminalMacro(backend:host.backend.rawValue,events:host.macroEvents)
    let saved=root.appendingPathComponent("macro.json");try macro.save(saved)
    let loaded=try TerminalMacro.load(saved);check(loaded.events.count >= 2 && loaded.events[0].text == "macro-中文","macro saves text and Return as separate events")
    check(rejects{try macro.save(saved)},"macro save refuses overwrite")
    let target=controller.launch(title:"Replay target",executable:"/bin/sh",arguments:["-c",command])!;controller.workspace.layoutSubtreeIfNeeded()
    check(until{target.view.transcript()?.contains("READY") == true},"second terminal ready")
    try target.view.playMacro(loaded);controller.selectTab(0)
    check(until{target.view.transcript()?.contains("OUT:macro-中文") == true && !target.view.macroPlaying},"macro playback stays bound to original target after tab switch")
    var oldMacro=loaded;oldMacro.version=1;oldMacro.events[0].text="version1-compat";oldMacro.events[0].paste=nil
    try target.view.playMacro(oldMacro)
    check(until{target.view.transcript()?.contains("OUT:version1-compat") == true && !target.view.macroPlaying},"version 1 macro remains playable after engine upgrade")
    check(loaded.version == 2,"new macro files record version 2 text and paste semantics")
    var delayed=loaded;delayed.events[0].delay=1
    try target.view.playMacro(delayed);target.view.cancelMacro();let before=target.view.transcript()
    _=until(1.2){false};check(target.view.transcript()==before && !target.view.macroPlaying,"cancel prevents queued macro input")
    try target.view.playMacro(delayed);_ = target.view.input("manual",submit:true)
    check(!target.view.macroPlaying && until{target.view.transcript()?.contains("OUT:manual") == true},"manual input cancels playback")
    var invalid=loaded;invalid.events[0].delay = -1;check(rejects{try target.view.playMacro(invalid)},"negative macro delay rejected")
    invalid=loaded;invalid.backend="unknown";check(rejects{try invalid.validate()},"unknown macro engine rejected")
    // Exercise native key hooks, not just the programmatic text API.
    try target.view.beginMacro()
    #if GHOSTTY
    if let ghost=target.view.subviews.compactMap({$0 as? GhosttyTerminalView}).first {
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:controller.window.windowNumber,context:nil,characters:"x",charactersIgnoringModifiers:"x",isARepeat:false,keyCode:7)!
        ghost.keyDown(with:event)
        let up=NSEvent.keyEvent(with:.keyUp,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:controller.window.windowNumber,context:nil,characters:"x",charactersIgnoringModifiers:"x",isARepeat:false,keyCode:7)!
        ghost.keyUp(with:up)
        ghost.insertText("中文",replacementRange:NSRange(location:NSNotFound,length:0))
        check(target.view.macroEvents.contains{$0.kind == "key" && $0.key == 7} && target.view.macroEvents.contains{$0.kind == "text" && $0.text == "中文"},"native key and committed IME text captured")
    }
    #endif
    if let legacy=target.view.subviews.compactMap({$0 as? TerminalView}).first {
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:controller.window.windowNumber,context:nil,characters:"x",charactersIgnoringModifiers:"x",isARepeat:false,keyCode:7)!
        legacy.keyDown(with:event);check(target.view.macroEvents.last?.text == "x","native Legacy key captured")
    }
    target.view.endMacro()
    let history=host.transcript() ?? "";check(history.contains("OUT:first-中文") && history.contains("OUT:not-logged"),"history includes retained pre- and post-log output")
    let historyFile=CurrentSessionLog(), historyURL=root.appendingPathComponent("history.txt");try historyFile.start(historyURL);try historyFile.append(Data(history.utf8));try historyFile.stop()
    check(try String(contentsOf:historyURL,encoding:.utf8)==history,"UTF-8 history export byte roundtrip")
    let burstLog=root.appendingPathComponent("burst.log")
    let burst=controller.launch(title:"Output volume",executable:"/bin/sh",arguments:["-c","stty -echo; printf 'READY\\n'; read line; head -c 1048576 /dev/zero | tr '\\000' 'Z'; printf 'BURST_END\\n'"],workingDirectory:root.path)!
    controller.workspace.layoutSubtreeIfNeeded();check(until{burst.view.transcript()?.contains("READY") == true},"bulk-output fixture ready")
    try burst.view.startLiveLog(burstLog);_ = burst.view.input("go",submit:true)
    check(until(15){!burst.running},"1 MiB output completes without FIFO deadlock")
    let burstBytes=try Data(contentsOf:burstLog)
    check(burstBytes.filter{$0 == 90}.count == 1048576 && String(decoding:burstBytes.suffix(30),as:UTF8.self).contains("BURST_END"),"raw output tap preserves all 1 MiB bytes and final marker")
    let finalLog=root.appendingPathComponent("final.log");try host.startLiveLog(finalLog);_ = host.input("end",submit:true)
    check(until{!tab.running},"wrapped terminal reports child exit")
    check(try !host.liveLog.active && String(contentsOf:finalLog,encoding:.utf8).contains("FINAL"),"exit drains final output and closes log")
    try target.view.playMacro(delayed);target.stopTerminal();check(!target.view.macroPlaying && !target.view.liveLog.active,"closing target cancels playback and logging")
    let menus=NSApp.mainMenu?.items.flatMap{$0.submenu?.items ?? []}.map(\.title) ?? []
    check(menus.contains(L("Import MobaXterm sessions…")) && menus.contains(L("Record macro…")) && menus.contains(L("Start current session log…")) && menus.contains(L("Export terminal history…")),"all four features exposed in Session menu")
 } catch {check(false,error.localizedDescription)}
 controller.tabs.forEach{$0.stopTerminal()};try? FileManager.default.removeItem(at:root)
 print("RESULT assertions=\(assertions) failures=\(failures)");fflush(stdout);exit(failures == 0 ? 0 : 1)
}
app.run()
