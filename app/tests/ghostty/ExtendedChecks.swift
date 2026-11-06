import AppKit
extension TestDelegate {
    func searchCheck() {
        a.stop(); b.stop(); window.contentView = c
        let wrapped = "跨行" + String(repeating:"0123456789",count:20) + "终点"
        let grapheme = "e\u{301}👩‍💻"
        let program = "import time; print('"+grapheme+"'); print('SEARCH_中文'); print('"+wrapped+"'); print(''.join(f'history-{i:05d}\\n' for i in range(5000)),end=''); print('SEARCH_中文',flush=True); time.sleep(60)"
        do { try c.start(executable:"/usr/bin/python3",arguments:["-c",program]) } catch { check(false,error.localizedDescription); finish(); return }
        func until(_ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while !predicate(), Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
            return predicate()
        }
        Timer.scheduledTimer(withTimeInterval:2,repeats:false) { _ in
            do {
                try? self.c.readText()?.write(toFile:out+"/search-screen.txt",atomically:true,encoding:.utf8)
                try self.c.startSearch("SEARCH_中文")
                check(until { self.c.searchTotal == 2 && self.c.searchSelected != nil },"async search counts history and active screen Chinese matches")
                let first = self.c.searchSelected
                try self.c.startSearch("search_中文")
                check(self.c.searchTotal == 2 && self.c.searchSelected == first,"ASCII case-only query change keeps completed search state")
                self.c.navigateSearch(backwards:true)
                check(until { self.c.searchSelected != nil && self.c.searchSelected != first },"search navigation changes selected match")
                check(until { self.c.readText(viewport:true)?.contains("history-00000") == true },"search scrolls viewport to historical Chinese match")
                self.c.navigateSearch(backwards:true)
                check(until { self.c.searchSelected == first },"search navigation wraps to initial match")
                check(until { self.c.readText(viewport:true)?.contains("history-04999") == true },"search returns viewport to latest match")
                try self.c.startSearch(wrapped)
                check(until { self.c.searchTotal == 1 && self.c.searchSelected != nil },"Unicode query across soft-wrapped rows matches")
                try self.c.startSearch("history-")
                check(until { self.c.searchTotal == 5000 },"search traverses every retained history page")
                try self.c.startSearch(grapheme)
                check(until { self.c.searchTotal == 1 && self.c.searchSelected != nil },"combining marks and emoji match complete cells")
                try self.c.startSearch("\nhistory-")
                check(until { self.c.searchTotal == 5000 },"hard newlines remain searchable across terminal pages")
                try self.c.startSearch("NO_SUCH_HISTORY_VALUE")
                check(until { self.c.searchTotal == 0 && self.c.searchSelected == nil },"no result clears stale search state")
                self.c.clearSearchSelection()
                check(until { !self.c.searchActive && self.c.searchTotal == nil && self.c.searchSelected == nil },"explicit search close resets engine host state")
                try self.c.startSearch("SEARCH_中文")
                self.c.clearSearchSelection()
                try self.c.startSearch("history-00042")
                check(until { self.c.searchActive && self.c.searchTotal == 1 && self.c.searchSelected != nil },"close and immediate reopen ignores queued old search callbacks")
                self.c.clearSearchSelection()
                var rejected = false
                do { try self.c.startSearch("") } catch { rejected = true }
                check(rejected,"empty query rejected without invoking engine search")
            } catch { check(false,error.localizedDescription) }
            self.c.stop(); self.finish()
        }
    }
    func paneActionsCheck() {
        var received: [String] = [], other: [String] = []
        a.onPaneAction = { received.append("\($0):\($1):\($2)") }
        b.onPaneAction = { other.append("\($0):\($1):\($2)") }
        window.contentView = b
        later(1) {
            for direction in ["left","right","up","down"] { self.a.action("new_split:"+direction) }
            for direction in ["previous","next","left","right","up","down"] { self.a.action("goto_split:"+direction) }
            for direction in ["left","right","up","down"] { self.a.action("resize_split:"+direction+",10") }
            self.a.action("equalize_splits")
        }
        later(2) {
            check(Set(received.filter { $0.hasPrefix("split:") }) == Set(["left","right","up","down"].map { "split:\($0):0" }),"engine routes all split directions")
            check(Set(received.filter { $0.hasPrefix("focus:") }) == Set(["previous","next","left","right","up","down"].map { "focus:\($0):0" }),"engine routes all focus directions")
            check(Set(received.filter { $0.hasPrefix("resize:") }) == Set(["left","right","up","down"].map { "resize:\($0):10" }),"engine routes resize direction and amount")
            check(received.contains("equalize::0") && received.count == 15 && other.isEmpty,"actions stay on originating surface despite another visible surface")
            self.a.stop(); self.a.receivePaneAction("split","right")
            check(received.count == 15,"closed surface ignores queued pane actions")
            self.b.stop(); self.finish()
        }
    }
    func preferencesCheck() {
        let domain = "local.harbor.terminal.preferences"
        let saved = TerminalPreferences.defaults.persistentDomain(forName:domain)
        func restore() {
            if let saved { TerminalPreferences.defaults.setPersistentDomain(saved,forName:domain) }
            else { TerminalPreferences.defaults.removePersistentDomain(forName:domain) }
        }
        let originalHeight = ghostty_surface_size(a.surface).cell_height_px
        var variants: [GhosttyTerminalView] = []
        do {
            for theme in ["Harbor Dark","Light","High Contrast"] {
                for cursor in ["block","bar","underline"] {
                    for font in ["JetBrains Mono","Menlo"] {
                        for size: Float in [8,40] {
                            TerminalPreferences.theme = theme; TerminalPreferences.cursor = cursor
                            TerminalPreferences.fontFamily = font; TerminalPreferences.fontSize = size
                            TerminalPreferences.historyMB = size == 8 ? 1 : 512
                            let cfg = try GhosttyRuntime.shared.configuration()
                            var actualSize: Float = 0, color = ghostty_config_color_s()
                            var actualCursor: UnsafePointer<CChar>?
                            let gotSize = ghostty_config_get(cfg,&actualSize,"font-size",9)
                            let gotColor = ghostty_config_get(cfg,&color,"background",10)
                            let gotCursor = ghostty_config_get(cfg,&actualCursor,"cursor-style",12)
                            let expected: [UInt8] = theme == "Light" ? [245,245,245] : theme == "High Contrast" ? [0,0,0] : [11,17,24]
                            check(gotSize && actualSize == size && gotColor && [color.r,color.g,color.b] == expected && gotCursor && actualCursor.map { String(cString:$0) } == cursor,"engine preferences \(theme)/\(cursor)/\(font)/\(size)")
                            ghostty_config_free(cfg)
                        }
                    }
                }
            }
            let container = NSView(frame:window.contentView!.bounds); window.contentView = container
            for (i,size) in [Float(8),Float(14.5),Float(40)].enumerated() {
                TerminalPreferences.fontSize = size
                TerminalPreferences.fontFamily = i == 1 ? "Menlo" : "JetBrains Mono"
                TerminalPreferences.historyMB = [1,32,512][i]
                TerminalPreferences.theme = ["Harbor Dark","Light","High Contrast"][i]
                TerminalPreferences.cursor = ["block","bar","underline"][i]
                let view = GhosttyTerminalView(frame:container.bounds); container.addSubview(view); variants.append(view)
                try view.start(executable:"/bin/sh",arguments:["-c","printf 'PREFERENCES_OK 中文\\n'; sleep 30"])
            }
        } catch { check(false,error.localizedDescription); variants.forEach { $0.stop() }; restore(); finish(); return }
        later(2) {
            let sizes = variants.map { ghostty_surface_size($0.surface).cell_height_px }
            check(sizes[0] < sizes[1] && sizes[1] < sizes[2],"new surfaces use configured font sizes including fractional size")
            check(variants.allSatisfy { $0.readText()?.contains("PREFERENCES_OK 中文") == true },"all representative theme/font/cursor/history surfaces render real PTY output")
            check(ghostty_surface_size(self.a.surface).cell_height_px == originalHeight,"preference changes do not resize existing terminal")
            variants.forEach { $0.stop() }; restore(); self.finish()
        }
    }
    func linkCheck() {
        a.stop(); b.stop(); window.contentView = c; window.makeFirstResponder(c)
        var opened: [String] = []
        c.openURL = { opened.append($0.absoluteString); return true }
        let program = #"import time; print('\x1b[2J\x1b[H\x1b]8;;https://example.com/harbor\x07CLICK HERE\x1b]8;;\x07',flush=True); time.sleep(30)"#
        do { try c.start(executable:"/usr/bin/python3",arguments:["-c",program]) } catch { check(false,error.localizedDescription); finish(); return }
        later(1) {
            check(opened.isEmpty,"printing hyperlink does not open it")
            check(self.c.readText(viewport:true)?.contains("CLICK HERE") == true,"OSC8 fixture rendered")
            let size = ghostty_surface_size(self.c.surface), scale = self.window.backingScaleFactor
            let point = self.c.convert(NSPoint(x:CGFloat(size.cell_width_px)/scale*2,y:CGFloat(size.cell_height_px)/scale*0.5),to:nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:point,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            }
            self.c.mouseMoved(with:event(.mouseMoved))
            self.c.mouseDown(with:event(.leftMouseDown)); self.c.mouseUp(with:event(.leftMouseUp))
        }
        later(2) {
            check(opened == ["https://example.com/harbor"],"Command-click routes OSC8 URL to host opener once")
            check(self.c.hoveredURL == "https://example.com/harbor","hover reports actual OSC8 destination")
            check(["file:///tmp/test","javascript:alert(1)","ssh://host","https://","https://example.com\n"].allSatisfy { GhosttyTerminalView.supportedURL($0) == nil },"unsupported schemes and malformed URLs rejected")
            check(GhosttyTerminalView.supportedURL("mailto:test@example.com") != nil,"mailto link supported")
            self.c.stop(); self.c.receiveOpenURL("https://example.com/late")
            check(opened.count == 1,"closed surface cannot open queued URL")
            self.finish()
        }
    }
    func shellDirectoryCheck() {
        a.stop(); b.stop(); window.contentView = c
        do { try c.start(executable:"/bin/zsh",arguments:["-l"]) } catch { check(false,error.localizedDescription); finish(); return }
        later(2) { send(self.c,"cd /private/tmp\n") }
        later(4) {
            check(self.c.reportedWorkingDirectory == "/private/tmp","login zsh automatically reports cd without manual OSC")
            self.c.stop(); self.finish()
        }
    }
    func directoryCheck() {
        a.stop(); b.stop()
        let directory = URL(fileURLWithPath:out).appendingPathComponent("cwd 中文 ' space")
        try! FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        check(TerminalDirectory.inherited(directory.path,isLocal:false) == nil,"remote path is never inherited locally")
        check(TerminalDirectory.inherited("relative",isLocal:true) == nil,"relative directory rejected")
        check(TerminalDirectory.inherited(directory.path+"/missing",isLocal:true) == nil,"missing directory rejected")
        window.contentView = c
        do { try c.start(executable:"/bin/sh",arguments:["-c","printf 'PWD=%s\\n' \"$PWD\"; sleep 20"],workingDirectory:directory.path) }
        catch { check(false,error.localizedDescription); finish(); return }
        later(2) {
            check(self.c.readText()?.contains("PWD="+directory.path) == true,"real child starts in directory with Unicode spaces and quote")
            self.c.stop(); try? FileManager.default.removeItem(at:directory); self.finish()
        }
    }
    func metadataCheck() {
        later(1) { send(self.a,"printf '\\033]2;Harbor Alpha\\007\\033]7;file://localhost/tmp\\007'\n") }
        later(2) {
            check(self.a.reportedTitle == "Harbor Alpha","OSC title delivered to source surface")
            check(self.a.reportedWorkingDirectory == "/tmp","OSC working directory delivered")
            self.window.contentView = self.b
        }
        later(3) { send(self.b,"printf '\\033]2;Harbor Beta\\007\\033]7;file://localhost/private/tmp\\007'\n") }
        later(4) {
            check(self.b.reportedTitle == "Harbor Beta","second surface title delivered")
            check(self.b.reportedWorkingDirectory == "/private/tmp" && self.a.reportedWorkingDirectory == "/tmp","directory callbacks stay isolated")
            check(self.a.reportedTitle == "Harbor Alpha","title callbacks stay isolated")
            self.a.stop(); self.a.receiveTitle("late"); self.a.receiveWorkingDirectory("/late")
            check(self.a.reportedTitle == "Harbor Alpha" && self.a.reportedWorkingDirectory == "/tmp","closed surface ignores queued metadata")
            self.b.receiveTitle("safe\nname"); self.b.receiveWorkingDirectory("relative")
            check(self.b.reportedTitle == "safename" && self.b.reportedWorkingDirectory == "/private/tmp","metadata rejects controls and relative paths")
            self.b.stop(); self.finish()
        }
    }

