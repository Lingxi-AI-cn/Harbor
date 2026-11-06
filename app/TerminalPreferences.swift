import AppKit

/// Stable domain shared by the Cargo launcher and the native app bundle.
enum TerminalPreferences {
    static let defaults = UserDefaults(suiteName:ProcessInfo.processInfo.environment["HARBOR_TEST_PREFERENCES_DOMAIN"] ?? "local.harbor.terminal.preferences")!
    static var backend: String? { get { defaults.string(forKey:"backend") } set { defaults.set(newValue,forKey:"backend") } }
    static var fontSize: Float {
        get { let v = defaults.float(forKey:"fontSize"); return v.isFinite && (8...40).contains(v) ? v : 14 }
        set { if newValue.isFinite && (8...40).contains(newValue) { defaults.set(newValue,forKey:"fontSize") } }
    }
    static var optionAsAlt: Bool { get { defaults.bool(forKey:"optionAsAlt") } set { defaults.set(newValue,forKey:"optionAsAlt") } }
}

extension TerminalPreferences {
    static var fontFamily: String {
        get { defaults.string(forKey:"fontFamily") ?? "JetBrains Mono" }
        set { if !newValue.isEmpty && !newValue.contains(where: { $0.isNewline || $0 == "\0" || $0 == "\"" }) { defaults.set(newValue,forKey:"fontFamily") } }
    }
    static var theme: String {
        get { let v = defaults.string(forKey:"theme") ?? "Follow Appearance"; return ["Follow Appearance","Harbor Dark","Light","High Contrast"].contains(v) ? v : "Follow Appearance" }
        set { if ["Follow Appearance","Harbor Dark","Light","High Contrast"].contains(newValue) { defaults.set(newValue,forKey:"theme") } }
    }
    static var cursor: String {
        get { let v = defaults.string(forKey:"cursor") ?? "block"; return ["block","bar","underline"].contains(v) ? v : "block" }
        set { if ["block","bar","underline"].contains(newValue) { defaults.set(newValue,forKey:"cursor") } }
    }
    static var historyMB: Int {
        get { let v = defaults.integer(forKey:"historyMB"); return (1...512).contains(v) ? v : 32 }
        set { if (1...512).contains(newValue) { defaults.set(newValue,forKey:"historyMB") } }
    }
    static var resolvedTheme: String {
        theme == "Follow Appearance" ? (InterfaceAppearance.isDark ? "Harbor Dark" : "Light") : theme
    }
    static func colorConfig(for theme: String) -> String {
        let colors = theme == "Light" ? ("f5f5f5","202020") : theme == "High Contrast" ? ("000000","ffffff") : ("0b1118","c7d2df")
        let lightPalette = ["202020","a31c38","176b3b","806000","215ca6","7241a3","126d72","202020","566575","b52542","25733e","8a6500","2766b3","854daf","20777b","404040"]
        let palette = theme == "Light" ? lightPalette.enumerated().map { "palette = \($0.offset)=#\($0.element)\n" }.joined() : ""
        return palette + "background = \(colors.0)\nforeground = \(colors.1)\ncursor-color = \(colors.1)\n"
    }
    static var engineConfig: String {
        colorConfig(for:resolvedTheme) + "font-family = \(fontFamily)\nfont-size = \(fontSize)\ncursor-style = \(cursor)\nscrollback-limit = \(historyMB * 1024 * 1024)\n"
    }
}

struct TerminalShortcut: Equatable {
    let key: String
    let modifiers: Set<String>
    static func parse(_ source: String) throws -> TerminalShortcut {
        let parts = source.lowercased().split(separator:"+",omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:.whitespaces) }
        guard let key = parts.last, !key.isEmpty else { throw invalid(L("Use a shortcut such as cmd+shift+j.")) }
        let modifiers = Set(parts.dropLast())
        guard modifiers.count == parts.count - 1, modifiers.contains("cmd"), modifiers.isSubset(of:["cmd","shift","alt","ctrl"]) else { throw invalid(L("Include cmd once; optional modifiers are shift, alt and ctrl.")) }
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789=-"
        guard ["home","end"].contains(key) || (key.count == 1 && allowed.contains(key)) else { throw invalid(L("Use a letter, digit, =, -, home or end.")) }
        guard !["a","c","v","x","q","w","t","n","h","m","f","d"].contains(key) else { throw invalid(L("That key is reserved for application or standard editing commands.")) }
        return TerminalShortcut(key:key,modifiers:modifiers)
    }
    static func alternatives(_ source: String) throws -> [TerminalShortcut] {
        try source.split(separator:",",omittingEmptySubsequences:false).map { try parse(String($0)) }
    }
    static func invalid(_ message: String) -> NSError { NSError(domain:"HarborShortcut",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}

extension TerminalPreferences {
    static let shortcutActions: [(id:String,title:String,binding:String,defaultKey:String)] = [
        ("zoomIn",L("Increase font size"),"increase_font_size:1","cmd+=,cmd+shift+="),
        ("zoomOut",L("Decrease font size"),"decrease_font_size:1","cmd+-"),
        ("zoomReset",L("Reset font size"),"reset_font_size","cmd+0"),
        ("scrollTop",L("Scroll to top"),"scroll_to_top","cmd+home"),
        ("scrollBottom",L("Scroll to bottom"),"scroll_to_bottom","cmd+end")
    ]
    static var shortcutStrings: [String:String] {
        let saved = defaults.dictionary(forKey:"shortcuts") as? [String:String] ?? [:]
        let merged = Dictionary(uniqueKeysWithValues:shortcutActions.map { ($0.id,saved[$0.id] ?? $0.defaultKey) })
        return (try? validateShortcuts(merged)) != nil ? merged : Dictionary(uniqueKeysWithValues:shortcutActions.map { ($0.id,$0.defaultKey) })
    }
    static func validateShortcuts(_ values: [String:String]) throws {
        var used: [TerminalShortcut] = []
        for action in shortcutActions {
            guard let value = values[action.id] else { throw TerminalShortcut.invalid(L("Missing shortcut for \(action.title).")) }
            for parsed in try TerminalShortcut.alternatives(value) {
                guard !used.contains(parsed) else { throw TerminalShortcut.invalid(L("Two actions cannot use the same shortcut.")) }
                used.append(parsed)
            }
        }
    }
    static func saveShortcuts(_ values: [String:String]) throws { try validateShortcuts(values); defaults.set(values,forKey:"shortcuts") }
}


/// Remote OSC paths must never select a local process directory.
enum TerminalDirectory {
    static func inherited(_ path: String?, isLocal: Bool) -> String? {
        guard isLocal, let path, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:path,isDirectory:&directory), directory.boolValue,
              FileManager.default.isExecutableFile(atPath:path) else { return nil }
        return path
    }
}

/// AppKit propagates a nil application appearance when the system changes.
enum InterfaceAppearance: String, CaseIterable {
    case system, light, dark
    static var preference: InterfaceAppearance {
        get { InterfaceAppearance(rawValue:TerminalPreferences.defaults.string(forKey:"interfaceAppearance") ?? "system") ?? .system }
        set { TerminalPreferences.defaults.set(newValue.rawValue,forKey:"interfaceAppearance") }
    }
    static var isDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
    }
    static func apply() {
        switch preference {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named:.aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named:.darkAqua)
        }
    }
}
