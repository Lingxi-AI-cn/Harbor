import AppKit
let out = CommandLine.arguments[1]
var failures = 0
func check(_ ok: Bool,_ message: String) { print("\(ok ? "PASS" : "FAIL"): \(message)"); fflush(stdout); if !ok { failures += 1 } }
func later(_ seconds: Double,_ task: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline:.now()+seconds*2,execute:task) }
func send(_ view: GhosttyTerminalView,_ text: String) {
    if text.count > 50, text.hasSuffix("\n"), let p = view.surface {
        let payload = String(text.dropLast())
        payload.withCString { ghostty_surface_text(p,$0,UInt(payload.utf8.count)) }
        send(view,"\n"); return
    }
    for c in text {
        let code: UInt16 = c == "\n" ? 36 : c == "\u{1b}" ? 53 : 0
        let e = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,characters:String(c),charactersIgnoringModifiers:String(c),isARepeat:false,keyCode:code)!
        view.sendKey(e,action:GHOSTTY_ACTION_PRESS,text:code == 0 ? String(c) : nil)
    }
}
final class TestDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let a = GhosttyTerminalView(frame:NSRect(x:0,y:0,width:900,height:500))
    let b = GhosttyTerminalView(frame:NSRect(x:0,y:0,width:900,height:500))
    let c = GhosttyTerminalView(frame:NSRect(x:0,y:0,width:900,height:500))
    var cpid: Int32 = -1
    var childExited = false
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect:NSRect(x:80,y:80,width:900,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Harbor Ghostty backend verification"; window.isReleasedWhenClosed = false
        window.contentView = a; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(a)
        do { try a.start(executable:"/bin/zsh",arguments:["-f"]); try b.start(executable:"/bin/zsh",arguments:["-f"]) } catch { check(false,error.localizedDescription); exit(1) }
        if ProcessInfo.processInfo.environment["HARBOR_SHELL_DIRECTORY_TEST"] == "1" { shellDirectoryCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_SEARCH_TEST"] == "1" { searchCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_PANE_ACTIONS_TEST"] == "1" { paneActionsCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_PREFERENCES_TEST"] == "1" { preferencesCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_LINK_TEST"] == "1" { linkCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_DIRECTORY_TEST"] == "1" { directoryCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_METADATA_TEST"] == "1" { metadataCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_SOAK_TEST"] == "1" { soakCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_SELECTION_TEST"] == "1" { selectionCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_SHORTCUT_TEST"] == "1" { shortcutCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_PASTE_TEST"] == "1" { pasteCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_INPUT_TEST"] == "1" { inputCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_LIFECYCLE_TEST"] == "1" { lifecycleCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_PERF_TEST"] == "1" { performanceCheck(); return }
        if ProcessInfo.processInfo.environment["HARBOR_INTERACTIVE_TEST"] == "1" { return }
        later(1) { send(self.a,"printf '\\033[2J\\033[HSELECT_ME_中文\\n'; stty size\n") }
        later(2) {
            try? self.a.readText()?.write(toFile:out+"/first-screen.txt",atomically:true,encoding:.utf8)
            check(self.a.readText()?.hasPrefix("SELECT_ME_中文") == true,"real PTY output")
            self.a.selectAll(nil)
            check(self.a.readText(selection:true)?.contains("SELECT_ME_中文") == true,"selection reads this surface")
            let board = NSPasteboard(name:NSPasteboard.Name("HarborTest-\(UUID())"))
            // Validate exact selected content without touching the user's clipboard.
            let selected = GhosttyTerminalView.clipboardText(self.a.readText(selection:true) ?? ""); self.a.copySelection(to:board)
            check(board.string(forType:.string) == selected && !selected.isEmpty,"selected text clipboard roundtrip")
            self.a.action("clear_selection")
            func mouse(_ type: NSEvent.EventType,_ x: CGFloat) -> NSEvent {
                let point = self.a.convert(NSPoint(x:x,y:10),to:nil)
                return NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            }
            self.a.mouseDown(with:mouse(.leftMouseDown,2))
            self.a.mouseDragged(with:mouse(.leftMouseDragged,60))
            self.a.mouseUp(with:mouse(.leftMouseUp,60))
            self.a.copySelection(to:board)
            check(board.string(forType:.string)?.hasPrefix("SELECT") == true && (board.string(forType:.string)?.count ?? 999) < 20,"mouse selection copies only selected cells")
            self.a.action("clear_selection")
            self.a.setMarkedText("中文组合",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            check(self.a.hasMarkedText() && self.a.selectedRange().location == 2,"IME marked selection")
            check(self.a.attributedSubstring(forProposedRange:NSRange(location:0,length:2),actualRange:nil)?.string == "中文","IME substring uses UTF16 ranges")
            check(self.a.firstRect(forCharacterRange:NSRange(location:0,length:0),actualRange:nil).height > 0,"IME candidate anchor")
            self.a.unmarkText(); check(!self.a.hasMarkedText(),"IME cancellation")
            self.window.setContentSize(NSSize(width:650,height:350)); self.a.resize(); send(self.a,"stty size\n")
        }
        later(3) { send(self.a,"/usr/bin/vim -Nu NONE -i NONE -n\n") }
        later(4) { send(self.a,"iVIM_中文_OK") }
        later(5) {
            check(self.a.readText()?.contains("VIM_中文_OK") == true && self.a.readText()?.contains("~") == true,"real vim")
            send(self.a,"\u{1b}:q!\n")
        }
        later(6) { send(self.a,"/opt/homebrew/bin/tmux -L harbor-backend-\(getpid()) -f /dev/null new-session -s verify '/bin/zsh -f'\n") }
        later(7) { send(self.a,"printf 'TMUX_OK\\n'\n") }
        later(8) {
            let s = self.a.readText() ?? ""; try? s.write(toFile:out+"/tmux-screen.txt",atomically:true,encoding:.utf8); check(s.contains("TMUX_OK") && s.contains("[verify]"),"real tmux status and output")
            send(self.a,"exit\n")
        }
        later(9) {
            self.window.contentView = self.b; self.b.resize()
            send(self.b,"printf '\\033[2J\\033[HSECOND_TAB\\n'\n")
        }
        later(10) {
            check(self.b.readText()?.hasPrefix("SECOND_TAB") == true,"second surface owns independent PTY")
            check(self.a.readText()?.contains("SECOND_TAB") == false,"tab output isolation")
            self.a.stop()
            var rejected = false
            do { try self.a.start(executable:"/bin/sh",arguments:["-c","exit 99"]) } catch { rejected = true }
            check(rejected,"closed surface cannot restart or create orphan processes")
            let cancelled = GhosttyTerminalView(frame:.zero)
            do { try cancelled.start(executable:"/bin/sleep",arguments:["120"]); cancelled.stop() } catch { check(false,error.localizedDescription) }
            check(cancelled.surface == nil,"closing before attachment cancels pending launch")
            send(self.b,"printf 'SURVIVOR_OK\\n'\n")
        }
        later(11) {
            check(self.b.readText()?.contains("SURVIVOR_OK") == true,"closing one surface preserves the other")
            self.b.onEnded = { self.childExited = true }
            send(self.b,"exit\n")
        }
        later(12) {
            check(self.childExited,"child exit callback")
            self.window.contentView = self.c
            let script = "echo $$ > '" + out + "/child.pid'; exec /bin/sleep 120"
            do { try self.c.start(executable:"/bin/sh",arguments:["-c",script]) } catch { check(false,error.localizedDescription) }
        }
        later(13) {
            self.cpid = Int32((try? String(contentsOfFile:out+"/child.pid",encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "") ?? -1
            check(self.cpid > 0 && kill(self.cpid,0) == 0,"controlled child is alive before stop")
            self.c.stop()
        }
        later(14) { check(self.cpid > 0 && kill(self.cpid,0) != 0,"surface stop terminates controlled child"); self.finish() }
        later(18) { check(false,"test timeout"); self.finish() }
    }
    var perfViews: [GhosttyTerminalView] = []
    func rss() -> Int {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath:"/bin/ps"); p.arguments = ["-o","rss=","-p","\(getpid())"]; p.standardOutput = pipe
        try? p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return Int(String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) ?? -1
    }
    func performanceCheck() {
        a.stop(); b.stop()
        let host = NSView(frame:window.contentView!.bounds); window.contentView = host
        let baseline = rss(), started = Date()
        for i in 0..<4 {
            let v = GhosttyTerminalView(frame:host.bounds); host.addSubview(v); perfViews.append(v)
            let generator = "import sys; sys.stdout.write(''.join(f'line-{n:05d} 中文 '+('x'*50)+'\\n' for n in range(20000))); print('PERF_DONE_\(i)',flush=True)"
            do { try v.start(executable:"/usr/bin/python3",arguments:["-c",generator]) } catch { check(false,error.localizedDescription); finish(); return }
            if i < 3, let p = v.surface { ghostty_surface_set_occlusion(p,false) }
        }
        func poll() {
            let complete = self.perfViews.enumerated().allSatisfy { $0.element.readText()?.contains("PERF_DONE_\($0.offset)") == true }
            if !complete && Date().timeIntervalSince(started) < 30 { DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:poll); return }
            let elapsed = Date().timeIntervalSince(started), loaded = self.rss()
            check(complete,"four terminal surfaces process 80000 Unicode lines")
            self.perfViews.forEach { $0.stop(); $0.removeFromSuperview() }; self.perfViews.removeAll()
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                let metrics: [String:Any] = ["surfaces":4,"lines":80000,"seconds":elapsed,"rss_before_kb":baseline,"rss_loaded_kb":loaded,"rss_after_close_kb":self.rss(),"complete":complete,"scope":"bounded local throughput; not a long-duration leak proof"]
                if let data = try? JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:out+"/performance.json")) }
                self.finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:poll)
    }
    func finish() {
        a.onEnded = nil; b.onEnded = nil; a.stop(); b.stop(); c.stop()
        print("RESULT failures=\(failures)"); fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let delegate = TestDelegate(); app.delegate = delegate; app.run()
