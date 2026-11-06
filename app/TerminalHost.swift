import AppKit

enum TerminalBackend: String { case legacy, ghostty
    static var selected: TerminalBackend = {
        #if GHOSTTY
        return (ProcessInfo.processInfo.environment["HARBOR_TERMINAL_BACKEND"] ?? TerminalPreferences.backend) == "legacy" ? .legacy : .ghostty
        #else
        return .legacy
        #endif
    }()
}
final class TerminalHost: NSView, NSSearchFieldDelegate {
    let backend = TerminalBackend.selected
    private var legacy: TerminalView?
    #if GHOSTTY
    private var ghost: GhosttyTerminalView?
    #endif
    let liveLog = CurrentSessionLog()
    private var outputTap: LiveOutputTap?
    var onAutomationChanged: (() -> Void)?
    var onAutomationError: ((Error) -> Void)?
    private(set) var macroEvents = [TerminalMacroEvent]()
    private(set) var macroRecording = false
    private(set) var macroPlaying = false
    private var macroLastTime = 0.0
    private var macroBytes = 0
    private var macroElapsed = 0.0
    private var macroTimer: Timer?
    private var macroHeld = [UInt32:TerminalMacroEvent]()
    var automationBadge: String { (liveLog.active ? L("● LOG · ") : "") + (macroRecording ? L("● MACRO · ") : macroPlaying ? L("▶ MACRO · ") : "") }
    func receiveOutput(_ data: Data) {
        do { try liveLog.append(data) } catch { onAutomationChanged?(); onAutomationError?(error) }
    }
    func startLiveLog(_ url: URL) throws {
        guard acceptsProgrammaticInput else { throw HarborError.message(L("The terminal is not running.")) }
        outputTap?.drain(); try liveLog.start(url); onAutomationChanged?()
    }
    func stopLiveLog() throws { outputTap?.drain(); try liveLog.stop(); onAutomationChanged?() }
    func beginMacro() throws {
        guard acceptsProgrammaticInput, !macroPlaying else { throw HarborError.message(L("The terminal is unavailable.")) }
        macroEvents = []; macroBytes = 0; macroElapsed = 0; macroRecording = true; macroLastTime = ProcessInfo.processInfo.systemUptime; onAutomationChanged?()
    }
    func endMacro() { macroRecording = false; onAutomationChanged?() }
    func clearMacro() { endMacro(); macroEvents = []; macroBytes = 0 }
    func captureMacro(_ input: TerminalMacroEvent) {
        // Manual typing cancels playback before subsequent queued events.
        if macroPlaying { cancelMacro() }
        guard macroRecording else { return }
        guard macroEvents.count < 10000, macroBytes + input.text.utf8.count <= 1_048_576, input.text.utf8.count <= 65536 else {
            endMacro(); onAutomationError?(HarborError.message(L("Macro recording stopped at its size limit. Save the recorded events."))); return
        }
        var event = input; let now = ProcessInfo.processInfo.systemUptime
        event.delay = macroEvents.isEmpty ? 0 : min(60,max(0,now - macroLastTime)); macroLastTime = now
        guard macroElapsed + event.delay <= 3600 else { endMacro(); onAutomationError?(HarborError.message(L("Macro recording stopped at one hour of recorded waits. Save the recorded events."))); return }
        macroElapsed += event.delay; macroBytes += event.text.utf8.count; macroEvents.append(event)
    }
    func playMacro(_ macro: TerminalMacro) throws {
        try macro.validate()
        guard macro.backend == backend.rawValue, acceptsProgrammaticInput, !macroRecording, !macroPlaying else { throw HarborError.message(L("Macro engine or terminal state does not match.")) }
        var events = macro.events
        if macro.version == 1 && macro.backend == "ghostty" {
            // Version 1 text events used the old engine's paste-style text API.
            for i in events.indices where events[i].kind == "text" { events[i].paste = true }
        }
        macroPlaying = true; onAutomationChanged?(); scheduleMacro(events,index:0)
    }
    private func scheduleMacro(_ events:[TerminalMacroEvent],index:Int) {
        guard macroPlaying else { return }
        guard index < events.count else { cancelMacro(); return }
        let timer = Timer(timeInterval:max(0.001,events[index].delay),repeats:false) { [weak self] _ in
            guard let self, self.macroPlaying, self.acceptsProgrammaticInput else { self?.cancelMacro(); return }
            let e = events[index]
            #if GHOSTTY
            if let ghost = self.ghost { ghost.replayMacroEvent(e) }
            #endif
            if let legacy = self.legacy {
                legacy.session.send(e.kind == "text" ? legacy.grid.pasteData(e.text) : Data(e.text.utf8))
            }
            if e.kind == "key" { if e.action == 0 { self.macroHeld.removeValue(forKey:e.key) } else { self.macroHeld[e.key] = e } }
            self.scheduleMacro(events,index:index+1)
        }
        macroTimer = timer; RunLoop.main.add(timer,forMode:.common)
    }
    func cancelMacro() {
        macroTimer?.invalidate(); macroTimer = nil; macroPlaying = false
        #if GHOSTTY
        for var event in macroHeld.values { event.action = 0; event.text = ""; ghost?.replayMacroEvent(event) }
        #endif
        macroHeld = [:]; onAutomationChanged?()
    }
    private func endAutomation() { endMacro(); cancelMacro(); outputTap?.close(); outputTap = nil; do { try liveLog.stop() } catch { onAutomationError?(error) }; onAutomationChanged?() }
    var onPaneAction: ((String,String,Int) -> Void)?
    var onFocused: (() -> Void)?
    var onEnded: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onTitle: ((String) -> Void)?
    var onWorkingDirectory: ((String) -> Void)?
    private var child: NSView?
    private var processEnded = false
    private var searchBar: NSView?
    private let searchField = NSSearchField()
    private let searchStatus = NSTextField(labelWithString:"")
    private var previousQuery = ""
    func showSearch() {
        if searchBar == nil {
            let bar = NSView(); searchBar = bar; addSubview(bar)
            searchField.placeholderString = L("Search history (ignores ASCII case)")
            searchField.target = self; searchField.action = #selector(searchNext); searchField.delegate = self
            searchField.sendsSearchStringImmediately = false; searchField.sendsWholeSearchString = true
            let previous = NSButton(title:"↑",target:self,action:#selector(searchPrevious))
            let next = NSButton(title:"↓",target:self,action:#selector(searchNext))
            let close = NSButton(title:L("Done"),target:self,action:#selector(closeSearch))
            for view in [searchField,previous,next,searchStatus,close] { bar.addSubview(view) }
        }
        searchBar?.isHidden = false; needsLayout = true; layoutSubtreeIfNeeded()
        window?.makeFirstResponder(searchField)
    }
    func controlTextDidBeginEditing(_ notification: Notification) { onFocused?() }
    @objc private func searchNext() { performSearch(backwards:false) }
    @objc private func searchPrevious() { performSearch(backwards:true) }
    private func performSearch(backwards: Bool) {
        let query = searchField.stringValue
        guard !query.isEmpty else {
            previousQuery = ""; searchStatus.stringValue = ""
            #if GHOSTTY
            ghost?.clearSearchSelection()
            #endif
            return
        }
        #if GHOSTTY
        if let ghost {
            do {
                if query == previousQuery { ghost.navigateSearch(backwards:backwards) }
                else { previousQuery = query; searchStatus.stringValue = L("Searching…"); try ghost.startSearch(query) }
            } catch { searchStatus.stringValue = L("Search failed"); searchStatus.toolTip = error.localizedDescription }
            return
        }
        #endif
        searchStatus.stringValue = L("Ghostty only"); searchStatus.toolTip = L("History search requires the Ghostty backend.")
    }
    @objc private func closeSearch() {
        searchBar?.isHidden = true; previousQuery = ""; needsLayout = true
        #if GHOSTTY
        ghost?.clearSearchSelection()
        #endif
        if let child { window?.makeFirstResponder(child) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == NSSelectorFromString("insertNewline:"), NSApp.currentEvent?.modifierFlags.contains(.shift) == true { searchPrevious(); return true }
        if commandSelector == NSSelectorFromString("cancelOperation:") { closeSearch(); return true }; return false
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { if let child { return window?.makeFirstResponder(child) ?? false }; return true }
    func start(executable: String, arguments: [String], workingDirectory: String? = nil) throws {
        #if GHOSTTY
        if backend == .ghostty {
            let tap = try LiveOutputTap(); outputTap = tap
            tap.receive = { [weak self] in self?.receiveOutput($0) }
            let v = GhosttyTerminalView(frame:bounds); ghost = v; child = v
            v.onMacroInput = { [weak self] in self?.captureMacro($0) }
            v.onSearchChanged = { [weak self] total,selected in
                guard let self else { return }
                if let total { self.searchStatus.stringValue = total == 0 ? L("No matches") : "\(selected.map { String($0+1) } ?? "–") / \(total)" }
                else { self.searchStatus.stringValue = L("Searching…") }
                self.searchStatus.toolTip = self.searchStatus.stringValue
            }
            v.onSearchRequested = { [weak self] needle in
                guard let self else { return }; self.showSearch()
                if let needle, !needle.isEmpty { self.searchField.stringValue = needle; self.previousQuery = ""; self.performSearch(backwards:false) }
            }
            v.onSearchEnded = { [weak self] in self?.searchBar?.isHidden = true; self?.previousQuery = ""; self?.needsLayout = true }
            v.onPaneAction = { [weak self] in self?.onPaneAction?($0,$1,$2) }
            v.onFocused = { [weak self] in self?.onFocused?() }
            v.onTitle = { [weak self] in self?.onTitle?($0) }
            v.onWorkingDirectory = { [weak self] in self?.onWorkingDirectory?($0) }
            v.onEnded = { [weak self] in self?.processEnded = true; self?.endAutomation(); self?.onEnded?() }
            v.onCloseRequested = { [weak self] in self?.onCloseRequested?() }
            v.onFailure = { [weak self] error in self?.onFailure?(error) }
            addSubview(v); v.autoresizingMask = [.width,.height]
            do { try v.start(executable:"/usr/bin/script",arguments:["-q","-F",tap.fifo.path,executable] + arguments,workingDirectory:workingDirectory) }
            catch { endAutomation(); throw error }
            return
        }
        #endif
        let v = TerminalView(frame:bounds); legacy = v; child = v
        v.onMacroInput = { [weak self] in self?.captureMacro($0) }
        v.onRawOutput = { [weak self] in self?.receiveOutput($0) }
        v.onFocused = { [weak self] in self?.onFocused?() }
        v.onEnded = { [weak self] in self?.processEnded = true; self?.endAutomation(); self?.onEnded?() }
        addSubview(v); v.autoresizingMask = [.width,.height]
        try v.session.start(executable:executable,arguments:arguments,workingDirectory:workingDirectory)
    }
    func stop() {
        processEnded = true
        endAutomation()
        #if GHOSTTY
        ghost?.stop()
        #endif
        legacy?.session.stop()
    }
    var acceptsProgrammaticInput: Bool {
        guard !processEnded else { return false }
        #if GHOSTTY
        if let ghost { return ghost.acceptsProgrammaticInput }
        #endif
        return legacy?.session.fd ?? -1 >= 0
    }
    @discardableResult func input(_ text: String, submit: Bool = false) -> Bool {
        guard acceptsProgrammaticInput else { return false }
        #if GHOSTTY
        if let ghost { return ghost.input(text,submit:submit) }
        #endif
        if let legacy { captureMacro(TerminalMacroEvent(kind:"text",text:text)); legacy.session.send(legacy.grid.pasteData(text)); if submit { captureMacro(TerminalMacroEvent(kind:"raw",text:"\r")); legacy.session.send(Data([13])) }; return true }
        return false
    }
    func transcript() -> String? {
        #if GHOSTTY
        if let ghost { return ghost.readText() }
        #endif
        return legacy?.grid.plainText
    }
    func notice(_ s: String) { legacy?.grid.feed(Data(s.utf8)); legacy?.needsDisplay = true }
    override func layout() {
        super.layout()
        let compact = bounds.width < 340
        let height: CGFloat = searchBar?.isHidden == false ? (compact ? 64 : 32) : 0
        child?.frame = NSRect(x:0,y:0,width:bounds.width,height:max(0,bounds.height - height))
        if let bar = searchBar, height > 0 {
            bar.frame = NSRect(x:0,y:bounds.height - height,width:bounds.width,height:height)
            let narrow = bounds.width < 180
            bar.subviews[1].isHidden = narrow; searchStatus.isHidden = narrow
            let fieldWidth = compact ? max(0,bounds.width - 8) : bounds.width - 220
            searchField.frame = NSRect(x:4,y:compact ? 35 : 3,width:fieldWidth,height:26)
            let controlsX: CGFloat = compact ? 4 : fieldWidth + 6
            bar.subviews[1].frame = NSRect(x:controlsX,y:2,width:28,height:28)
            bar.subviews[2].frame = NSRect(x:narrow ? 4 : controlsX + 30,y:2,width:28,height:28)
            let statusWidth = compact ? max(0,bounds.width - 128) : 85
            searchStatus.frame = NSRect(x:controlsX + 62,y:7,width:statusWidth,height:20)
            bar.subviews[4].frame = NSRect(x:narrow ? 34 : controlsX + 63 + statusWidth,y:2,width:58,height:28)
        }
    }
}