    func soakCheck() {
        a.stop(); b.stop()
        let host = NSView(frame:window.contentView!.bounds); window.contentView = host
        let duration = max(60,Double(ProcessInfo.processInfo.environment["HARBOR_SOAK_SECONDS"] ?? "7200") ?? 7200)
        let started = Date(), log = URL(fileURLWithPath:out+"/soak.jsonl")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let writer = try! FileHandle(forWritingTo:log)
        var files: [String] = [], previous: [String] = []
        for i in 0..<4 {
            let v = GhosttyTerminalView(frame:host.bounds); host.addSubview(v); perfViews.append(v)
            let file = out+"/soak-\(i).pid"; files.append(file)
            // Fresh directory argument is encoded as a Python string using JSON.
            let encoded = String(data:try! JSONSerialization.data(withJSONObject:[file]),encoding:.utf8)!
            let program = "import os,time,json; p=json.loads('"+encoded.replacingOccurrences(of:"'",with:"\\'")+"')[0]; open(p,'w').write(str(os.getpid())); n=0\nwhile True:\n print(''.join(f'SOAK-{n:08d} 中文 '+('x'*40)+'\\n' for _ in range(100)),end='',flush=True); n+=1; time.sleep(1)"
            do { try v.start(executable:"/usr/bin/python3",arguments:["-c",program]) } catch { check(false,error.localizedDescription); perfViews.forEach { $0.stop() }; finish(); return }
        }
        window.orderOut(nil)
        func sample() {
            let text = self.perfViews.map { $0.readText(viewport:true) ?? "" }
            let elapsed = Date().timeIntervalSince(started)
            let healthy = text.allSatisfy { $0.contains("SOAK-") } && (previous.isEmpty || zip(previous,text).allSatisfy { $0 != $1 })
            let record: [String:Any] = ["seconds":elapsed,"rss_kb":self.rss(),"output_progress":healthy,"surfaces":4]
            if let data = try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) { try? writer.write(contentsOf:data+Data([10])) }
            print("SOAK seconds=\(Int(elapsed)) progress=\(healthy)"); fflush(stdout)
            previous = text
            if !healthy { check(false,"soak output stopped progressing") }
            if elapsed < duration && healthy { DispatchQueue.main.asyncAfter(deadline:.now()+min(60,duration-elapsed),execute:sample); return }
            let pids = files.map { Int32((try? String(contentsOfFile:$0,encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "") ?? -1 }
            self.perfViews.forEach { $0.stop(); $0.removeFromSuperview() }; self.perfViews.removeAll()
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                check(pids.allSatisfy { $0 > 0 && kill($0,0) != 0 },"soak children terminate after closure")
                files.forEach { try? FileManager.default.removeItem(atPath:$0) }; try? writer.close(); self.finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:sample)
    }
    func selectionCheck() {
        a.stop(); b.stop(); window.contentView = c; window.makeFirstResponder(c)
        let program = "import time; print(''.join(f'history-{n:04d} 中文\\n' for n in range(400)),end=''); print('\\x1b[2J\\x1b[Halpha beta gamma\\nsecond line 中文',flush=True); time.sleep(120)"
        do { try c.start(executable:"/usr/bin/python3",arguments:["-c",program]) } catch { check(false,error.localizedDescription); finish(); return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {
            try? self.c.readText(viewport:true)?.write(toFile:out+"/selection-screen.txt",atomically:true,encoding:.utf8)
            check(self.c.readText(viewport:true)?.hasPrefix("alpha beta gamma") == true,"selection fixture reaches actual PTY screen")
            let size = ghostty_surface_size(self.c.surface)
            let scale = self.window.backingScaleFactor
            let w = CGFloat(size.cell_width_px)/scale, h = CGFloat(size.cell_height_px)/scale
            func event(_ type: NSEvent.EventType,_ x: CGFloat,_ y: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:self.c.convert(NSPoint(x:x,y:y),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            }
            for _ in 0..<2 {
                self.c.mouseDown(with:event(.leftMouseDown,w*7,h*0.5)); self.c.mouseUp(with:event(.leftMouseUp,w*7,h*0.5))
            }
            check(self.c.readText(selection:true) == "beta","double click selects a word without adjacent spaces")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {
                self.c.action("clear_selection")
                self.c.mouseDown(with:event(.leftMouseDown,w*0.2,h*0.5))
                self.c.mouseDragged(with:event(.leftMouseDragged,w*6,h*1.5))
                self.c.mouseUp(with:event(.leftMouseUp,w*6,h*1.5))
                let selection = self.c.readText(selection:true) ?? ""
                try? selection.write(toFile:out+"/selection-crossline.txt",atomically:true,encoding:.utf8)
                let board = NSPasteboard(name:NSPasteboard.Name("HarborSelection-\(UUID())"))
                self.c.copySelection(to:board)
                check(board.string(forType:.string) == "alpha beta gamma\nsecond","cross-line copy preserves text and newline without terminal padding")
                check(GhosttyTerminalView.clipboardText("  indent  \n  \n中文\t \n") == "  indent\n\n中文","copy trims trailing padding while preserving indentation and interior blank lines")
                DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {
                    self.c.action("clear_selection")
                    let before = self.c.readText(viewport:true)
                    self.c.mouseDown(with:event(.leftMouseDown,w*3,h*1.5))
                    self.c.mouseDragged(with:event(.leftMouseDragged,w*3,-h*3))
                    // AppKit also sends mouseExited while dragging outside the view.
                    let exitEvent = NSEvent.enterExitEvent(with:.mouseExited,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.window.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!
                    self.c.mouseExited(with:exitEvent)
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {
                        let selected = self.c.readText(selection:true) ?? ""
                        try? selected.write(toFile:out+"/selection-drag.txt",atomically:true,encoding:.utf8)
                        check(self.c.readText(viewport:true) != before && selected.contains("history-"),"out-of-view drag continues scrolling into history after mouse exit")
                        self.c.mouseUp(with:event(.leftMouseUp,w*3,-h*3))
                        self.c.finish(); self.finish()
                    }
                }
            }
        }
    }
    func shortcutCheck() {
        let previous = TerminalPreferences.defaults.object(forKey:"shortcuts")
        func restore() { TerminalPreferences.defaults.set(previous,forKey:"shortcuts") }
        var values = Dictionary(uniqueKeysWithValues:TerminalPreferences.shortcutActions.map { ($0.id,$0.defaultKey) })
        values["zoomIn"] = "cmd+shift+j"
        do { try TerminalPreferences.saveShortcuts(values) } catch { restore(); check(false,error.localizedDescription); finish(); return }
        window.makeFirstResponder(a)
        let before = ghostty_surface_size(a.surface).cell_height_px
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command,.shift],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"J",charactersIgnoringModifiers:"J",isARepeat:false,keyCode:38)!
        check(a.performKeyEquivalent(with:event),"saved custom key is consumed by focused terminal")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
            check(ghostty_surface_size(self.a.surface).cell_height_px > before,"custom key actually increases terminal cell height")
            let reset = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.window.windowNumber,context:nil,characters:"0",charactersIgnoringModifiers:"0",isARepeat:false,keyCode:29)!
            check(self.a.performKeyEquivalent(with:reset),"configured reset action is handled")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                check(ghostty_surface_size(self.a.surface).cell_height_px == before,"reset restores original cell height")
                restore(); self.finish()
            }
        }
    }
    func inputCheck() {
        a.stop(); b.stop(); window.contentView = c; window.makeFirstResponder(c)
        let capture = out + "/input-capture.json"
        try? FileManager.default.removeItem(atPath:capture)
        do { try c.start(executable:"/usr/bin/python3",arguments:[FileManager.default.currentDirectoryPath + "/app/tests/ghostty/capture-input.py",capture]) }
        catch { check(false,error.localizedDescription); finish(); return }
        let deadline = Date().addingTimeInterval(10)
        func ready() {
            guard self.c.readText()?.contains("INPUT_READY") == true else {
                if Date() < deadline { DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:ready) }
                else { check(false,"raw input receiver ready"); self.finish() }; return
            }
            func key(_ code: UInt16,_ text: String,_ plain: String,_ flags: NSEvent.ModifierFlags = []) {
                let e = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:plain,isARepeat:false,keyCode:code)!
                self.c.keyDown(with:e); self.c.keyUp(with:e)
            }
            key(0,"\u{1}","a",.control)
            key(123,"\u{f702}","\u{f702}")
            key(122,"\u{f704}","\u{f704}")
            key(48,"\t","\t",.shift)
            key(51,"\u{7f}","\u{7f}")
            let accent = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.option,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.window.windowNumber,context:nil,characters:"ß",charactersIgnoringModifiers:"s",isARepeat:false,keyCode:1)!
            self.c.sendKey(accent,action:GHOSTTY_ACTION_PRESS,text:"ß")
            self.c.pasteText("first 中文\nsecond line")
            self.c.replayMacroEvent(TerminalMacroEvent(kind:"text",text:"replayed 中文\nsecond line",paste:true))
            let point = self.c.convert(NSPoint(x:25,y:25),to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let e = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
                if type == .leftMouseDown { self.c.mouseDown(with:e) } else { self.c.mouseUp(with:e) }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+8.5) {
                let json = (try? Data(contentsOf:URL(fileURLWithPath:capture))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
                let hex = json?["hex"] as? String ?? ""
                func has(_ bytes: String) -> Bool { hex.contains(Data(bytes.utf8).map { String(format:"%02x",$0) }.joined()) }
                check(hex.hasPrefix("01"),"Ctrl+A reaches raw PTY as control byte")
                check(has("\u{1b}[D"),"left arrow reaches raw PTY")
                check(has("\u{1b}OP"),"F1 reaches raw PTY")
                check(has("\u{1b}[Z"),"Shift+Tab reaches raw PTY")
                check(hex.contains("7f"),"Delete reaches raw PTY as DEL")
                if !TerminalPreferences.optionAsAlt { check(has("ß") && !has("\u{1b}ß"),"Option-produced text consumes Alt without extra escape prefix") }
                check(has("\u{1b}[200~first 中文\nsecond line\u{1b}[201~"),"multiline Unicode paste preserves bracketed-paste boundaries")
                check(has("\u{1b}[200~replayed 中文\nsecond line\u{1b}[201~"),"macro paste replay preserves bracketed-paste boundaries")
                check(has("\u{1b}[<0;") && has("M") && has("m"),"SGR mouse press and release reach raw PTY")
                self.finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:ready)
    }
    func pasteCheck() {
        a.stop(); b.stop(); window.contentView = c
        let capture = out + "/paste-capture.json"
        let program = "import os,tty,time,select,json; tty.setraw(0); os.write(1,b'PASTE_READY'); data=b''; end=time.monotonic()+4\nwhile time.monotonic()<end:\n if select.select([0],[],[],0.05)[0]: data+=os.read(0,65536)\njson.dump({'hex':data.hex()},open(" + String(reflecting:capture) + ",'w')); time.sleep(20)"
        do { try c.start(executable:"/usr/bin/python3",arguments:["-c",program]) } catch { check(false,error.localizedDescription); finish(); return }
        func until(_ predicate: () -> Bool) -> Bool { let end=Date().addingTimeInterval(6); while !predicate() && Date()<end { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }; return predicate() }
        Timer.scheduledTimer(withTimeInterval:0.1,repeats:false) { _ in
            check(until { self.c.readText()?.contains("PASTE_READY") == true },"unbracketed paste receiver ready")
            var decisions=0, events:[TerminalMacroEvent]=[]
            self.c.onMacroInput = { events.append($0) }
            self.c.confirmPaste = { _ in decisions += 1; return false }
            self.c.pasteText("DENIED\n")
            check(until { decisions == 1 },"unsafe paste requests host confirmation")
            check(events.isEmpty,"denied paste is not recorded")
            self.c.confirmPaste = { _ in decisions += 1; return true }
            self.c.pasteText("ALLOWED\n")
            check(until { decisions == 2 && events.count == 1 },"approved paste recorded once")
            check(events.first?.paste == true,"macro marks paste separately from typed text")
            self.c.replayMacroEvent(TerminalMacroEvent(kind:"text",text:"REPLAY\n",paste:true))
            check(until { FileManager.default.fileExists(atPath:capture) },"paste fixture records PTY bytes")
            let data = (try? Data(contentsOf:URL(fileURLWithPath:capture))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:String] }
            let hex=data?["hex"] ?? ""
            let expected=Data("ALLOWED\rREPLAY\r".utf8).map { String(format:"%02x",$0) }.joined()
            check(hex == expected,"cancel sends no bytes; approved paste and replay preserve paste newline conversion")
            check(decisions == 2 && events.count == 1,"approved macro replay neither prompts again nor records itself")
            self.c.stop(); self.finish()
        }
    }
    func lifecycleCheck() {
        a.stop(); b.stop()
        let host = NSView(frame:window.contentView!.bounds); window.contentView = host
        let rounds = min(1000,max(1,Int(ProcessInfo.processInfo.environment["HARBOR_LIFECYCLE_ROUNDS"] ?? "30") ?? 30))
        var samples: [[String:Int]] = [], round = 0
        let started = Date()
        func cycle() {
            round += 1
            var views: [GhosttyTerminalView] = []
            var files: [String] = []
            for index in 0..<4 {
                let view = GhosttyTerminalView(frame:host.bounds); host.addSubview(view); views.append(view)
                let file = out + "/cycle-\(round)-\(index).pid"; files.append(file)
                let script = "echo $$ > '" + file + "'; i=0; while [ $i -lt 1000 ]; do printf 'cycle output 中文 %s\\n' $i; i=$((i+1)); done; exec /bin/sleep 120"
                do { try view.start(executable:"/bin/sh",arguments:["-c",script]) } catch { check(false,error.localizedDescription) }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                let pids = files.map { Int32((try? String(contentsOfFile:$0,encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "") ?? -1 }
                check(pids.allSatisfy { $0 > 0 && kill($0,0) == 0 },"cycle \(round): all four children started")
                views.forEach { $0.stop(); $0.removeFromSuperview() }; views.removeAll()
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    check(pids.allSatisfy { $0 > 0 && kill($0,0) != 0 },"cycle \(round): all four children terminated")
                    samples.append(["cycle":round,"rss_kb":self.rss()])
                    files.forEach { try? FileManager.default.removeItem(atPath:$0) }
                    if round < rounds { cycle() } else {
                        let record: [String:Any] = ["cycles":round,"surfaces":round*4,"seconds":Date().timeIntervalSince(started),"samples":samples,"scope":"bounded repeated lifecycle test; does not prove multi-hour stability"]
                        if let data = try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:out+"/lifecycle.json")) }
                        self.finish()
                    }
                }
            }
        }
        cycle()
    }
}
