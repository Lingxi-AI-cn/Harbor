#if GHOSTTY
import AppKit
final class GhosttyTerminalView: NSView, NSTextInputClient {
    var onMacroInput: ((TerminalMacroEvent)->Void)?
    func replayMacroEvent(_ e: TerminalMacroEvent) {
        guard let p = surface, !ended else { return }
        if e.kind == "text" {
            if e.paste == true {
                replayingPaste = true; defer { replayingPaste = false }
                e.text.withCString { ghostty_surface_paste_text(p,$0,UInt(e.text.utf8.count)) }
            } else { e.text.withCString { ghostty_surface_text(p,$0,UInt(e.text.utf8.count)) } }
            return
        }
        guard e.kind == "key" else { return }
        var key = ghostty_input_key_s(); key.action = ghostty_input_action_e(rawValue:e.action); key.keycode = e.key
        key.mods = ghostty_input_mods_e(rawValue:e.modifiers); key.consumed_mods = ghostty_input_mods_e(rawValue:e.consumed); key.unshifted_codepoint = e.codepoint
        if !e.text.isEmpty { e.text.withCString { key.text = $0; _ = ghostty_surface_key(p,key) } } else { _ = ghostty_surface_key(p,key) }
    }
    private var followsAppearance = false
    private var fixedConfiguration = ""
    var surface: ghostty_surface_t?
    var onPaneAction: ((String,String,Int) -> Void)?
    func receivePaneAction(_ action: String, _ direction: String, _ amount: Int = 0) {
        guard !ended else { return }; onPaneAction?(action,direction,amount)
    }
    var onFocused: (() -> Void)?
    var onEnded: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private(set) var hoveredURL: String?
    static func supportedURL(_ value: String) -> URL? {
        guard value.utf8.count <= 16384, !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string:value), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" { return url.host?.isEmpty == false ? url : nil }
        if scheme == "mailto", !value.dropFirst(7).isEmpty { return url }
        return nil
    }
    func receiveOpenURL(_ value: String) {
        guard !ended else { return }
        guard let url = Self.supportedURL(value) else {
            toolTip = L("Unsupported link. Harbor opens HTTP, HTTPS and mailto links."); NSSound.beep(); return
        }
        if !openURL(url) { toolTip = L("Could not open this link."); NSSound.beep() }
    }
    func receiveHoveredURL(_ value: String) {
        guard !ended else { return }
        hoveredURL = value.isEmpty ? nil : value
        toolTip = hoveredURL
    }
    var onTitle: ((String) -> Void)?
    var onWorkingDirectory: ((String) -> Void)?
    private(set) var reportedTitle: String?
    private(set) var reportedWorkingDirectory: String?
    func receiveTitle(_ value: String) {
        guard !ended else { return }
        let title = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(512))
        guard !title.isEmpty else { return }
        reportedTitle = title; onTitle?(title)
    }
    func receiveWorkingDirectory(_ value: String) {
        guard !ended, value.hasPrefix("/"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        reportedWorkingDirectory = value; onWorkingDirectory?(value)
    }
    private var initialDirectory: String?
    private var pending: String?
    private var poll: Timer?
    private var ended = false
    private var started = false
    private let optionAsAlt = TerminalPreferences.optionAsAlt
    private var tracking: NSTrackingArea?
    private var pressedButtons = Set<Int>()
    private var activeKey: NSEvent?
    private var committed: String?
    var marked = ""
    var markedSelection = NSRange(location: 0, length: 0)
    static func shellCommand(executable: String, arguments: [String]) throws -> String {
        guard ([executable] + arguments).allSatisfy({ !$0.contains("\u{0}") }) else { throw NSError(domain: "Harbor", code: 1, userInfo: [NSLocalizedDescriptionKey: L("NUL is not allowed in process arguments")]) }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\"'\"'") + "'" }
        // Ghostty 1.2.3 detects shells from the first word without unquoting it.
        // Only a strict ASCII absolute path may bypass shell quoting.
        let safe = CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
        let command = executable.hasPrefix("/") && executable.unicodeScalars.allSatisfy({ safe.contains($0) }) ? executable : quote(executable)
        return ([command] + arguments.map(quote)).joined(separator:" ")
    }
    func start(executable: String, arguments: [String], workingDirectory: String? = nil) throws {
        guard !started, !ended else { throw NSError(domain:"Harbor",code:3,userInfo:[NSLocalizedDescriptionKey:L("A terminal cannot be restarted after it was started or closed.")]) }
        initialDirectory = TerminalDirectory.inherited(workingDirectory,isLocal:true)
        started = true
        _ = try GhosttyRuntime.shared.ensure()
        pending = try Self.shellCommand(executable: executable, arguments: arguments)
        if window != nil { try createSurface() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, surface == nil, pending != nil {
            do { try createSurface() } catch { finish(); onFailure?(error) }
        }
        if let p = surface { ghostty_surface_set_occlusion(p,window != nil) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard followsAppearance, let surface else { return }
        do {
            let theme = InterfaceAppearance.isDark ? "Harbor Dark" : "Light"
            let config = try GhosttyRuntime.shared.configuration(source:TerminalPreferences.colorConfig(for:theme)+fixedConfiguration)
            defer { ghostty_config_free(config) }
            ghostty_surface_update_config(surface,config)
            ghostty_surface_set_color_scheme(surface,InterfaceAppearance.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        } catch { onFailure?(error) }
    }
    private func createSurface() throws {
        guard let command = pending, surface == nil else { return }
        followsAppearance = TerminalPreferences.theme == "Follow Appearance"
        let source = TerminalPreferences.engineConfig
        fixedConfiguration = source.components(separatedBy:"\n").filter { line in
            !["background =", "foreground =", "cursor-color =", "palette ="].contains(where:line.hasPrefix)
        }.joined(separator:"\n") + "\n"
        let preferences = try GhosttyRuntime.shared.configuration(source:source)
        defer { ghostty_config_free(preferences) }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 1); cfg.font_size = TerminalPreferences.fontSize
        command.withCString { commandPtr in
            cfg.command = commandPtr
            if let initialDirectory {
                initialDirectory.withCString { cfg.working_directory = $0; surface = ghostty_surface_new(GhosttyRuntime.shared.app,&cfg) }
            } else { surface = ghostty_surface_new(GhosttyRuntime.shared.app,&cfg) }
        }
        guard surface != nil else { throw NSError(domain:"Harbor",code:2,userInfo:[NSLocalizedDescriptionKey:L("Ghostty could not create a terminal surface")]) }
        ghostty_surface_update_config(surface,preferences)
        ghostty_surface_set_color_scheme(surface,TerminalPreferences.resolvedTheme == "Light" ? GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK)
        pending = nil; resize()
        poll = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in
            guard let self, let p = self.surface else { return }
            if ghostty_surface_process_exited(p) { self.finish() }
        }
        if let poll { RunLoop.main.add(poll,forMode:.common) }
    }
    func receiveCloseRequest() {
        guard let surface else { return }
        if ghostty_surface_process_exited(surface) { finish() }
        onCloseRequested?()
    }
    func finish() { guard !ended else { return }; denyPendingPastes(); ended = true; poll?.invalidate(); poll = nil; onEnded?() }
    func stop() { denyPendingPastes(); clearSearchSelection(); pressedButtons.removeAll(); pending = nil; poll?.invalidate(); poll = nil; if let p = surface { surface = nil; ghostty_surface_free(p) }; finish() }
    deinit { denyPendingPastes(); poll?.invalidate(); if let p = surface { ghostty_surface_free(p) } }
    func action(_ name: String) { if let p = surface { name.withCString { _ = ghostty_surface_binding_action(p,$0,UInt(name.utf8.count)) } } }
    var onSearchChanged: ((Int?,Int?) -> Void)?
    var onSearchRequested: ((String?) -> Void)?
    var onSearchEnded: (() -> Void)?
    private(set) var searchTotal: Int?
    private(set) var searchSelected: Int?
    private(set) var searchActive = false
    private(set) var searchGeneration: UInt64 = 0
    private var searchQuery = ""
    private var selectFirstSearchMatch = false
    private(set) var searchUpdateSerial: UInt64 = 0
    func receiveSearchTotal(_ count: Int) {
        guard !ended, searchActive else { return }
        searchTotal = count >= 0 ? count : nil; searchUpdateSerial &+= 1
        if count > 0 && selectFirstSearchMatch {
            selectFirstSearchMatch = false; action("navigate_search:next")
        }
        onSearchChanged?(searchTotal,searchSelected)
    }
    func receiveSearchSelected(_ index: Int) {
        guard !ended, searchActive else { return }
        searchSelected = index >= 0 ? index : nil; searchUpdateSerial &+= 1
        onSearchChanged?(searchTotal,searchSelected)
    }
    func receiveSearchEnd() {
        searchActive = false; searchTotal = nil; searchSelected = nil
        onSearchChanged?(nil,nil); onSearchEnded?()
    }
    func clearSearchSelection() {
        guard searchActive else { return }
        searchGeneration &+= 1
        searchActive = false; searchTotal = nil; searchSelected = nil
        action("end_search"); onSearchChanged?(nil,nil)
    }
    func startSearch(_ query: String) throws {
        guard surface != nil, !ended else { throw NSError(domain:"HarborSearch",code:1,userInfo:[NSLocalizedDescriptionKey:L("This terminal has ended.")]) }
        guard !query.isEmpty, !query.contains("\0"), query.utf8.count <= 4096 else { throw NSError(domain:"HarborSearch",code:2,userInfo:[NSLocalizedDescriptionKey:L("Enter 1–4096 bytes of search text without NUL.")]) }
        func foldASCII(_ value: String) -> [UInt8] { value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 } }
        if searchActive && foldASCII(searchQuery) == foldASCII(query) {
            onSearchChanged?(searchTotal,searchSelected); return
        }
        searchGeneration &+= 1
        searchQuery = query; searchActive = true; searchTotal = nil; searchSelected = nil; selectFirstSearchMatch = true
        onSearchChanged?(nil,nil); action("search:"+query)
    }
    func navigateSearch(backwards: Bool) {
        guard searchActive, !ended else { return }
        // Upstream next walks toward older matches; previous walks toward newer ones.
        action(backwards ? "navigate_search:next" : "navigate_search:previous")
    }
    func readText(selection: Bool = false, viewport: Bool = false) -> String? {
        guard let p = surface else { return nil }; var value = ghostty_text_s()
        var region = ghostty_selection_s()
        region.top_left.tag = viewport ? GHOSTTY_POINT_VIEWPORT : GHOSTTY_POINT_SCREEN; region.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        region.bottom_right.tag = viewport ? GHOSTTY_POINT_VIEWPORT : GHOSTTY_POINT_SCREEN; region.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        guard selection ? ghostty_surface_read_selection(p,&value) : ghostty_surface_read_text(p,region,&value) else { return nil }
        defer { ghostty_surface_free_text(p,&value) }
        guard let bytes = value.text else { return nil }
        return String(decoding:UnsafeBufferPointer(start:UnsafeRawPointer(bytes).assumingMemoryBound(to:UInt8.self),count:Int(value.text_len)),as:UTF8.self)
    }
    @objc func copy(_ sender: Any?) { copySelection(to:.general) }
    static func clipboardText(_ raw: String) -> String {
        var lines = raw.components(separatedBy:"\n").map { line -> String in
            var trimmed = line
            while trimmed.last == " " || trimmed.last == "\t" { trimmed.removeLast() }
            return trimmed
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator:"\n")
    }
    func copySelection(to board: NSPasteboard) {
        guard let raw = readText(selection:true), !raw.isEmpty else { return }
        let text = Self.clipboardText(raw)
        board.clearContents(); board.setString(text,forType:.string)
    }
    var acceptsProgrammaticInput: Bool { surface != nil && !ended }
    func input(_ text: String, submit: Bool) -> Bool {
        guard let p = surface, !ended else { return false }
        onMacroInput?(TerminalMacroEvent(kind:"text",text:text))
        text.withCString { ghostty_surface_text(p,$0,UInt(text.utf8.count)) }
        if submit {
            var key = ghostty_input_key_s(); key.action = GHOSTTY_ACTION_PRESS; key.keycode = 36; key.unshifted_codepoint = 13
            onMacroInput?(TerminalMacroEvent(kind:"key",key:36,codepoint:13,action:GHOSTTY_ACTION_PRESS.rawValue))
            _ = ghostty_surface_key(p,key); key.action = GHOSTTY_ACTION_RELEASE
            onMacroInput?(TerminalMacroEvent(kind:"key",key:36,codepoint:13,action:GHOSTTY_ACTION_RELEASE.rawValue)); _ = ghostty_surface_key(p,key)
        }
        return true
    }
    private struct PendingPaste { let id: UUID; let state: UnsafeMutableRawPointer?; let data: Data }
    private var pendingPastes = [UUID:PendingPaste]()
    private var pasteRequestedConfirmation = false
    private var replayingPaste = false
    // Tests may inject a decision; production presents the exact text before allowing unsafe paste.
    var confirmPaste: (String) -> Bool = { text in
        let alert = NSAlert(); alert.messageText = L("Paste text that may execute commands?")
        alert.informativeText = L("This text contains line endings or control characters. Inspect it before pasting.\n\n") + String(reflecting:String(text.prefix(2000))) + (text.count > 2000 ? L("\n[Preview truncated]") : "")
        alert.addButton(withTitle:L("Paste")); alert.addButton(withTitle:L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func pasteText(_ text: String) {
        guard let p = surface, !ended, pendingPastes.isEmpty, !text.isEmpty, !text.contains("\0"), text.utf8.count <= 16 * 1024 * 1024 else { return }
        pasteRequestedConfirmation = false
        text.withCString { ghostty_surface_paste_text(p,$0,UInt(text.utf8.count)) }
        if !pasteRequestedConfirmation { onMacroInput?(TerminalMacroEvent(kind:"text",text:text,paste:true)) }
    }
    func receivePasteConfirmation(_ data: Data,state: UnsafeMutableRawPointer?) {
        guard let p = surface else { return }
        pasteRequestedConfirmation = true
        guard !ended else { ghostty_surface_deny_clipboard_request(p,state); return }
        if replayingPaste { completePaste(data,state:state); return }
        let item = PendingPaste(id:UUID(),state:state,data:data); pendingPastes[item.id] = item
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingPastes[item.id] != nil else { return }
            let text = String(decoding:item.data,as:UTF8.self)
            let allowed = self.confirmPaste(text)
            guard self.pendingPastes.removeValue(forKey:item.id) != nil, let surface = self.surface else { return }
            guard allowed, !self.ended else { ghostty_surface_deny_clipboard_request(surface,item.state); return }
            self.onMacroInput?(TerminalMacroEvent(kind:"text",text:text,paste:true))
            self.completePaste(item.data,state:item.state)
        }
    }
    private func completePaste(_ data: Data,state: UnsafeMutableRawPointer?) {
        guard let surface else { return }
        data.withUnsafeBytes { bytes in
            "text/plain".withCString { mime in
                var content = ghostty_clipboard_content_s(mime:mime,data:bytes.baseAddress?.assumingMemoryBound(to:CChar.self),len:bytes.count)
                withUnsafePointer(to:&content) { pointer in
                    var complete = ghostty_clipboard_complete_s(contents:pointer,contents_len:1,available:nil,available_len:0,confirmed:true,remember:false)
                    ghostty_surface_complete_clipboard_request(surface,&complete,state)
                }
            }
        }
    }
    private func denyPendingPastes() {
        if let p = surface { for item in pendingPastes.values { ghostty_surface_deny_clipboard_request(p,item.state) } }
        pendingPastes.removeAll()
    }
    @objc func paste(_ sender: Any?) { if let text = NSPasteboard.general.string(forType:.string) { pasteText(text) } }
    override func selectAll(_ sender: Any?) { action("select_all") }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.modifierFlags.contains(.command) else { return false }
        let flags = e.modifierFlags.intersection([.command,.shift,.option,.control])
        // Standard text editing remains consistent with the macOS Edit menu.
        if flags == .command {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil); return true
            case "v": paste(nil); return true
            case "a": selectAll(nil); return true
            default: break
            }
        }
        var names = Set<String>()
        for (flag,name): (NSEvent.ModifierFlags,String) in [(.command,"cmd"),(.shift,"shift"),(.option,"alt"),(.control,"ctrl")] { if flags.contains(flag) { names.insert(name) } }
        let key = e.keyCode == 115 ? "home" : e.keyCode == 119 ? "end" : (e.characters(byApplyingModifiers:[]) ?? e.charactersIgnoringModifiers ?? "").lowercased()
        let pressed = TerminalShortcut(key:key,modifiers:names)
        let values = TerminalPreferences.shortcutStrings
        for item in TerminalPreferences.shortcutActions {
            if let value = values[item.id], let shortcuts = try? TerminalShortcut.alternatives(value), shortcuts.contains(pressed) {
                action(item.binding); return true
            }
        }
        return false
    }
    func sendKey(_ e: NSEvent, action: ghostty_input_action_e, text: String? = nil, composing: Bool = false) {
        guard let p = surface else { return }; var key = ghostty_input_key_s()
        key.action = action; key.keycode = UInt32(e.keyCode); key.mods = mods(e); key.composing = composing
        // Shift/Option used to produce committed text are consumed; Control/Command
        // remain available to the terminal encoder. Option-as-Alt is deliberately
        // not consumed because the user requested an escape-prefix shortcut.
        var consumed = e.modifierFlags.subtracting([.control,.command])
        if optionAsAlt { consumed.remove(.option) }
        key.consumed_mods = modifierBits(consumed)
        key.unshifted_codepoint = e.characters(byApplyingModifiers:[])?.unicodeScalars.first?.value ?? 0
        if !composing { onMacroInput?(TerminalMacroEvent(kind:"key",text:(text?.utf8.first ?? 0) >= 32 ? (text ?? "") : "",key:key.keycode,modifiers:key.mods.rawValue,consumed:key.consumed_mods.rawValue,codepoint:key.unshifted_codepoint,action:action.rawValue)) }
        if let text, let first = text.utf8.first, first >= 32 { text.withCString { key.text = $0; _ = ghostty_surface_key(p,key) } }
        else { _ = ghostty_surface_key(p,key) }
    }
    override func keyUp(with e: NSEvent) { sendKey(e,action:GHOSTTY_ACTION_RELEASE) }

    var inserted = false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); resize() }
    func resize() {
        guard let p = surface else { return }
        let scale = window?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(p, scale, scale)
        ghostty_surface_set_size(p, UInt32(max(1,bounds.width * scale)), UInt32(max(1,bounds.height * scale)))
    }
    override func becomeFirstResponder() -> Bool { if let p = surface { ghostty_surface_set_focus(p, true) }; onFocused?(); return true }
    override func resignFirstResponder() -> Bool { if let p = surface { ghostty_surface_set_focus(p, false) }; return true }
    func mods(_ e: NSEvent) -> ghostty_input_mods_e { modifierBits(e.modifierFlags) }
    func modifierBits(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var v: UInt32 = 0
        for (a,b): (NSEvent.ModifierFlags, ghostty_input_mods_e) in [(.shift,GHOSTTY_MODS_SHIFT),(.control,GHOSTTY_MODS_CTRL),(.option,GHOSTTY_MODS_ALT),(.command,GHOSTTY_MODS_SUPER)] { if flags.contains(a) { v |= b.rawValue } }
        return ghostty_input_mods_e(rawValue:v)
    }
    override func keyDown(with e: NSEvent) {
        if performKeyEquivalent(with:e) { return }
        if optionAsAlt, e.modifierFlags.contains(.option), !hasMarkedText() {
            sendKey(e,action:e.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,text:e.charactersIgnoringModifiers); return
        }
        let wasMarked = hasMarkedText()
        activeKey = e; committed = nil
        interpretKeyEvents([e])
        let result = committed
        activeKey = nil; committed = nil
        if let result { sendKey(e,action:e.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,text:result) }
        else if !wasMarked && !hasMarkedText() { sendKey(e,action:e.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) }
        else if hasMarkedText() { sendKey(e,action:GHOSTTY_ACTION_PRESS,composing:true) }
    }
    override func doCommand(by selector: Selector) {}
    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        unmarkText(); inserted = true
        if activeKey != nil { committed = (committed ?? "") + s }
        else if let p = surface { onMacroInput?(TerminalMacroEvent(kind:"text",text:s)); s.withCString { ghostty_surface_text(p,$0,UInt(s.utf8.count)) } }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        markedSelection = selectedRange
        if let p = surface { marked.withCString { ghostty_surface_preedit(p,$0,UInt(marked.utf8.count)) } }
    }
    func unmarkText() { marked = ""; if let p = surface { ghostty_surface_preedit(p,nil,0) } }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location:NSNotFound,length:0) : NSRange(location:0,length:marked.utf16.count) }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location:NSNotFound,length:0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let source = marked as NSString
        guard range.location != NSNotFound, range.location <= source.length else { return nil }
        let valid = NSIntersectionRange(range,NSRange(location:0,length:source.length)); actualRange?.pointee = valid
        return NSAttributedString(string:source.substring(with:valid))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var x = 0.0,y = 0.0,w = 0.0,h = 0.0
        if let p = surface { ghostty_surface_ime_point(p,&x,&y,&w,&h) }
        return window?.convertToScreen(convert(NSRect(x:x,y:y,width:w,height:h),to:nil)) ?? .zero
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resize() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with e: NSEvent) { mouse(e) }
    override func mouseMoved(with e: NSEvent) { mouse(e) }
    override func mouseExited(with e: NSEvent) { guard pressedButtons.isEmpty && NSEvent.pressedMouseButtons == 0 else { return }; if let p = surface { ghostty_surface_mouse_pos(p,-1,-1,mods(e)) } }
    override func rightMouseDown(with e: NSEvent) { pressedButtons.insert(1); mouse(e); if let p = surface { _ = ghostty_surface_mouse_button(p,GHOSTTY_MOUSE_PRESS,GHOSTTY_MOUSE_RIGHT,mods(e)) } }
    override func rightMouseUp(with e: NSEvent) { pressedButtons.remove(1); mouse(e); if let p = surface { _ = ghostty_surface_mouse_button(p,GHOSTTY_MOUSE_RELEASE,GHOSTTY_MOUSE_RIGHT,mods(e)) } }
    override func otherMouseDown(with e: NSEvent) { pressedButtons.insert(2); mouse(e); if let p = surface { _ = ghostty_surface_mouse_button(p,GHOSTTY_MOUSE_PRESS,GHOSTTY_MOUSE_MIDDLE,mods(e)) } }
    override func otherMouseUp(with e: NSEvent) { pressedButtons.remove(2); mouse(e); if let p = surface { _ = ghostty_surface_mouse_button(p,GHOSTTY_MOUSE_RELEASE,GHOSTTY_MOUSE_MIDDLE,mods(e)) } }
    override func rightMouseDragged(with e: NSEvent) { mouse(e) }
    override func otherMouseDragged(with e: NSEvent) { mouse(e) }
    func mouse(_ e: NSEvent) { if let p = surface { let q = convert(e.locationInWindow,from:nil); ghostty_surface_mouse_pos(p,q.x,q.y,mods(e)) } }
    override func mouseDown(with e: NSEvent) { pressedButtons.insert(0); window?.makeFirstResponder(self); mouse(e); if let p = surface { _ = ghostty_surface_mouse_button(p,GHOSTTY_MOUSE_PRESS,GHOSTTY_MOUSE_LEFT,mods(e)) } }
    override func mouseDragged(with e: NSEvent) { mouse(e) }
    override func mouseUp(with e: NSEvent) { pressedButtons.remove(0); mouse(e); if let p = surface { _ = ghostty_surface_mouse_button(p,GHOSTTY_MOUSE_RELEASE,GHOSTTY_MOUSE_LEFT,mods(e)) } }
    override func scrollWheel(with e: NSEvent) {
        guard let p = surface else { return }
        let phase: Int32 = e.momentumPhase.contains(.began) ? 1 : e.momentumPhase.contains(.changed) ? 3 : e.momentumPhase.contains(.ended) ? 4 : e.momentumPhase.contains(.cancelled) ? 5 : 0
        ghostty_surface_mouse_scroll(p,e.scrollingDeltaX,e.scrollingDeltaY,(e.hasPreciseScrollingDeltas ? 1 : 0) | (phase << 1))
    }
}
#endif
