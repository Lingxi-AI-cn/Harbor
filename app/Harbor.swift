import AppKit
import Foundation
import Darwin

let ink = interfaceColor( 0xe7edf5)
let muted = interfaceColor( 0x8796aa)
let accent = interfaceColor( 0x8ad9b7)
let panelColor = interfaceColor( 0x151e29)
let background = interfaceColor( 0x101720)

struct Connection: Codable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var user: String
    var port: Int = 22
    var kind: String = "SSH"
    var identity = ""
    var x11 = false
    var serial: SerialSettings? = nil
    var desktop: DesktopSettings? = nil
    var folder: String? = nil
    var favorite: Bool? = nil
    var jumpHosts: String? = nil
    var isolatedSSHConfig: Bool? = nil
    // Optional fields keep sessions written before these controls decodable.
    var keepAlive: Bool? = nil
    var compression: Bool? = nil
    var forwardAgent: Bool? = nil
    var forwardsAgent: Bool { forwardAgent ?? HarborDefaults.forwardAgentDefault }
    var autoOpenRemoteFiles: Bool? = nil
    var opensRemoteFiles: Bool { autoOpenRemoteFiles ?? HarborDefaults.autoOpenRemoteFilesDefault }
    var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
    func validate(checkIdentity: Bool = true) throws {
        if kind == "Serial" {
            guard let serial, host == serial.device else { throw HarborError.message(L("Serial settings and device path do not match.")) }
            try serial.validate(); try SessionRules.validateMetadata(self); return
        }
        guard !host.isEmpty, host.utf8.count <= 255, !host.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains), !host.hasPrefix("-"), host.range(of: #"^[A-Za-z0-9._:\-]+$"#, options: .regularExpression) != nil else { throw HarborError.message(L("Enter a hostname or IP address, without spaces or a URL prefix.")) }
        guard (["RDP","VNC"].contains(kind) && user.utf8.count <= 256 && !user.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)) || user.isEmpty || user.range(of: #"^[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil && !user.hasPrefix("-") else { throw HarborError.message(L("The username contains unsupported characters.")) }
        guard (1...65535).contains(port) else { throw HarborError.message(L("The port must be between 1 and 65535.")) }
        guard ["SSH", "SFTP", "VNC", "RDP"].contains(kind) else { throw HarborError.message(L("Unsupported connection type.")) }
        try SessionRules.validateMetadata(self)
        if ["RDP","VNC"].contains(kind) { try desktop?.validate(checkIdentity:checkIdentity) }
        guard !checkIdentity || identity.isEmpty || FileManager.default.fileExists(atPath: (identity as NSString).expandingTildeInPath) else { throw HarborError.message(L("The selected private key file does not exist.")) }
    }
    func command(includeJump: Bool = true) -> (String, [String]) {
        if kind == "Serial", let serial {
            return (Bundle.main.executableURL?.path ?? CommandLine.arguments[0],["--serial-bridge",serial.encodeArgument()])
        }
        var args = [String]()
        if kind == "SFTP" { args = ["-P", "\(port)"] }
        else { args = HarborDefaults.sshOptions(keepAlive: keepAlive == true, compression: compression == true, forwardAgent: forwardsAgent) + ["-p", "\(port)"]; if x11 { args += ["-X","-o","XAuthLocation=/opt/X11/bin/xauth"] } }
        if isolatedSSHConfig == true { args = ["-F", "/dev/null"] + args }
        if includeJump, let route = jumpHosts, !route.isEmpty { args += ["-J", route] }
        if !identity.isEmpty { args += ["-i", (identity as NSString).expandingTildeInPath] }
        args += [destination]
        return (kind == "SFTP" ? "/usr/bin/sftp" : "/usr/bin/ssh", args)
    }
}

enum HarborError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

final class SessionStore {
    let url: URL
    var connections: [Connection] = []
    var recent: [RecentConnection] = []
    var recentURL: URL { url.deletingPathExtension().appendingPathExtension("recent.json") }
    init(url: URL? = nil) throws {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Harbor/sessions.json")
        if FileManager.default.fileExists(atPath: self.url.path) { connections = try JSONDecoder().decode([Connection].self, from: Data(contentsOf: self.url)) }
        if let data = try? Data(contentsOf:recentURL), let values = try? JSONDecoder().decode([RecentConnection].self,from:data) { recent = Array(values.prefix(30)) }
    }
    func save() throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(connections).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}


/// Dynamic colors are resolved by the drawing view's effective appearance.
func interfaceColor(_ dark: UInt32) -> NSColor {
    let light: UInt32
    switch dark {
    case 0xe7edf5: light = 0x202d3b
    case 0x8796aa: light = 0x526579
    case 0x8ad9b7: light = 0x176e50
    case 0x151e29: light = 0xffffff
    case 0x101720: light = 0xf2f5f8
    case 0x10251e: light = 0xffffff
    case 0x243b3b: light = 0xdcefe6
    case 0x18232e: light = 0xe8eef3
    case 0x6f8297: light = 0x526579
    case 0x263341: light = 0xcbd6df
    case 0x29483f: light = 0xd5ecdf
    case 0x202d3b: light = 0xe6edf3
    case 0x344456: light = 0xb9c8d5
    case 0x1a2930: light = 0xe0eeea
    case 0x283441: light = 0xd5dee6
    case 0x64788c: light = 0x526579
    case 0x131c26: light = 0xe5ecf2
    case 0x121b25: light = 0xeaf0f5
    case 0x111a24: light = 0xe5ecf2
    case 0x121c26: light = 0xeaf0f5
    case 0x1a2b2c: light = 0xdcefe6
    case 0x141e29: light = 0xeaf0f5
    default: light = dark
    }
    return NSColor(name:nil) { appearance in
        NSColor(hex:appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark : light)
    }
}

class Canvas: NSView {
    let canvasColor: NSColor
    var canvasBorderColor: NSColor? { didSet { refreshColors() } }
    func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = canvasColor.cgColor
            layer?.borderColor = canvasBorderColor?.cgColor
        }
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshColors() }
    override var isFlipped: Bool { true }
    init(_ color: NSColor = background, radius: CGFloat = 0) {
        canvasColor = color
        super.init(frame: .zero); wantsLayer = true; layer?.cornerRadius = radius; refreshColors()
    }
    required init?(coder: NSCoder) { fatalError() }
}

func label(_ text: String, size: CGFloat = 13, color: NSColor = ink, weight: NSFont.Weight = .regular) -> NSTextField {
    let v = NSTextField(wrappingLabelWithString: text)
    v.font = .systemFont(ofSize: size, weight: weight); v.textColor = color; v.isSelectable = false
    v.maximumNumberOfLines = 0
    return v
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, symbol: String? = nil, primary: Bool = false, handler: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; self.handler = handler; target = self; action = #selector(invoke)
        bezelStyle = .rounded; controlSize = .large; font = .systemFont(ofSize: 12, weight: .medium)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = .imageLeading }
        if primary { bezelColor = accent; contentTintColor = interfaceColor( 0x10251e) }
        else { contentTintColor = ink }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func invoke() { handler?() }
}

func iconButton(_ title: String, symbol: String, handler: @escaping () -> Void) -> ActionButton {
    let button = ActionButton(title,symbol:symbol,handler:handler)
    button.imagePosition = .imageOnly; button.toolTip = title; button.setAccessibilityLabel(title)
    return button
}

final class SessionTabItem: Canvas {
    let selectButton: ActionButton
    let closeButton: ActionButton
    init(title: String, active: Bool, closing: Bool, select: @escaping () -> Void, close: @escaping () -> Void) {
        selectButton = ActionButton(title,symbol:"terminal",handler:select)
        closeButton = iconButton(L("Close session: ") + title,symbol:"xmark",handler:close)
        super.init(active ? interfaceColor(0x243b3b) : interfaceColor(0x18232e),radius:7)
        layer?.borderWidth = active ? 1 : 0
        canvasBorderColor = accent.withAlphaComponent(0.5)
        selectButton.isBordered = false; selectButton.contentTintColor = active ? accent : muted
        selectButton.cell?.lineBreakMode = .byTruncatingTail; selectButton.toolTip = title
        selectButton.setAccessibilityLabel(title + (active ? L(", active session") : ""))
        closeButton.isBordered = false; closeButton.contentTintColor = muted; closeButton.isEnabled = !closing
        addSubview(selectButton); addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        selectButton.frame = NSRect(x:5,y:1,width:max(0,bounds.width-36),height:30)
        closeButton.frame = NSRect(x:bounds.width-29,y:3,width:26,height:26)
    }
}

final class ConnectionCard: Canvas {
    let openButton: ActionButton
    let icon: NSTextField, titleLabel: NSTextField, subtitle: NSTextField, hint: NSTextField
    var handler: (() -> Void)?
    init(icon: String, title: String, subtitle: String, hint: String, action: @escaping () -> Void) {
        openButton = ActionButton("",handler:action)
        openButton.isBordered = false; openButton.setAccessibilityLabel(title); openButton.toolTip = subtitle
        self.icon = label(icon, size: 23, color: accent, weight: .medium)
        titleLabel = label(title, size: 14, weight: .semibold)
        self.subtitle = label(subtitle, size: 11, color: muted)
        self.hint = label(hint, size: 10, color: interfaceColor( 0x6f8297))
        super.init(panelColor, radius: 12); handler = action
        layer?.borderWidth = 1; canvasBorderColor = interfaceColor(0x263341)
        [self.icon, titleLabel, self.subtitle, self.hint].forEach { $0.setAccessibilityElement(false); addSubview($0) }
        addSubview(openButton)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        icon.frame = NSRect(x:16,y:13,width:30,height:30)
        titleLabel.frame = NSRect(x:54,y:17,width:bounds.width-68,height:22)
        subtitle.frame = NSRect(x:16,y:47,width:bounds.width-32,height:20)
        hint.frame = NSRect(x:16,y:bounds.height-23,width:bounds.width-32,height:16)
        openButton.frame = bounds
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { handler?() }
}

final class HomeSessionButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false
    private let handler: () -> Void
    init(connection: Connection, openedAt: Date?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        title = connection.name.isEmpty ? connection.destination : connection.name
        font = .systemFont(ofSize: 12, weight: .medium)
        isBordered = false; setButtonType(.momentaryPushIn)
        target = self; action = #selector(openSession)
        var details = [title, L("Protocol: \(L10n.text(connection.kind))")]
        if let serial = connection.serial, connection.kind == "Serial" {
            details.append(L("Device: \(serial.device)"))
        } else {
            details.append(L("Host: \(connection.host)"))
            details.append(L("Port: \(connection.port)"))
            if !connection.user.isEmpty { details.append(L("User: \(connection.user)")) }
        }
        if let folder = connection.folder, !folder.isEmpty { details.append(L("Folder: \(folder)")) }
        if let jumps = connection.jumpHosts, !jumps.isEmpty { details.append(L("SSH gateways: \(jumps)")) }
        if let openedAt { details.append(L("Last opened: ") + openedAt.formatted()) }
        toolTip = details.joined(separator: "\n")
        setAccessibilityLabel(title); setAccessibilityHelp(toolTip)
    }
    required init?(coder: NSCoder) { fatalError() }
    var preferredWidth: CGFloat { min(260, max(64, (title as NSString).size(withAttributes:[.font:font!]).width + 28)) }
    @objc private func openSession() { handler() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options:[.mouseEnteredAndExited,.mouseMoved,.activeAlways,.enabledDuringMouseDrag,.inVisibleRect], owner:self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { if !hovered { hovered = true; needsDisplay = true } }
    override func resetCursorRects() { addCursorRect(bounds, cursor:.pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        let active = hovered || isHighlighted
        let shape = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5), xRadius:8, yRadius:8)
        (active ? interfaceColor(0x29483f) : interfaceColor(0x202d3b)).setFill(); shape.fill()
        (active ? accent.withAlphaComponent(0.7) : interfaceColor(0x344456)).setStroke(); shape.lineWidth = 1; shape.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key:Any] = [.font:font!, .foregroundColor:active ? accent : ink, .paragraphStyle:paragraph]
        let height = (title as NSString).size(withAttributes:attrs).height
        (title as NSString).draw(in:NSRect(x:12,y:(bounds.height-height)/2,width:max(0,bounds.width-24),height:height),withAttributes:attrs)
    }
}

final class WelcomeView: Canvas {
    weak var owner: AppController?
    let eyebrow = label(L("ONE WORKSPACE. EVERY CONNECTION."), size: 10, color: accent, weight: .semibold)
    let headline = label(L("A little more calm.\nA lot more connected."), size: 34, weight: .semibold)
    let summary = label(L("Your terminals, remote files and saved sessions,\ntogether in a workspace made for Mac."), size: 13, color: muted)
    let quick = Canvas(interfaceColor( 0x1a2930), radius: 14)
    let quickTitle = label(L("Make a connection"), size: 16, weight: .semibold)
    let quickNote = label(L("Open an SSH terminal"), size: 11, color: muted)
    let hostField = NSTextField()
    var quickButton: ActionButton!
    let sectionTitle = label(L("START SOMETHING"), size: 10, color: muted, weight: .semibold)
    var cards: [ConnectionCard] = []
    let activity = Canvas(panelColor, radius: 12)
    let activityTitle = label(L("Your sessions"), size: 15, weight: .semibold)
    let activityBody = label(L("No saved connections yet.\nAdd your first server and find it here next time."), size: 12, color: muted)
    let activityScroll = NSScrollView(), activityTags = Canvas(panelColor)
    var sessionTags: [HomeSessionButton] = []
    let activityRule = Canvas(interfaceColor( 0x283441))
    let tools = Canvas(panelColor, radius: 12)
    let toolsTitle = label(L("Ready on this Mac"), size: 15, weight: .semibold)
    let toolsBody = label(L("●  Local shell                         zsh\n●  Secure connections          OpenSSH\n●  File transfers                    SFTP\n●  Remote desktops              Embedded / external"), size: 12, color: muted)
    let footer = label(L("BUILT FOR YOUR MAC  /  POWERED BY OPENSSH"), size: 9, color: interfaceColor( 0x64788c), weight: .medium)
    init(owner: AppController) {
        self.owner = owner; super.init()
        hostField.placeholderString = "user@hostname"; hostField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hostField.bezelStyle = .roundedBezel; hostField.focusRingType = .none
        quickButton = ActionButton(L("Connect"), symbol: "arrow.right", primary: true) { [weak self] in self?.connectQuick() }
        hostField.target = self; hostField.action = #selector(connectQuick)
        [quickTitle, quickNote, hostField, quickButton].forEach(quick.addSubview)
        cards = [
            ConnectionCard(icon: ">_", title: L("Local terminal"), subtitle: L("A real shell. Right here."), hint: L("⌘T  NEW TERMINAL")) { [weak owner] in owner?.newLocal() },
            ConnectionCard(icon: "↗", title: L("SSH session"), subtitle: L("A secure path to your server."), hint: L("PORT 22  /  OPENSSH")) { [weak owner] in owner?.showConnection(kind: "SSH") },
            ConnectionCard(icon: "⇄", title: L("SFTP transfer"), subtitle: L("Move files, securely."), hint: L("BROWSE  /  UPLOAD  /  DOWNLOAD")) { [weak owner] in owner?.showConnection(kind: "SFTP") },
            ConnectionCard(icon: "⌘", title: L("Serial"), subtitle: L("Connect a serial device."), hint: L("PORT / BAUD / FLOW CONTROL")) { [weak owner] in owner?.showConnection(kind: "Serial") },
            ConnectionCard(icon: "▣", title: "RDP", subtitle: L("Open a Windows desktop."), hint: L("PORT 3389 / REMOTE DESKTOP")) { [weak owner] in owner?.showConnection(kind: "RDP") },
            ConnectionCard(icon: "▤", title: "VNC", subtitle: L("Share a remote desktop."), hint: L("PORT 5900 / SCREEN SHARING")) { [weak owner] in owner?.showConnection(kind: "VNC") },
            ConnectionCard(icon: "⌁", title: L("SSH tunnel"), subtitle: L("Bring a remote service closer."), hint: L("LOCAL / REMOTE / SOCKS")) { [weak owner] in owner?.showTunnel() }
        ]
        activityScroll.documentView = activityTags; activityScroll.drawsBackground = false
        activityScroll.hasVerticalScroller = true; activityScroll.autohidesScrollers = true; activityScroll.scrollerStyle = .overlay
        [activityTitle, activityBody, activityRule, activityScroll].forEach(activity.addSubview)
        [toolsTitle, toolsBody].forEach(tools.addSubview)
        [eyebrow, headline, summary, quick, sectionTitle, activity, tools, footer].forEach(addSubview)
        cards.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func connectQuick() {
        let raw = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        owner?.connect(Connection(name: raw, host: String(parts.last ?? ""), user: parts.count > 1 ? String(parts[0]) : ""))
    }
    func refresh() {
        sessionTags.forEach { $0.removeFromSuperview() }; sessionTags.removeAll()
        guard let owner else { return }
        // Recently opened first; saved connections remain available before their first use.
        var seen = Set<UUID>()
        let recent = owner.store.recent.sorted { $0.openedAt > $1.openedAt }
        let sessions = recent.map { record in owner.store.connections.first { $0.id == record.connection.id } ?? record.connection } + owner.store.connections
        for connection in sessions where seen.insert(connection.id).inserted {
            let date = recent.first { $0.connection.id == connection.id }?.openedAt
            let tag = HomeSessionButton(connection:connection,openedAt:date) { [weak owner] in owner?.connect(connection) }
            sessionTags.append(tag); activityTags.addSubview(tag)
        }
        activityBody.isHidden = !sessionTags.isEmpty; activityScroll.isHidden = sessionTags.isEmpty
        needsLayout = true
    }
    override func layout() {
        let pad: CGFloat = 32, w = bounds.width - 64, quickW: CGFloat = 260
        eyebrow.frame = NSRect(x: pad, y: 30, width: w, height: 16)
        headline.frame = NSRect(x: pad, y: 64, width: w - quickW - 20, height: 94)
        summary.frame = NSRect(x: pad, y: 172, width: w - quickW - 10, height: 52)
        quick.frame = NSRect(x: bounds.width - pad - quickW, y: 61, width: quickW, height: 166)
        quickTitle.frame = NSRect(x: 20, y: 18, width: 220, height: 24)
        quickNote.frame = NSRect(x: 20, y: 47, width: 220, height: 17)
        hostField.frame = NSRect(x: 18, y: 77, width: 224, height: 28)
        quickButton.frame = NSRect(x: 15, y: 118, width: 230, height: 32)
        sectionTitle.frame = NSRect(x: pad, y: 258, width: w, height: 18)
        let cardW = (w - 36) / 4
        for (i, card) in cards.enumerated() { card.frame = NSRect(x: pad + CGFloat(i % 4) * (cardW + 12), y: 289 + CGFloat(i / 4) * 112, width: cardW, height: 100) }
        let lowerY: CGFloat = 525, lowerH = max(154, bounds.height - lowerY - 48)
        activity.frame = NSRect(x: pad, y: lowerY, width: w * 0.54 - 8, height: lowerH)
        tools.frame = NSRect(x: pad + w * 0.54 + 8, y: lowerY, width: w * 0.46 - 8, height: lowerH)
        activityTitle.frame = NSRect(x: 20, y: 18, width: activity.bounds.width - 40, height: 24)
        activityRule.frame = NSRect(x: 20, y: 54, width: activity.bounds.width - 40, height: 1)
        activityBody.frame = NSRect(x: 20, y: 73, width: activity.bounds.width - 40, height: 82)
        activityScroll.frame = NSRect(x:20,y:70,width:max(1,activity.bounds.width-40),height:max(36,activity.bounds.height-86))
        let tagWidth = max(1,activityScroll.contentSize.width - 4)
        var x: CGFloat = 0, y: CGFloat = 0
        for tag in sessionTags {
            let width = min(tag.preferredWidth,tagWidth)
            if x > 0 && x + width > tagWidth { x = 0; y += 40 }
            tag.frame = NSRect(x:x,y:y,width:width,height:32); x += width + 8
        }
        activityTags.frame = NSRect(x:0,y:0,width:activityScroll.contentSize.width,height:max(activityScroll.contentSize.height,y+32))
        toolsTitle.frame = NSRect(x: 20, y: 18, width: tools.bounds.width - 40, height: 24)
        toolsBody.frame = NSRect(x: 20, y: 57, width: tools.bounds.width - 40, height: 93)
        footer.frame = NSRect(x: pad, y: bounds.height - 27, width: w, height: 15)
    }
}

final class WorkspaceView: Canvas {
    weak var owner: AppController?
    let top = Canvas(interfaceColor( 0x131c26))
    let sidebar = Canvas(interfaceColor( 0x121b25))
    let tabBar = Canvas(interfaceColor( 0x111a24))
    let body = Canvas()
    let statusBar = Canvas(interfaceColor( 0x121c26))
    let brand = label("HARBOR", size: 15, weight: .bold)
    let brandIcon = label("H", size: 22, color: accent, weight: .bold)
    let sideTitle = label(L("SAVED SESSIONS"), size: 10, color: muted, weight: .semibold)
    let empty = label(L("Your connections live here.\nAdd a session to get started."), size: 11, color: muted)
    let localTitle = label(L("ON THIS MAC"), size: 10, color: muted, weight: .semibold)
    let engine = Canvas(interfaceColor( 0x1a2b2c), radius: 10)
    let engineTitle = label(L("●  Local engine"), size: 11, color: accent, weight: .medium)
    let engineBody = label(L("macOS shell + OpenSSH\nCredentials stay in your terminal."), size: 10, color: muted)
    let search = NSSearchField()
    let status = label(L("●  Ready"), size: 10, color: accent)
    let detail = label("Harbor  /  macOS", size: 10, color: muted)
    var newButton: ActionButton!, terminalButton: ActionButton!, filesButton: ActionButton!, localButton: ActionButton!, tunnelButton: ActionButton!, addButton: ActionButton!
    var connectionButtons: [ActionButton] = []
    let sessionScroll = NSScrollView(), sessionDocument = Canvas()
    let sessionScope = NSPopUpButton(frame:.zero,pullsDown:false)
    var collapsedFolders = Set<String>()
    var tabItems: [SessionTabItem] = []
    let tabScroll = NSScrollView()
    var sidebarButton: ActionButton!, overviewButton: ActionButton!, fileCollapseButton: ActionButton!
    private(set) var sidebarHidden = TerminalPreferences.defaults.bool(forKey:"sidebarHidden")
    private var lastActiveGroup: ObjectIdentifier?
    private var revealTab: SessionTabItem?
    var fileBrowser: Canvas?
    let welcome: WelcomeView
    var terminal: NSView?
    init(owner: AppController) {
        self.owner = owner; welcome = WelcomeView(owner: owner); super.init()
        newButton = iconButton(L("New connection…"), symbol: "plus") { [weak owner] in owner?.showConnection() }
        terminalButton = iconButton(L("New local terminal (⌘T)"), symbol: "terminal") { [weak owner] in owner?.newLocal() }
        filesButton = iconButton(L("Show or hide files"), symbol: "folder") { [weak self] in self?.toggleFiles() }
        localButton = ActionButton(L("Local terminal"), symbol: "terminal") { [weak owner] in owner?.newLocal() }
        tunnelButton = ActionButton(L("SSH tunnels"), symbol: "point.3.connected.trianglepath.dotted") { [weak owner] in owner?.showTunnel() }
        addButton = ActionButton("+", symbol: nil) { [weak owner] in owner?.showConnection() }
        sidebarButton = iconButton(L("Show or hide sessions"),symbol:"sidebar.left") { [weak self] in self?.toggleSidebar() }
        overviewButton = iconButton(L("Overview"),symbol:"square.grid.2x2") { [weak owner] in owner?.selectTab(-1) }
        fileCollapseButton = iconButton(L("Hide file browser"),symbol:"sidebar.left") { [weak self] in self?.toggleFiles() }
        fileCollapseButton.isBordered = false
        tabScroll.documentView = tabBar; tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true; tabScroll.autohidesScrollers = true; tabScroll.scrollerStyle = .overlay
        [sidebarButton, overviewButton, tabScroll, newButton, terminalButton, filesButton].forEach(top.addSubview)
        [brandIcon,brand].forEach(sidebar.addSubview)
        [sideTitle, addButton, search, empty, localTitle, localButton, tunnelButton, engine].forEach(sidebar.addSubview)
        [engineTitle, engineBody].forEach(engine.addSubview)
        [status, detail].forEach(statusBar.addSubview)
        [top, sidebar, body, statusBar].forEach(addSubview)
        body.addSubview(welcome)
        search.placeholderString = L("Find a session…"); search.target = self; search.action = #selector(filterSessions)
        sessionScope.addItems(withTitles:[L("All sessions"), L("Favorites"), L("Recently opened")])
        sessionScope.target = self; sessionScope.action = #selector(filterSessions)
        sessionScroll.documentView = sessionDocument; sessionScroll.hasVerticalScroller = true; sessionScroll.drawsBackground = false
        sessionScroll.autohidesScrollers = true; sessionScroll.scrollerStyle = .overlay
        sidebar.addSubview(sessionScope); sidebar.addSubview(sessionScroll)
        refreshSessions(); refreshTabs()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func filterSessions() { refreshSessions() }
    func refreshSessions() {
        connectionButtons.forEach { $0.removeFromSuperview() }; connectionButtons = []
        guard let owner else { return }
        let q = search.stringValue.lowercased()
        let recent = sessionScope.indexOfSelectedItem == 2
        let values = recent ? owner.store.recent.map { record in owner.store.connections.first(where:{$0.id == record.connection.id}) ?? record.connection } : owner.store.connections
        let filtered = values.filter { c in
            (sessionScope.indexOfSelectedItem != 1 || c.favorite == true) && (q.isEmpty || [c.name,c.host,c.user,c.folder ?? ""].contains(where:{$0.lowercased().contains(q)}))
        }
        func addConnection(_ connection: Connection, depth: Int) {
            let b = ActionButton((connection.favorite == true ? "★ " : "") + connection.name,symbol:connection.kind == "SFTP" ? "folder" : "server.rack") { [weak owner] in owner?.connect(connection) }
            b.cell?.lineBreakMode = .byTruncatingTail; b.alignment = .left
            b.toolTip = "\(connection.kind) · \(SessionRules.route(connection))"
            if recent, let date = owner.store.recent.first(where:{$0.connection.id == connection.id})?.openedAt { b.toolTip! += L("\nOpened: ") + date.formatted() }
            b.setAccessibilityLabel(connection.name)
            b.menu = owner.sessionContextMenu(connection)
            b.tag = depth; connectionButtons.append(b); sessionDocument.addSubview(b)
        }
        func addFolder(_ path: String, depth: Int) {
            let collapsed = collapsedFolders.contains(path) && q.isEmpty
            let b = ActionButton(String(path.split(separator:"/").last ?? ""),symbol:collapsed ? "chevron.right" : "chevron.down") { [weak self] in
                guard let self else { return }
                if self.collapsedFolders.contains(path) { self.collapsedFolders.remove(path) } else { self.collapsedFolders.insert(path) }
                self.refreshSessions()
            }
            let menu = NSMenu(); let rename = menu.addItem(withTitle:L("Rename or move folder…"),action:#selector(AppController.renameSessionFolder(_:)),keyEquivalent:""); rename.target = owner; rename.representedObject = path; b.menu = menu
            b.isBordered = false; b.alignment = .left; b.contentTintColor = accent; b.toolTip = path
            b.setAccessibilityLabel(L("Folder: ") + path + (collapsed ? L(", collapsed") : L(", expanded")))
            b.tag = depth; connectionButtons.append(b); sessionDocument.addSubview(b)
        }
        func appendFolder(_ path: String, depth: Int) {
            let prefix = path.isEmpty ? "" : path + "/"
            for c in filtered.filter({($0.folder ?? "") == path}).sorted(by:{$0.name.localizedStandardCompare($1.name) == .orderedAscending}) { addConnection(c,depth:depth) }
            let children = Set(filtered.compactMap { c -> String? in
                let folder = c.folder ?? ""
                guard folder.hasPrefix(prefix), folder != path else { return nil }
                guard let component = folder.dropFirst(prefix.count).split(separator:"/").first else { return nil }
                return prefix + component
            }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for child in children {
                addFolder(child,depth:depth)
                if !collapsedFolders.contains(child) || !q.isEmpty { appendFolder(child,depth:depth+1) }
            }
        }
        if recent { filtered.forEach { addConnection($0,depth:0) } } else { appendFolder("",depth:0) }
        empty.isHidden = !connectionButtons.isEmpty
        sessionScroll.isHidden = connectionButtons.isEmpty
        empty.stringValue = L("No matching sessions.")
        welcome.refresh(); needsLayout = true
    }
    func toggleSidebar() {
        sidebarHidden.toggle(); TerminalPreferences.defaults.set(sidebarHidden,forKey:"sidebarHidden")
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func refreshTabs() {
        tabItems.forEach { $0.removeFromSuperview() }; tabItems = []; revealTab = nil
        let active = owner?.activeGroup
        let activeID = active.map(ObjectIdentifier.init)
        for group in owner?.paneGroups ?? [] {
            guard let tab = group.active else { continue }
            let baseTitle = tab.view.automationBadge + tab.title
            let title = group.panes.count > 1 ? "\(baseTitle) · \(group.panes.count)" : baseTitle
            let item = SessionTabItem(title:title,active:group === active,closing:group.panes.allSatisfy(\.closing),select:{ [weak owner, weak group] in
                guard let owner, let tab = group?.active, let index = owner.tabs.firstIndex(where:{$0 === tab}) else { return }
                owner.selectTab(index)
            },close:{ [weak owner, weak group] in if let group { owner?.closeGroup(group) } })
            tabItems.append(item); tabBar.addSubview(item)
            if group === active, activeID != lastActiveGroup { revealTab = item }
        }
        for run in owner?.desktopRuns ?? [] where run.viewer != nil && !run.closed {
            let item=SessionTabItem(title:"\(run.connection.kind) · \(run.connection.name)",active:owner?.selectedDesktop === run,closing:false,select:{[weak owner,weak run] in if let run{owner?.selectDesktop(run)}},close:{[weak run] in run?.stop()})
            tabItems.append(item);tabBar.addSubview(item);if owner?.selectedDesktop === run{revealTab=item}
        }
        lastActiveGroup = activeID; needsLayout = true
    }
    func showTerminal(_ view: NSView?) {
        if terminal !== view {
            terminal?.removeFromSuperview(); terminal = view
            if let view { body.addSubview(view) }
        }
        welcome.isHidden = view != nil
        status.stringValue = view == nil ? L("●  Ready") : L("●  Terminal open")
        needsLayout = true
    }
    func toggleFiles() {
        if let owner, owner.tabs.indices.contains(owner.selected), owner.tabs[owner.selected].remoteFiles != nil {
            let tab = owner.tabs[owner.selected]; tab.toggleFiles(); showFiles(tab)
        } else if let existing = fileBrowser { existing.removeFromSuperview(); fileBrowser = nil }
        else { let browser = FileBrowser(owner: owner); fileBrowser = browser; body.addSubview(browser) }
        needsLayout = true
    }
    func showFiles(_ tab: TerminalTab?) {
        fileBrowser?.removeFromSuperview(); fileBrowser = nil
        let isActive: Bool
        if let tab, let owner, owner.tabs.indices.contains(owner.selected) {
            isActive = owner.tabs[owner.selected] === tab
        } else { isActive = false }
        if let tab, tab.shouldShowFiles(isActiveSession: isActive), let browser = tab.remoteBrowser {
            fileBrowser = browser; body.addSubview(browser)
        }
        needsLayout = true
    }
    override func layout() {
        let w = bounds.width, h = bounds.height, side: CGFloat = sidebarHidden ? 0 : 220
        let toolbarHeight: CGFloat = 48
        top.frame = NSRect(x:0,y:0,width:w,height:toolbarHeight)
        sidebar.isHidden = sidebarHidden
        sidebar.frame = NSRect(x:0,y:toolbarHeight,width:220,height:max(0,h-toolbarHeight-26))
        body.frame = NSRect(x:side,y:toolbarHeight,width:max(0,w-side),height:max(0,h-toolbarHeight-26))
        statusBar.frame = NSRect(x:0,y:h-26,width:w,height:26)
        sidebarButton.frame = NSRect(x:8,y:8,width:32,height:32)
        overviewButton.frame = NSRect(x:44,y:8,width:32,height:32)
        tabScroll.frame = NSRect(x:84,y:0,width:max(0,w-212),height:48)
        filesButton.frame = NSRect(x:w-120,y:8,width:32,height:32)
        terminalButton.frame = NSRect(x:w-82,y:8,width:32,height:32)
        newButton.frame = NSRect(x:w-44,y:8,width:32,height:32)
        sidebarButton.contentTintColor = sidebarHidden ? muted : accent
        filesButton.contentTintColor = fileBrowser == nil ? muted : accent
        sidebarButton.toolTip = sidebarHidden ? L("Show sessions") : L("Hide sessions")
        filesButton.toolTip = fileBrowser == nil ? L("Show files") : L("Hide files")
        overviewButton.contentTintColor = owner?.selected == -1 ? accent : muted
        brandIcon.frame = NSRect(x:20,y:12,width:26,height:26)
        brand.frame = NSRect(x:54,y:13,width:140,height:24)
        sideTitle.frame = NSRect(x: 22, y: 58, width: 150, height: 18)
        addButton.frame = NSRect(x: 175, y: 52, width: 27, height: 28)
        search.frame = NSRect(x: 17, y: 94, width: 187, height: 25)
        sessionScope.frame = NSRect(x:17,y:128,width:187,height:28)
        empty.frame = NSRect(x:23,y:174,width:177,height:56)
        let localY = max(239,sidebar.bounds.height-245)
        sessionScroll.frame = NSRect(x:10,y:164,width:200,height:max(0,localY-180))
        let listWidth = sessionScroll.contentSize.width
        sessionDocument.frame = NSRect(x:0,y:0,width:listWidth,height:max(sessionScroll.contentSize.height,CGFloat(connectionButtons.count)*34))
        for (i,button) in connectionButtons.enumerated() {
            let indent = CGFloat(min(button.tag,5))*12
            button.frame = NSRect(x:4+indent,y:CGFloat(i)*34,width:max(0,listWidth-8-indent),height:31)
        }
        localTitle.frame = NSRect(x: 22, y: localY, width: 180, height: 18)
        localButton.frame = NSRect(x: 14, y: localY + 29, width: 192, height: 32)
        tunnelButton.frame = NSRect(x: 14, y: localY + 67, width: 192, height: 32)
        engine.frame = NSRect(x: 16, y: sidebar.bounds.height - 103, width: 188, height: 85)
        engineTitle.frame = NSRect(x: 14, y: 13, width: 165, height: 20)
        engineBody.frame = NSRect(x: 14, y: 38, width: 165, height: 36)
        let tabWidth: CGFloat = 188
        tabBar.frame = NSRect(x:0,y:0,width:max(tabScroll.bounds.width,CGFloat(tabItems.count)*(tabWidth+6)),height:48)
        for (i,item) in tabItems.enumerated() { item.frame = NSRect(x:CGFloat(i)*(tabWidth+6),y:8,width:tabWidth,height:32) }
        if let item = revealTab { revealTab = nil; tabBar.scrollToVisible(item.frame) }
        status.frame = NSRect(x: 22, y: 6, width: 260, height: 17)
        detail.frame = NSRect(x: w - 180, y: 6, width: 160, height: 17)
        let browserW: CGFloat = fileBrowser == nil ? 0 : 270
        welcome.frame = NSRect(x: browserW, y: 0, width: body.bounds.width - browserW, height: body.bounds.height)
        terminal?.frame = welcome.frame
        fileBrowser?.frame = NSRect(x:0,y:0,width:270,height:body.bounds.height)
        if let browser = fileBrowser {
            if fileCollapseButton.superview !== browser { browser.addSubview(fileCollapseButton) }
            fileCollapseButton.frame = NSRect(x:236,y:10,width:26,height:26)
        }
    }
}

final class TerminalPaneGroup {
    let layout = TerminalPaneLayout(frame:.zero)
    var panes: [TerminalTab]
    var active: TerminalTab? { panes.first { $0.id == layout.focusedID } ?? panes.first }
    init(_ pane: TerminalTab) { panes = [pane]; layout.setInitial(pane.view,id:pane.id) }
}

final class TerminalTab {
    let id = UUID()
    var title: String
    let view = TerminalHost(frame: .zero)
    var diagnosticDirectory: URL?
    var recordingURL: URL?
    var onStopping: (() -> Void)?
    var onStopped: (() -> Void)?
    var onProcessEnded: (() -> Void)?
    var connection: Connection?
    var tunnel: TunnelDescriptor?
    var running = true
    var closing = false
    private var closed = false
    private var closeError: Error?
    private var closeCallbacks: [(Error?) -> Void] = []
    var reportedWorkingDirectory: String?
    var remoteFiles: SSHFileSession?
    var remoteBrowser: RemoteFileBrowser?
    var filesHidden = false
    var remoteFilesReady = false
    private var manuallyOpenedFiles = false
    var authenticationTimer: Timer?
    init(title: String, connection: Connection? = nil) {
        self.title = title; self.connection = connection
        filesHidden = !(connection?.opensRemoteFiles ?? HarborDefaults.autoOpenRemoteFilesDefault)
    }
    func shouldShowFiles(isActiveSession: Bool) -> Bool {
        guard isActiveSession, !filesHidden else { return false }
        return manuallyOpenedFiles || HarborDefaults.shouldAutoOpenRemoteFiles(
            connected: remoteFilesReady, isActiveSession: isActiveSession,
            enabled: connection?.opensRemoteFiles ?? HarborDefaults.autoOpenRemoteFilesDefault)
    }
    func toggleFiles() {
        if shouldShowFiles(isActiveSession: true) {
            filesHidden = true; manuallyOpenedFiles = false
        } else {
            filesHidden = false; manuallyOpenedFiles = true
        }
    }
    func stopFiles(removeDirectory: Bool = true) {
        remoteFilesReady = false
        authenticationTimer?.invalidate(); authenticationTimer = nil
        remoteFiles?.stop(removeDirectory: removeDirectory); remoteBrowser?.disconnected()
    }
    func stopTerminal(completion: @escaping (Error?) -> Void = { _ in }) {
        if closed { completion(closeError); return }
        closeCallbacks.append(completion)
        guard !closing else { return }
        closing = true; onStopping?(); running = false; view.onEnded = nil
        remoteFilesReady = false; authenticationTimer?.invalidate(); authenticationTimer = nil
        remoteBrowser?.disconnected()
        let finish: (Error?) -> Void = { error in
            self.view.stop(); self.remoteFiles?.cleanup()
            if let directory = self.diagnosticDirectory { try? FileManager.default.removeItem(at:directory); self.diagnosticDirectory = nil }
            self.closed = true; self.closeError = error; self.onStopped?()
            let callbacks = self.closeCallbacks; self.closeCallbacks.removeAll()
            callbacks.forEach { $0(error) }
        }
        if let files = remoteFiles { files.prepareToClose(completion:finish) }
        else { finish(nil) }
    }
    deinit { authenticationTimer?.invalidate(); remoteFiles?.stop(); if let diagnosticDirectory { try? FileManager.default.removeItem(at:diagnosticDirectory) } }
}

final class FileBrowser: Canvas, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: AppController?
    let heading = label(L("LOCAL FILES"), size: 10, color: accent, weight: .semibold)
    let path = NSTextField()
    let table = NSTableView()
    let scroll = NSScrollView()
    let note = label(L("Double-click a folder to browse.\nUse SFTP for remote files."), size: 10, color: muted)
    var entries: [URL] = []
    var directory = FileManager.default.homeDirectoryForCurrentUser
    var up: ActionButton!, transfer: ActionButton!
    init(owner: AppController?) {
        self.owner = owner; super.init(interfaceColor( 0x141e29))
        up = ActionButton(L("Up"), symbol: "arrow.up") { [weak self] in guard let self else { return }; self.directory.deleteLastPathComponent(); self.reload() }
        transfer = ActionButton(L("Open SFTP"), symbol: "arrow.left.arrow.right") { [weak self] in
            if var connection = self?.owner?.currentConnection, connection.kind != "Serial" { connection.kind = "SFTP"; self?.owner?.connect(connection) }
            else { self?.owner?.showConnection(kind: "SFTP") }
        }
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular); path.target = self; path.action = #selector(changePath)
        let column = NSTableColumn(identifier: .init("name")); column.title = L("Name"); column.width = 230
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 29; table.backgroundColor = interfaceColor( 0x141e29)
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openEntry)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        [heading, path, up, transfer, scroll, note].forEach(addSubview)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    func reload() {
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted {
                let a = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let b = (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return a != b ? a : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            path.stringValue = directory.path; table.reloadData()
        } catch { owner?.showError(error) }
    }
    @objc func changePath() {
        let candidate = URL(fileURLWithPath: (path.stringValue as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { owner?.showError(HarborError.message(L("That folder does not exist."))); return }
        directory = candidate; reload()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = entries[row]
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let view = NSTableCellView()
        let text = label((isDir ? "▸  " : "   ") + url.lastPathComponent, size: 11, color: isDir ? accent : ink)
        text.frame = NSRect(x: 8, y: 4, width: 240, height: 20); view.addSubview(text)
        return view
    }
    @objc func openEntry() {
        let row = table.clickedRow; guard entries.indices.contains(row) else { return }
        let url = entries[row]
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { directory = url; reload() }
        else { NSWorkspace.shared.open(url) }
    }
    override func layout() {
        heading.frame = NSRect(x: 16, y: 20, width: 220, height: 18)
        path.frame = NSRect(x: 14, y: 52, width: 242, height: 25)
        up.frame = NSRect(x: 12, y: 87, width: 68, height: 29)
        transfer.frame = NSRect(x: 91, y: 87, width: 166, height: 29)
        scroll.frame = NSRect(x: 8, y: 130, width: 254, height: max(20, bounds.height - 194))
        note.frame = NSRect(x: 17, y: bounds.height - 51, width: 237, height: 38)
    }
}

final class ConnectionEditor: NSObject {
    weak var owner: AppController?
    let window: NSWindow
    let name = NSTextField(), host = NSTextField(), user = NSTextField(), port = NSTextField(), identity = NSTextField()
    let folder = NSTextField(), gateways = NSTextField()
    let favorite = NSButton(checkboxWithTitle:L("Favorite"),target:nil,action:nil)
    let useSSHConfig = NSButton(checkboxWithTitle:L("Use system and ~/.ssh/config settings"),target:nil,action:nil)
    var desktopSettings = DesktopSettings()
    var desktopButton: ActionButton!
    var original: Connection?
    let type = NSPopUpButton(frame: .zero, pullsDown: false)
    let x11 = NSButton(checkboxWithTitle: L("Forward X11 through XQuartz"), target: nil, action: nil)
    let keepAlive = NSButton(checkboxWithTitle: L("Keep SSH connected (every \(HarborDefaults.sshKeepAliveSeconds) seconds)"), target: nil, action: nil)
    let compression = NSButton(checkboxWithTitle: L("Compress SSH traffic"), target: nil, action: nil)
    let forwardAgent = NSButton(checkboxWithTitle: L("Allow SSH agent forwarding"), target: nil, action: nil)
    let autoOpenFiles = NSButton(checkboxWithTitle: L("Open remote files after login"), target: nil, action: nil)
    let save = NSButton(checkboxWithTitle: L("Save this session"), target: nil, action: nil)
    var editingID: UUID?
    init(owner: AppController, kind: String, existing: Connection? = nil) {
        self.owner = owner; original = existing
        desktopSettings = existing?.desktop ?? DesktopSettings(localPort:kind == "VNC" ? 15900 : 13389)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 710), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = existing == nil ? L("New connection") : L("Edit session"); window.appearance = nil
        let content = Canvas(); window.contentView = content
        type.addItems(withTitles: ["SSH", "SFTP", "VNC", "RDP"]); type.selectItem(withTitle: existing?.kind ?? kind)
        type.target = self; type.action = #selector(typeChanged)
        let names = [L("Session name"), L("Host"), L("Username"), L("Port"), L("Private key (optional)")]
        let fields = [name, host, user, port, identity]
        for (i, field) in fields.enumerated() {
            let title = label(names[i], size: 11, color: muted)
            title.frame = NSRect(x: 26, y: 77 + CGFloat(i) * 47, width: 150, height: 18)
            field.frame = NSRect(x: 180, y: 71 + CGFloat(i) * 47, width: i == 4 ? 325 : 380, height: 27)
            content.addSubview(title); content.addSubview(field)
        }
        let heading = label(L("Connect on your terms."), size: 22, weight: .semibold); heading.frame = NSRect(x: 25, y: 20, width: 290, height: 31)
        type.frame = NSRect(x: 434, y: 21, width: 126, height: 30)
        host.placeholderString = "server.example.com"; user.placeholderString = L("Optional"); name.placeholderString = L("My server")
        identity.placeholderString = "~/.ssh/id_ed25519"
        let browse = ActionButton("…") { [weak self] in
            let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.canChooseFiles = true; picker.showsHiddenFiles = true
            if picker.runModal() == .OK, let url = picker.url { self?.identity.stringValue = url.path }
        }; browse.frame = NSRect(x: 512, y: 258, width: 48, height: 29)
        desktopButton=ActionButton(L("Desktop options / SSH tunnel…")) { [weak self] in self?.desktopOptions() }; desktopButton.frame=NSRect(x:180,y:338,width:380,height:32); content.addSubview(desktopButton)
        x11.frame = NSRect(x: 180, y: 308, width: 280, height: 22)
        keepAlive.frame = NSRect(x: 180, y: 338, width: 300, height: 22)
        compression.frame = NSRect(x: 180, y: 368, width: 280, height: 22)
        forwardAgent.frame = NSRect(x: 180, y: 398, width: 280, height: 22)
        forwardAgent.toolTip = L("Allow the SSH server to use your local SSH agent for forwarded connections. Enable for servers you trust.")
        autoOpenFiles.frame = NSRect(x: 180, y: 428, width: 280, height: 22)
        save.frame = NSRect(x: 180, y: 458, width: 280, height: 22); save.state = .on
        for (caption,field,y) in [(L("Folder"),folder,CGFloat(498)),(L("SSH gateways"),gateways,CGFloat(545))] {
            let text = label(caption,size:11,color:muted); text.frame = NSRect(x:26,y:y+5,width:150,height:20)
            field.frame = NSRect(x:180,y:y,width:380,height:27); content.addSubview(text); content.addSubview(field)
        }
        folder.placeholderString = "Production/Databases"
        gateways.placeholderString = "user@jump:22,user@next:22"
        gateways.toolTip = L("Comma-separated SSH gateways, in order. Gateway keys use ~/.ssh/config. Empty uses the normal SSH configuration.")
        favorite.frame = NSRect(x:180,y:585,width:180,height:22); content.addSubview(favorite)
        useSSHConfig.frame = NSRect(x:180,y:612,width:380,height:22); content.addSubview(useSSHConfig)
        useSSHConfig.state = existing?.isolatedSSHConfig == true ? .off : .on
        useSSHConfig.toolTip = L("When off, only these settings and default key locations apply, including on gateways. Imported SSH settings start isolated. When on, gateway-specific keys can be defined in ~/.ssh/config.")
        let cancel = ActionButton(L("Cancel")) { [weak self] in self?.dismiss() }; cancel.frame = NSRect(x: 355, y: 659, width: 94, height: 31)
        let connect = ActionButton(existing == nil ? L("Connect") : L("Save"), primary: true) { [weak self] in self?.submit() }; connect.frame = NSRect(x: 455, y: 659, width: 110, height: 31); connect.keyEquivalent = "\r"
        [heading, type, browse, x11, keepAlive, compression, forwardAgent, autoOpenFiles, save, cancel, connect].forEach(content.addSubview)
        folder.stringValue = existing?.folder ?? ""; gateways.stringValue = existing?.jumpHosts ?? ""
        favorite.state = existing?.favorite == true ? .on : .off
        save.isEnabled = existing == nil
        updateEnabledControls()
        if let c = existing { editingID = c.id; name.stringValue = c.name; host.stringValue = c.host; user.stringValue = c.user; port.stringValue = "\(c.port)"; identity.stringValue = c.identity; x11.state = c.x11 ? .on : .off }
        else { typeChanged() }
        keepAlive.state = existing?.keepAlive == true ? .on : .off
        compression.state = existing?.compression == true ? .on : .off
        forwardAgent.state = (existing?.forwardsAgent ?? HarborDefaults.forwardAgentDefault) ? .on : .off
        autoOpenFiles.state = (existing?.opensRemoteFiles ?? HarborDefaults.autoOpenRemoteFilesDefault) ? .on : .off
    }
    @objc func typeChanged() {
        let kind = type.titleOfSelectedItem ?? "SSH"
        port.stringValue = kind == "VNC" ? "5900" : kind == "RDP" ? "3389" : "22"
        updateEnabledControls()
    }
    func updateEnabledControls() {
        let kind = type.titleOfSelectedItem ?? "SSH"
        let desktop = ["RDP","VNC"].contains(kind)
        desktopButton.isHidden = !desktop
        for control in [x11,keepAlive,compression,forwardAgent,autoOpenFiles] { control.isHidden=desktop }
        x11.isEnabled = kind == "SSH"
        keepAlive.isEnabled = kind == "SSH"
        compression.isEnabled = kind == "SSH"
        forwardAgent.isEnabled = kind == "SSH"
        autoOpenFiles.isEnabled = kind == "SSH"
        identity.isEnabled = kind == "SSH" || kind == "SFTP"
        gateways.isEnabled = kind == "SSH" || kind == "SFTP"
        useSSHConfig.isEnabled = gateways.isEnabled
    }
    func show() { guard let parent = owner?.window else { return }; parent.beginSheet(window) }
    func dismiss() { owner?.window.endSheet(window); window.orderOut(nil); owner?.editor = nil }
    func submit() {
        var c = Connection(name: name.stringValue.isEmpty ? host.stringValue : name.stringValue, host: host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), user: user.stringValue, port: Int(port.stringValue) ?? 0, kind: type.titleOfSelectedItem ?? "SSH", identity: identity.stringValue, x11: x11.state == .on)
        c.desktop = ["RDP","VNC"].contains(c.kind) ? desktopSettings : nil
        c.keepAlive = c.kind == "SSH" && keepAlive.state == .on
        c.compression = c.kind == "SSH" && compression.state == .on
        c.forwardAgent = c.kind == "SSH" && forwardAgent.state == .on
        c.autoOpenRemoteFiles = autoOpenFiles.state == .on
        c.folder = folder.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        c.favorite = favorite.state == .on
        c.jumpHosts = gateways.isEnabled ? gateways.stringValue.trimmingCharacters(in:.whitespacesAndNewlines) : nil
        c.isolatedSSHConfig = useSSHConfig.state == .off
        if let id = editingID { c.id = id }
        do {
            try c.validate(checkIdentity:editingID == nil)
            if editingID != nil || save.state == .on { try owner?.saveConnection(c) }
            let app = owner; let shouldConnect = editingID == nil; dismiss(); if shouldConnect { app?.connect(c) }
        } catch { owner?.showError(error) }
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var workspace: WorkspaceView!
    var store: SessionStore!
    var tabs: [TerminalTab] = []
    var paneGroups: [TerminalPaneGroup] = []
    var selected = -1
    var editor: ConnectionEditor?
    var serialEditor: SerialEditor?
    var desktopRuns: [DesktopRun] = []
    var selectedDesktop:DesktopRun?
    var desktopManager: DesktopManager?
    var productivityStore: ProductivityStore?
    var managedTunnels: [UUID:TunnelRun] = [:]
    var tunnelManager: TunnelManager?
    var broadcastComposer: BroadcastComposer?
    var snippetManager: SnippetManager?
    var macroSource: TerminalHost?
    var startupError: Error?
    var currentConnection: Connection? { tabs.indices.contains(selected) ? tabs[selected].connection : nil }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { store = try SessionStore() }
        catch { startupError = error; store = try! SessionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("harbor-recovery-\(UUID().uuidString).json")) }
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // AppKit otherwise releases a programmatic window on close, before the
        // last-window termination callback reads it. The controller owns it.
        window.isReleasedWhenClosed = false
        window.title = L("Harbor — Remote workspace"); window.minSize = NSSize(width: 1180, height: 850)
        window.appearance = nil; window.backgroundColor = background; window.delegate = self
        workspace = WorkspaceView(owner: self); window.contentView = workspace
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let error = startupError { showError(HarborError.message(L("Your session file could not be read and has been preserved. This run uses temporary storage. \(error.localizedDescription)"))) }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.indices.contains(index + 1) {
            // Exercise the same last-window close path as the red close button.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.capture(CommandLine.arguments[index + 1]); self.window.performClose(nil) }
        }
    }
    func makeMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); main.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        let appearanceMenu = NSMenuItem(title:L("Appearance"),action:nil,keyEquivalent:"")
        appearanceMenu.submenu = NSMenu(title:L("Appearance"))
        for choice in InterfaceAppearance.allCases {
            let title = choice == .system ? L("Follow System (default)") : choice == .light ? L("Light") : L("Dark")
            let item = NSMenuItem(title:title,action:#selector(changeAppearance(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = choice.rawValue
            item.state = choice == InterfaceAppearance.preference ? .on : .off
            appearanceMenu.submenu?.addItem(item)
        }
        appMenu.addItem(appearanceMenu)
        appMenu.addItem(withTitle: L("About Harbor"), action: #selector(about), keyEquivalent: "").target = self
        let languages = NSMenuItem(title:L("Language"),action:nil,keyEquivalent:"")
        languages.submenu = NSMenu(title:L("Language"))
        for choice in AppLanguage.allCases {
            let title = choice == .system ? L("Follow System (default)") : choice == .english ? "English" : "简体中文"
            let item = NSMenuItem(title:title,action:#selector(changeLanguage(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = choice.rawValue
            item.identifier = NSUserInterfaceItemIdentifier("language."+choice.rawValue)
            item.state = L10n.preference == choice ? .on : .off
            languages.submenu?.addItem(item)
        }
        appMenu.addItem(languages)
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: L("Quit Harbor"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); main.addItem(file); file.submenu = NSMenu(title: L("Session"))
        file.title = L("Session")
        for (title, action, key) in [(L("New local terminal"), #selector(menuLocal), "t"), (L("New connection…"), #selector(menuConnect), "n"), (L("Close terminal"), #selector(menuClose), "w"), (L("SSH tunnel…"), #selector(menuTunnel), "")] {
            file.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        file.submenu?.addItem(withTitle:L("Desktop sessions…"),action:#selector(showDesktopSessions),keyEquivalent:"").target=self
        file.submenu?.addItem(withTitle:L("X11 environment…"),action:#selector(x11Diagnostics),keyEquivalent:"").target=self
        file.submenu?.addItem(withTitle:L("Serial connection…"),action:#selector(newSerial),keyEquivalent:"").target = self
        file.submenu?.addItem(.separator())
        for (title, action) in [(L("Split right"),#selector(splitRight)),(L("Split down"),#selector(splitDown)),(L("Next pane"),#selector(nextPane)),(L("Previous pane"),#selector(previousPane)),(L("Equalize panes"),#selector(equalizePanes))] {
            file.submenu?.addItem(withTitle:title,action:action,keyEquivalent:"").target = self
        }
        file.submenu?.addItem(.separator())
        file.submenu?.addItem(withTitle:L("Save workspace"),action:#selector(saveWorkspace),keyEquivalent:"").target = self
        file.submenu?.addItem(withTitle:L("Restore saved workspace…"),action:#selector(restoreWorkspace),keyEquivalent:"").target = self
        file.submenu?.addItem(.separator())
        for (title,action) in [(L("Import Harbor sessions…"),#selector(importSessions)),(L("Import SSH config…"),#selector(importSSHConfig)),(L("Import MobaXterm sessions…"),#selector(importMobaSessions)),(L("Export sessions…"),#selector(exportSessions)),(L("Clear recent connections…"),#selector(clearRecentConnections)),(L("Connection diagnostics…"),#selector(connectionDiagnostics))] { file.submenu?.addItem(withTitle:title,action:action,keyEquivalent:"").target = self }
        file.submenu?.addItem(.separator())
        for (title,action) in [(L("Broadcast input…"),#selector(broadcastInput)),(L("Command snippets…"),#selector(commandSnippets)),(L("New recorded terminal…"),#selector(newRecordedTerminal)),(L("Open recorded copy…"),#selector(recordedCopy)),(L("Reveal session log"),#selector(revealSessionLog))] { file.submenu?.addItem(withTitle:title,action:action,keyEquivalent:"").target = self }
        file.submenu?.addItem(.separator())
        for (title,action) in [(L("Start current session log…"),#selector(startCurrentLog)),(L("Stop current session log"),#selector(stopCurrentLog)),(L("Export terminal history…"),#selector(exportTerminalHistory)),(L("Record macro…"),#selector(startMacroRecording)),(L("Stop and save macro…"),#selector(saveMacroRecording)),(L("Discard macro recording"),#selector(discardMacroRecording)),(L("Replay macro…"),#selector(replayMacro)),(L("Cancel macro playback"),#selector(cancelMacroPlayback))] { file.submenu?.addItem(withTitle:title,action:action,keyEquivalent:"").target = self }
        let edit = NSMenuItem(); edit.title = L("Edit"); edit.submenu = NSMenu(title: L("Edit")); main.addItem(edit)
        for (title, action, key) in [(L("Copy"), #selector(NSText.copy(_:)), "c"), (L("Paste"), #selector(NSText.paste(_:)), "v"), (L("Select All"), #selector(NSText.selectAll(_:)), "a")] { edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key) }
        edit.submenu?.addItem(withTitle:L("Find in terminal…"),action:#selector(findInTerminal),keyEquivalent:"f").target = self
        #if GHOSTTY
        let backend = NSMenuItem(); backend.title = L("Terminal engine"); backend.submenu = NSMenu(title:L("Terminal engine")); main.addItem(backend)
        for value in [TerminalBackend.ghostty, .legacy] {
            let item = backend.submenu!.addItem(withTitle:value == .ghostty ? L("Ghostty (new terminals)") : L("Legacy (new terminals)"),action:#selector(changeBackend(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = value.rawValue; item.state = TerminalBackend.selected == value ? .on : .off
        }
        backend.submenu?.addItem(.separator())
        backend.submenu?.addItem(withTitle:L("Terminal preferences…"),action:#selector(terminalPreferences),keyEquivalent:",").target = self
        backend.submenu?.addItem(withTitle:L("Terminal shortcuts…"),action:#selector(terminalShortcuts),keyEquivalent:"").target = self
        #endif
        NSApp.mainMenu = main
    }
    @objc func changeAppearance(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = InterfaceAppearance(rawValue:raw) else { return }
        InterfaceAppearance.preference = value; InterfaceAppearance.apply(); makeMenu()
    }
    @objc func changeLanguage(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = AppLanguage(rawValue:raw) else { return }
        guard L10n.preference != value else { return }
        L10n.preference = value; makeMenu()
        let alert = NSAlert(); alert.messageText = L("Language saved")
        alert.informativeText = L("The selected language will apply the next time you open Harbor. Existing connections keep running. Unsupported system languages use English.")
        alert.addButton(withTitle:L("OK")); alert.runModal()
    }
    @objc func terminalShortcuts() {
        let alert = NSAlert(); alert.messageText = L("Terminal shortcuts")
        alert.informativeText = L("Applies immediately to Ghostty terminals. Use cmd with optional shift, alt or ctrl, for example cmd+shift+j. Separate alternatives with commas. Standard editing and other built-in Ghostty shortcuts remain available.")
        let form = NSView(frame:NSRect(x:0,y:0,width:440,height:200))
        var fields: [String:NSTextField] = [:]
        for (index,item) in TerminalPreferences.shortcutActions.enumerated() {
            let y = CGFloat(160-index*36)
            let label = NSTextField(labelWithString:item.title); label.frame = NSRect(x:0,y:y,width:200,height:24); form.addSubview(label)
            let field = NSTextField(string:TerminalPreferences.shortcutStrings[item.id] ?? item.defaultKey); field.frame = NSRect(x:220,y:y,width:210,height:26); form.addSubview(field); fields[item.id] = field
        }
        alert.accessoryView = form; alert.addButton(withTitle:L("Save")); alert.addButton(withTitle:L("Cancel")); alert.addButton(withTitle:L("Restore defaults"))
        while true {
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return }
            if response == .alertThirdButtonReturn {
                for item in TerminalPreferences.shortcutActions { fields[item.id]?.stringValue = item.defaultKey }
                continue
            }
            do { try TerminalPreferences.saveShortcuts(fields.mapValues { $0.stringValue }); return }
            catch { showError(error) }
        }
    }
    @objc func terminalPreferences() {
        let alert = NSAlert(); alert.messageText = L("Terminal preferences"); alert.informativeText = L("Applies to new Ghostty terminals. Existing terminals keep their current settings.")
        let form = NSView(frame:NSRect(x:0,y:0,width:420,height:260))
        let title = NSTextField(labelWithString:L("Font size (8–40 pt)")); title.frame = NSRect(x:0,y:224,width:200,height:24); form.addSubview(title)
        let size = NSTextField(string:"\(TerminalPreferences.fontSize)"); size.frame = NSRect(x:270,y:222,width:100,height:26); form.addSubview(size)
        let option = NSButton(checkboxWithTitle:L("Option sends Alt/Esc instead of accented text"),target:nil,action:nil); option.frame = NSRect(x:0,y:5,width:360,height:24); option.state = TerminalPreferences.optionAsAlt ? .on : .off; form.addSubview(option)
        func fieldLabel(_ text: String,_ y: CGFloat) { let l = NSTextField(labelWithString:text); l.frame = NSRect(x:0,y:y,width:200,height:24); form.addSubview(l) }
        fieldLabel(L("Font family"),184)
        let family = NSPopUpButton(frame:NSRect(x:200,y:180,width:210,height:28)); family.addItems(withTitles:Array(Set(NSFontManager.shared.availableFontFamilies + ["JetBrains Mono",TerminalPreferences.fontFamily])).sorted()); family.selectItem(withTitle:TerminalPreferences.fontFamily); form.addSubview(family)
        fieldLabel(L("Colors"),144)
        let theme = NSPopUpButton(frame:NSRect(x:200,y:140,width:210,height:28)); theme.addLocalizedItems(withValues:["Follow Appearance","Harbor Dark","Light","High Contrast"]); theme.selectRawValue(TerminalPreferences.theme); form.addSubview(theme)
        fieldLabel(L("Cursor"),104)
        let cursor = NSPopUpButton(frame:NSRect(x:200,y:100,width:210,height:28)); cursor.addLocalizedItems(withValues:["block","bar","underline"]); cursor.selectRawValue(TerminalPreferences.cursor); form.addSubview(cursor)
        fieldLabel(L("History memory (1–512 MB)"),64)
        let history = NSTextField(string:"\(TerminalPreferences.historyMB)"); history.frame = NSRect(x:270,y:62,width:100,height:26); form.addSubview(history)
        alert.accessoryView = form; alert.addButton(withTitle:L("Save")); alert.addButton(withTitle:L("Cancel"))
        while alert.runModal() == .alertFirstButtonReturn {
            guard let value = Float(size.stringValue), value.isFinite, (8...40).contains(value) else { showError(HarborError.message(L("Font size must be between 8 and 40."))); continue }
            guard let historyValue = Int(history.stringValue), (1...512).contains(historyValue) else { showError(HarborError.message(L("History memory must be between 1 and 512 MB."))); continue }
            TerminalPreferences.fontSize = value; TerminalPreferences.optionAsAlt = option.state == .on
            TerminalPreferences.fontFamily = family.titleOfSelectedItem ?? TerminalPreferences.fontFamily
            TerminalPreferences.theme = theme.rawSelectedValue ?? "Harbor Dark"
            TerminalPreferences.cursor = cursor.rawSelectedValue ?? "block"
            TerminalPreferences.historyMB = historyValue
            return
        }
    }
    @objc func changeBackend(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = TerminalBackend(rawValue:raw) else { return }
        TerminalBackend.selected = value; TerminalPreferences.backend = value.rawValue
        item.menu?.items.forEach { $0.state = ($0 === item) ? .on : .off }
    }
    @objc func menuLocal() { newLocal() }
    @objc func menuConnect() { showConnection() }
    @objc func menuClose() { closeCurrentTab() }
    @objc func menuTunnel() { showTunnel() }
    @objc func about() {
        let alert = NSAlert(); alert.messageText = L("Harbor Terminal")
        alert.informativeText = L("An independent macOS remote workspace.\n\nNative terminal tabs, OpenSSH, interactive SFTP, saved sessions and local SSH forwarding. VNC and RDP offer embedded viewers and an external-client option. X11 requires XQuartz.\n\nTerminal engine: \(TerminalBackend.selected.rawValue). Ghostty-enabled builds offer a legacy fallback for new terminals. Full compatibility and input-method coverage remain under validation. It does not include the original application's servers, plugins or X server. No MobaXterm code, artwork or branding is included.")
        alert.addButton(withTitle:L("OK")); alert.runModal()
    }
    func showError(_ error: Error) { let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = L("Harbor needs your attention"); alert.informativeText = error.localizedDescription; alert.addButton(withTitle:L("OK")); alert.runModal() }
    var activeGroup: TerminalPaneGroup? { guard tabs.indices.contains(selected) else { return nil }; return paneGroups.first { $0.panes.contains(where: { $0 === tabs[selected] }) } }
    @objc func findInTerminal() { if tabs.indices.contains(selected) { tabs[selected].view.showSearch() } }
    @objc func splitRight() { splitCurrent(.right) }
    @objc func splitDown() { splitCurrent(.down) }
    @objc func nextPane() { activeGroup?.layout.focusNext() }
    @objc func previousPane() { activeGroup?.layout.focusNext(backwards:true) }
    @objc func equalizePanes() { activeGroup?.layout.equalize() }
    func splitCurrent(_ direction: PaneDirection) {
        guard let group = activeGroup, let pane = group.active, !pane.closing else { return }
        if pane.tunnel != nil {
            showError(HarborError.message(L("A tunnel already owns its local port. Create a separate tunnel with another port to open a second one.")))
        } else if pane.connection?.kind == "Serial" {
            showError(HarborError.message(L("A serial port has a single owner. Open a separate local terminal or a different serial device instead.")))
        } else if let connection = pane.connection, ["SSH","SFTP"].contains(connection.kind) {
            let command = connection.command()
            launch(title:connection.name,executable:command.0,arguments:command.1,connection:connection,browseRemoteFiles:connection.kind == "SSH",splitGroup:group,splitDirection:direction)
        } else {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            launch(title:L("Local terminal"),executable:FileManager.default.isExecutableFile(atPath:shell) ? shell : "/bin/zsh",arguments:["-l"],workingDirectory:TerminalDirectory.inherited(pane.reportedWorkingDirectory,isLocal:pane.connection == nil),splitGroup:group,splitDirection:direction)
        }
    }
    func newLocal() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let current = tabs.indices.contains(selected) ? tabs[selected] : nil
        let directory = TerminalDirectory.inherited(current?.reportedWorkingDirectory,isLocal:current?.connection == nil)
        launch(title: L("Local terminal"), executable: shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh", arguments: ["-l"], workingDirectory:directory)
    }
    @discardableResult func launch(title: String, executable: String, arguments: [String], connection: Connection? = nil, browseRemoteFiles: Bool = false, workingDirectory: String? = nil, splitGroup: TerminalPaneGroup? = nil, splitDirection: PaneDirection = .right, recordingURL: URL? = nil) -> TerminalTab? {
        guard !quitting else { return nil }
        let tab = TerminalTab(title:(recordingURL == nil ? "" : L("● REC · ")) + title, connection: connection)
        tab.recordingURL = recordingURL
        do {
            var launchArguments = arguments
            if browseRemoteFiles, let connection {
                let files = try SSHFileSession(connection: connection); tab.remoteFiles = files
                launchArguments = files.masterOptions + arguments
            }
            tab.view.onCloseRequested = { [weak self, weak tab] in
                guard let self, let tab, !tab.closing else { return }
                self.requestClosePane(tab)
            }
            tab.view.onEnded = { [weak self, weak tab] in
                guard let tab else { return }; tab.running = false; tab.title += L(" · ended")
                tab.stopFiles(); tab.onProcessEnded?()
                tab.view.notice(L("\r\n[Session ended.]\r\n")); self?.workspace.refreshTabs()
                if let self, self.tabs.indices.contains(self.selected), self.tabs[self.selected] === tab, let connection = tab.connection {
                    self.workspace.status.stringValue = connection.kind == "Serial" ? L("● Serial ended · reconnect from saved session") : L("● \(connection.kind) ended · Connection diagnostics")
                    self.workspace.status.toolTip = connection.kind == "Serial" ? L("Read the serial disconnect reason in this terminal. The device is released when the process exits.") : L("Session → Connection diagnostics. Route: ") + SessionRules.route(connection)
                }
            }
            tab.view.onTitle = { [weak self, weak tab] title in
                guard let tab, tab.running else { return }
                tab.title = (tab.recordingURL == nil ? "" : L("● REC · ")) + (tab.diagnosticDirectory == nil ? "" : L("Diagnostics · ")) + (tab.connection.map { "\($0.name) · \(title)" } ?? title)
                self?.workspace.refreshTabs()
            }
            tab.view.onWorkingDirectory = { [weak tab] path in tab?.reportedWorkingDirectory = path;tab?.remoteBrowser?.receiveDirectory(path) }
            tab.view.onPaneAction = { [weak self, weak tab] action, direction, amount in
                guard let self, let tab, !tab.closing, !self.quitting,
                      let index = self.tabs.firstIndex(where:{ $0 === tab }) else { return }
                self.selectTab(index)
                guard let group = self.activeGroup else { return }
                switch action {
                case "split": if let direction = PaneDirection(rawValue:direction) { self.splitCurrent(direction) }
                case "focus":
                    if direction == "next" || direction == "previous" { group.layout.focusNext(backwards:direction == "previous") }
                    else if let direction = PaneDirection(rawValue:direction) { group.layout.focus(from:tab.id,direction:direction) }
                case "resize": if let direction = PaneDirection(rawValue:direction) { group.layout.resize(from:tab.id,direction:direction,amount:CGFloat(amount)) }
                case "equalize": group.layout.equalize()
                default: break
                }
            }
            tab.view.onFocused = { [weak self, weak tab] in
                DispatchQueue.main.async {
                    guard let self, let tab, !tab.closing,
                          let responder = self.window.firstResponder as? NSView,
                          responder === tab.view || responder.isDescendant(of:tab.view),
                          let index = self.tabs.firstIndex(where: { $0 === tab }), self.selected != index else { return }
                    self.selectTab(index,focusTerminal:false)
                }
            }
            tab.view.onFailure = { [weak self] error in self?.showError(error) }
            tab.view.onAutomationChanged = { [weak self] in self?.workspace.refreshTabs() }
            tab.view.onAutomationError = { [weak self] error in self?.showError(error) }
            var terminalCommand = (executable,launchArguments)
            if connection?.kind == "SSH", connection?.x11 == true, !launchArguments.contains("-x") {
                let display=try X11Support.preflight()
                terminalCommand=("/usr/bin/env",["DISPLAY=\(display)",executable]+launchArguments)
            }
            let command = recordingURL.map { SessionRecording.command(terminalCommand.0,terminalCommand.1,log:$0) } ?? terminalCommand
            try tab.view.start(executable: command.0, arguments: command.1, workingDirectory:workingDirectory)
            tabs.append(tab)
            if let group = splitGroup, let active = group.active {
                group.panes.append(tab)
                if !group.layout.split(active.id,with:tab.view,direction:splitDirection,newID:tab.id) {
                    group.panes.removeAll { $0 === tab }; tabs.removeAll { $0 === tab }; tab.stopTerminal(); return nil
                }
            } else { paneGroups.append(TerminalPaneGroup(tab)) }
            selectTab(tabs.count - 1)
            if let files = tab.remoteFiles {
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self, weak tab] timer in
                    guard let self, let tab, tab.running else { timer.invalidate(); return }
                    guard files.authenticated else { return }
                    timer.invalidate(); tab.authenticationTimer = nil
                    tab.remoteBrowser = RemoteFileBrowser(session: files) { [weak self, weak tab] in
                        guard let self, let tab, tab.running else { return }
                        tab.remoteFilesReady = true
                        if self.tabs.indices.contains(self.selected), self.tabs[self.selected] === tab {
                            self.workspace.showFiles(tab)
                        }
                    }
                    tab.remoteBrowser?.reportingAction = { [weak tab] in
                        guard let tab,tab.running else{return};let a=NSAlert();a.messageText=L("Enable path reporting in this SSH shell?");a.informativeText=L("Run the following only at an idle Bash or Zsh prompt. It adds an OSC 7 prompt hook for this shell session; no startup files are changed. Existing prompt hooks remain. Other shells need their own OSC 7 integration.");a.addButton(withTitle:L("Enable in current shell"));a.addButton(withTitle:L("Cancel"))
                        guard a.runModal() == .alertFirstButtonReturn else{return}
                        _ = tab.view.input(RemoteShellReporting.command,submit:true);tab.remoteBrowser?.follow.state = .on
                    }
                    if self.tabs.indices.contains(self.selected), self.tabs[self.selected] === tab { self.workspace.showFiles(tab) }
                }
                tab.authenticationTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            return tab
        } catch { tab.stopTerminal(); showError(error); return nil }
    }
    var workspaceURL: URL { store.url.deletingLastPathComponent().appendingPathComponent("workspace.json") }
    func workspaceSnapshot() -> WorkspaceSnapshot {
        let groups = paneGroups.compactMap { group -> WorkspaceSnapshot.Group? in
            guard let layout = group.layout.snapshot() else { return nil }
            let panes = group.panes.map { pane -> WorkspaceSnapshot.Pane in
                let session: WorkspaceSession
                if let tunnel = pane.tunnel { session = .tunnel(tunnel) }
                else if let connection = pane.connection { session = .connection(connection) }
                else { session = .local(TerminalDirectory.inherited(pane.reportedWorkingDirectory,isLocal:true)) }
                return .init(id:pane.id,session:session)
            }
            return .init(layout:layout,focused:group.layout.focusedID,panes:panes)
        }
        return WorkspaceSnapshot(groups:groups,selected:tabs.indices.contains(selected) ? tabs[selected].id : nil)
    }
    @objc func saveWorkspace() {
        do {
            guard !tabs.isEmpty, !tabs.contains(where: { $0.closing }) else { throw HarborError.message(L("Open a terminal and wait for closing sessions before saving a workspace.")) }
            try workspaceSnapshot().save(to:workspaceURL)
        } catch { showError(error) }
    }
    @objc func restoreWorkspace() {
        guard !quitting else { return }
        do {
            let snapshot = try WorkspaceSnapshot.load(from:workspaceURL)
            let panes = snapshot.groups.flatMap(\.panes)
            guard !panes.isEmpty else { throw HarborError.message(L("The saved workspace is empty.")) }
            let remote = panes.filter { if case .local = $0.session { return false }; return true }.count
            let alert = NSAlert(); alert.messageText = L("Restore saved workspace?")
            alert.informativeText = L("Open \(panes.count) new terminals in \(snapshot.groups.count) tabs, including \(remote) remote/device connections or tunnels. Existing tabs stay open. Local directories and split layouts are restored; processes, terminal history and commands are not replayed. Remote sessions authenticate again.")
            let destinations = panes.compactMap { pane -> String? in
                switch pane.session {
                case .local: return nil
                case .connection(let c): return "\(c.kind): \(SessionRules.route(c))"
                case .tunnel(let t): return t.summary
                }
            }
            if !destinations.isEmpty { alert.informativeText += "\n\n" + destinations.prefix(8).joined(separator:"\n") + (destinations.count > 8 ? L("\n… and \(destinations.count - 8) more") : "") }
            alert.informativeText += L("\nUnavailable local directories fall back to your home folder.")
            alert.addButton(withTitle:L("Restore")); alert.addButton(withTitle:L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try restoreWorkspaceSnapshot(snapshot)
        } catch { showError(error) }
    }
    func restoreWorkspaceSnapshot(_ snapshot: WorkspaceSnapshot) throws {
        try snapshot.validate()
        let serialPaths = snapshot.groups.flatMap(\.panes).compactMap { pane -> String? in
            if case .connection(let c) = pane.session, c.kind == "Serial" { return c.host }; return nil
        }
        guard Set(serialPaths).count == serialPaths.count,
              !tabs.contains(where: { $0.running && $0.connection?.kind == "Serial" && serialPaths.contains($0.connection!.host) }) else { throw HarborError.message(L("A saved serial device is duplicated or already open. Close its existing terminal before restoring this workspace.")) }
        var created: [TerminalTab] = [], mapped: [UUID:UUID] = [:]
        let previousSelection = tabs.indices.contains(selected) ? tabs[selected].id : nil
        do {
            for saved in snapshot.groups {
                var members: [TerminalTab] = []
                for pane in saved.panes {
                    let tab: TerminalTab?
                    switch pane.session {
                    case .local(let directory):
                        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                        tab = launch(title:L("Local terminal"),executable:FileManager.default.isExecutableFile(atPath:shell) ? shell : "/bin/zsh",arguments:["-l"],workingDirectory:TerminalDirectory.inherited(directory,isLocal:true) ?? FileManager.default.homeDirectoryForCurrentUser.path)
                    case .connection(let connection):
                        let command = connection.command()
                        tab = launch(title:connection.name,executable:command.0,arguments:command.1,connection:connection,browseRemoteFiles:connection.kind == "SSH")
                    case .tunnel(let tunnel):
                        tab = try startTunnel(TunnelProfile(id:tunnel.profileID ?? UUID(),name:L("Restored · \(tunnel.localPort)"),tunnel:tunnel))
                    }
                    guard let tab else { throw HarborError.message(L("Workspace restoration could not start a terminal.")) }
                    created.append(tab); members.append(tab); mapped[pane.id] = tab.id
                }
                let ids = Set(members.map(\.id))
                paneGroups.removeAll { $0.panes.contains { ids.contains($0.id) } }
                let group = TerminalPaneGroup(members[0]); group.panes = members
                guard group.layout.restore(saved.layout.remapping(mapped),views:Dictionary(uniqueKeysWithValues:members.map { ($0.id,$0.view as NSView) }),focused:saved.focused.flatMap { mapped[$0] }) else { throw HarborError.message(L("Workspace layout could not be restored.")) }
                paneGroups.append(group)
            }
            let selectedID = snapshot.selected.flatMap { mapped[$0] } ?? created.last?.id
            selectTab(tabs.firstIndex { $0.id == selectedID } ?? -1)
        } catch {
            let ids = Set(created.map(\.id))
            paneGroups.removeAll { $0.panes.contains { ids.contains($0.id) } }
            tabs.removeAll { ids.contains($0.id) }
            created.forEach { $0.stopTerminal() }
            selectTab(tabs.firstIndex { $0.id == previousSelection } ?? -1)
            throw error
        }
    }
    func selectTab(_ index: Int, focusTerminal: Bool = true) {
        guard index == -1 || tabs.indices.contains(index) else { return };selectedDesktop?.viewer?.surface.releaseKeys();selectedDesktop=nil; selected = index
        if index >= 0, let group = activeGroup {
            group.layout.markFocused(tabs[index].id)
            workspace.showTerminal(group.layout)
            if focusTerminal { window.makeFirstResponder(tabs[index].view) }
        } else { workspace.showTerminal(nil) }
        workspace.refreshTabs()
        workspace.showFiles(index == -1 ? nil : tabs[index])
    }
    func closeCurrentTab() {
        if let selectedDesktop {selectedDesktop.stop();return}
        guard tabs.indices.contains(selected) else { return }
        requestClosePane(tabs[selected])
    }
    func requestClosePane(_ tab: TerminalTab) {
        guard tabs.contains(where:{$0 === tab}), !tab.closing else { return }
        if tab.running {
            let alert = NSAlert(); alert.messageText = L("Close this terminal?"); alert.informativeText = L("The shell or connection and its running commands will be stopped."); alert.addButton(withTitle: L("Close terminal")); alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        closePane(tab)
    }
    func closeGroup(_ group: TerminalPaneGroup) {
        guard paneGroups.contains(where:{$0 === group}), !group.panes.allSatisfy(\.closing) else { return }
        if group.panes.contains(where:{$0.running}) {
            let alert = NSAlert(); alert.messageText = L("Close this session tab?")
            alert.informativeText = L("All \(group.panes.count) terminal pane(s) in this tab will close. Running commands stop and active transfers are cancelled with temporary-file cleanup.")
            alert.addButton(withTitle:L("Close session")); alert.addButton(withTitle:L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for pane in group.panes { closePane(pane) }
    }
    func closePane(_ tab: TerminalTab) {
        guard !tab.closing else { return }
        tab.title += L(" · closing"); workspace.refreshTabs()
        tab.stopTerminal { [weak self, weak tab] error in
            guard let self, let tab else { return }
            if let index = self.tabs.firstIndex(where: { $0 === tab }) {
                let selectedPane = self.tabs.indices.contains(self.selected) ? self.tabs[self.selected] : nil
                let group = self.paneGroups.first { $0.panes.contains(where: { $0 === tab }) }
                group?.panes.removeAll { $0 === tab }; _ = group?.layout.remove(tab.id)
                self.paneGroups.removeAll { $0.panes.isEmpty }
                self.tabs.remove(at:index)
                let replacement = selectedPane === tab ? group?.active ?? self.paneGroups.last?.active : selectedPane
                if let desktop=self.selectedDesktop,!desktop.closed {self.selectDesktop(desktop)}else{self.selectTab(replacement.flatMap { pane in self.tabs.firstIndex { $0 === pane } } ?? -1)}
            }
            if let error, !self.quitting { self.showError(error) }
        }
    }
    func showConnection(kind: String = "SSH", existing: Connection? = nil) {
        if (existing?.kind ?? kind) == "Serial" { showSerial(existing:existing); return }
        guard editor == nil, serialEditor == nil else { return }
        editor = ConnectionEditor(owner: self, kind: kind, existing: existing); editor?.show()
    }
    func saveConnection(_ c: Connection) throws {
        let previous = store.connections
        if let index = store.connections.firstIndex(where: { $0.id == c.id }) { store.connections[index] = c } else { store.connections.append(c) }
        do { try store.save() } catch { store.connections = previous; throw error }
        workspace.refreshSessions()
    }
    @objc func editSaved(_ item: NSMenuItem) {
        if let id = item.representedObject as? String, let c = store.connections.first(where: { $0.id.uuidString == id }) { showConnection(kind: c.kind, existing: c) }
    }
    @objc func deleteSaved(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let c = store.connections.first(where: { $0.id.uuidString == id }) else { return }
        let alert = NSAlert(); alert.messageText = L("Delete \(c.name)?"); alert.informativeText = L("This removes its saved settings. Existing terminals stay open."); alert.addButton(withTitle: L("Delete")); alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let previous = store.connections; store.connections.removeAll { $0.id == c.id }
            do { try store.save(); workspace.refreshSessions() } catch { store.connections = previous; showError(error) }
        }
    }
    func connect(_ c: Connection) {
        do {
            try c.validate()
            if c.kind == "Serial", tabs.contains(where: { $0.running && $0.connection?.kind == "Serial" && $0.connection?.host == c.host }) { throw HarborError.message(L("This serial device already has an open Harbor terminal. Close it before reconnecting.")) }
            if ["RDP","VNC"].contains(c.kind) { try connectDesktop(c); return }
            let (executable, arguments) = c.command()
            if launch(title: c.name.isEmpty ? c.destination : c.name, executable: executable, arguments: arguments, connection: c, browseRemoteFiles: c.kind == "SSH") != nil { recordRecent(c) }
            if c.kind == "SFTP" { tabs.last?.view.notice(L("Harbor SFTP · interactive file transfer\r\nUse ls / cd / lcd / get / put. Type help for all commands.\r\n\r\n")) }
        } catch { showError(error) }
    }
    func showTunnel() {
        do {
            if let tunnelManager { tunnelManager.window?.makeKeyAndOrderFront(nil); return }
            let manager = TunnelManager(hostController:self,store:try p2Store()); tunnelManager = manager; manager.showWindow(nil)
        } catch { showError(error) }
    }
    func capture(_ path: String) {
        workspace.layoutSubtreeIfNeeded()
        guard let bitmap = workspace.bitmapImageRepForCachingDisplay(in: workspace.bounds) else { return }
        workspace.cacheDisplay(in: workspace.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
    private var quitting = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        if let snippetManager, !snippetManager.discard() { return .terminateCancel }
        if tabs.contains(where: { $0.running }) || desktopRuns.contains(where: { $0.active }) {
            let alert = NSAlert(); alert.messageText = L("Quit Harbor?"); alert.informativeText = L("All open shells, connections and tunnels will be stopped. Active transfers will be cancelled and temporary upload cleanup will be attempted before disconnecting. External desktop clients stay open; Harbor removes their temporary configuration and owned tunnels."); alert.addButton(withTitle:L("Quit")); alert.addButton(withTitle:L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        for editor in RemoteTextEditor.openEditors {if let window=editor.window,!editor.windowShouldClose(window){return .terminateCancel}}
        quitting = true
        desktopRuns.forEach { $0.stop() }
        let group = DispatchGroup()
        var errors: [Error] = []
        for tab in tabs {
            group.enter()
            tab.stopTerminal { error in if let error { errors.append(error) }; group.leave() }
        }
        group.notify(queue:.main) {
            for error in errors { self.showError(error) }
            sender.reply(toApplicationShouldTerminate:true)
        }
        return .terminateLater
    }

}

func selfTest() throws {
    func require(_ condition: @autoclosure () -> Bool, _ description: String) throws { if !condition() { throw HarborError.message("FAIL: \(description)") }; print("PASS: \(description)") }
    let workspaceTest = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-workspace-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at:workspaceTest) }
    let wa = UUID(), wb = UUID()
    let workspaceRecord = WorkspaceSnapshot(groups:[.init(layout:.split(.right,0.35,.leaf(wa),.leaf(wb)),focused:wb,panes:[.init(id:wa,session:.local("/tmp")),.init(id:wb,session:.connection(Connection(name:"Test",host:"example.invalid",user:"tester")))])],selected:wb)
    let workspaceFile = workspaceTest.appendingPathComponent("workspace.json")
    try workspaceRecord.save(to:workspaceFile)
    let loadedWorkspace = try WorkspaceSnapshot.load(from:workspaceFile)
    try require(loadedWorkspace.groups[0].layout == workspaceRecord.groups[0].layout && loadedWorkspace.selected == wb,"workspace disk roundtrip preserves nested layout and selection")
    let permissions = try FileManager.default.attributesOfItem(atPath:workspaceFile.path)[.posixPermissions] as? NSNumber
    try require(permissions?.intValue == 0o600,"workspace file is private to its owner")
    var badWorkspace = workspaceRecord; badWorkspace.version = 99
    var rejectedWorkspace = false
    do { try badWorkspace.save(to:workspaceFile) } catch { rejectedWorkspace = true }
    let preservedWorkspace = try WorkspaceSnapshot.load(from:workspaceFile)
    try require(rejectedWorkspace && preservedWorkspace.version == 1,"invalid workspace cannot overwrite valid saved state")
    let duplicateWorkspace = WorkspaceSnapshot(groups:[workspaceRecord.groups[0],workspaceRecord.groups[0]],selected:wa)
    rejectedWorkspace = false; do { try duplicateWorkspace.validate() } catch { rejectedWorkspace = true }
    try require(rejectedWorkspace,"duplicate pane identities across groups are rejected")
    let tunnelRecord = TunnelDescriptor(connection:Connection(name:"Tunnel",host:"example.invalid",user:"tester"),localPort:8081,remote:"127.0.0.1:80")
    try tunnelRecord.validate()
    try require(tunnelRecord.arguments.last == "tester@example.invalid" && tunnelRecord.arguments.contains("127.0.0.1:8081:127.0.0.1:80"),"restored tunnel uses structured loopback forwarding before SSH destination")
    let grid = TerminalGrid(rows: 4, cols: 12)
    grid.feed(Data("hello\r\nworld\u{1b}[1;3HX\u{1b}[31mR\u{1b}[0m".utf8))
    try require(grid.cells[0][2].text == "X" && grid.cells[0][3].color == 1, "VT cursor positioning and SGR color")
    grid.feed(Data("\u{1b}[?1049hCLEAR\u{1b}[?1049l".utf8))
    try require(grid.cells[0][0].text == "h", "alternate screen restores shell content")
    let resized = TerminalGrid(rows: 24, cols: 80)
    resized.feed(Data("\u{1b}[24;80H\u{1b}7".utf8))
    resized.resize(rows: 4, cols: 12)
    resized.feed(Data("\u{1b}8X".utf8))
    try require(resized.cells[3][11].text == "X", "saved cursor is clamped after terminal shrink")
    let utf = TerminalGrid(); let bytes = Array("中".utf8)
    utf.feed(Data(bytes.prefix(1))); utf.feed(Data(bytes.dropFirst()))
    try require(utf.cells[0][0].text == "中" && utf.x == 2, "UTF-8 across read boundaries and wide characters")
    func line(_ grid: TerminalGrid, _ row: Int) -> String { grid.cells[row].map(\.text).joined().trimmingCharacters(in: .whitespaces) }
    let tmux = TerminalGrid(rows: 5, cols: 16)
    // Full-screen redraw and subsequent incremental scrolling must leave the
    // status line outside the pane's scroll region. Feed bytewise like split PTY reads.
    let redraw = "\u{1b}[?1049h\u{1b}[?25l\u{1b}[1;1HONE\u{1b}[2;1HTWO\u{1b}[3;1HTHREE\u{1b}[4;1HFOUR\u{1b}[5;1HSTATUS\u{1b}[1;4r\u{1b}[4;1H\nFIVE"
    for byte in redraw.utf8 { tmux.feed(Data([byte])) }
    try require((0..<5).map { line(tmux, $0) } == ["TWO", "THREE", "FOUR", "FIVE", "STATUS"] && tmux.history.count == 0, "tmux pane scrolling preserves one status row across fragmented PTY reads")
    tmux.feed(Data("\u{1b}[2;1H\u{1b}[2M\u{1b}[1L".utf8))
    try require((0..<5).map { line(tmux, $0) } == ["TWO", "", "FIVE", "", "STATUS"], "tmux insert/delete lines stay within the pane scroll region")
    tmux.feed(Data("\u{1b}[1;1H\u{1b}M".utf8))
    try require((0..<5).map { line(tmux, $0) } == ["", "TWO", "", "FIVE", "STATUS"], "tmux reverse index preserves the status row")
    let graphics = TerminalGrid(rows: 2, cols: 16)
    graphics.feed(Data("\u{1b}(0lqkx\u{1b}(BOK\u{1b})0\u{e}x\u{f}B".utf8))
    try require(line(graphics, 0) == "┌─┐│OK│B", "tmux split borders and charset reset do not print stray selector bytes")
    graphics.feed(Data("\u{1b}]2;hidden title\u{1b}\\\u{1b}[2;1H\u{1b}[7;38;2;12;34;56mX\u{1b}[27mY".utf8))
    try require(line(graphics, 1) == "XY" && graphics.cells[1][0].inverse && !graphics.cells[1][1].inverse && graphics.cells[1][0].color == 0x10c2238, "tmux title strings stay hidden and inverse truecolor resets correctly")
    let alternate = TerminalGrid(rows: 4, cols: 12)
    alternate.feed(Data("SHELL\u{1b}[?1049hFULLSCREEN".utf8)); alternate.resize(rows: 2, cols: 8)
    alternate.feed(Data("\u{1b}[?1049l".utf8))
    try require(alternate.cells.count == 2 && alternate.cells.allSatisfy { $0.count == 8 } && line(alternate, 0) == "SHELL" && alternate.x == 5, "leaving tmux after resize restores the shell with valid dimensions and cursor")
    let viewport = TerminalGrid(rows: 2, cols: 16)
    viewport.feed(Data("OLD\r\nSHELL\r\nPROMPT".utf8))
    let shellHistory = viewport.visibleLines(historyOffset: 1).map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
    viewport.feed(Data("\u{1b}[?1049hPANE\r\nSTATUS".utf8))
    let fullscreen = viewport.visibleLines(historyOffset: 1).map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
    try require(shellHistory == ["OLD", "SHELL"] && fullscreen == ["PANE", "STATUS"], "entering tmux from scrolled shell history draws only the active fullscreen viewport")
    viewport.feed(Data("\u{1b}[?1049l".utf8))
    try require(viewport.visibleLines(historyOffset: 1).map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) } == shellHistory, "leaving tmux restores the shell scrollback viewport")
    let pasteMode = TerminalGrid()
    let pasted = "first\n第二行\n"
    try require(pasteMode.pasteData(pasted) == Data(pasted.utf8), "ordinary paste preserves exact UTF-8 without unsolicited markers")
    pasteMode.feed(Data("\u{1b}[?1;25;2004h".utf8))
    try require(pasteMode.applicationCursorKeys && pasteMode.cursorVisible && pasteMode.pasteData(pasted) == Data(("\u{1b}[200~" + pasted + "\u{1b}[201~").utf8), "tmux-enabled bracketed paste encloses the complete multiline payload once")
    let otherTab = TerminalGrid()
    try require(!otherTab.bracketedPaste, "paste mode is isolated between terminal tabs")
    pasteMode.feed(Data("\u{1b}[?1;2004l".utf8))
    try require(!pasteMode.applicationCursorKeys && pasteMode.pasteData(pasted) == Data(pasted.utf8), "disabling tmux paste mode restores ordinary input")
    let scrollback = TerminalGrid(rows: 1, cols: 8, scrollbackLimit: 3)
    scrollback.feed(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n".utf8))
    try require(scrollback.history.count == 3 && scrollback.plainText == "three\nfour\nfive\n", "scrollback evicts only oldest lines and preserves chronological order")
    scrollback.feed(Data("\u{1b}[?1049hALT\r\n\u{1b}[?1049l".utf8))
    try require(scrollback.history.count == 3, "alternate screen does not enter scrollback")
    scrollback.feed(Data("\u{1b}[3Jnew\r\n".utf8))
    try require(scrollback.history.count == 1 && scrollback.plainText == "new\n", "scrollback clear resets ring ordering")
    let originalLimit = TerminalGrid(rows: 1, cols: 1)
    originalLimit.feed(Data(repeating: 10, count: HarborDefaults.scrollbackLines + 2))
    try require(originalLimit.history.count == 360_000, "360000-line default holds at the actual boundary")
    let c = Connection(name: "Test", host: "example.invalid", user: "operator", port: 2222)
    try c.validate(); let (executable, arguments) = c.command()
    try require(executable == "/usr/bin/ssh" && arguments.suffix(3) == ["-p", "2222", "operator@example.invalid"], "SSH executable and port passed as argument vector")
    func sshConfiguration(_ connection: Connection) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -G prints effective configuration and exits without connecting; ignore personal config.
        process.arguments = ["-G", "-F", "/dev/null"] + connection.command().1
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HarborError.message("FAIL: OpenSSH rejected generated options") }
        return String(decoding: data, as: UTF8.self)
    }
    let disabled = try sshConfiguration(c)
    try require(disabled.contains("serveraliveinterval 0\n") && disabled.contains("compression no\n") && disabled.contains("forwardagent no\n"), "OpenSSH confirms keepalive, compression and agent forwarding disabled by default")
    var enabled = c; enabled.keepAlive = true; enabled.compression = true
    enabled.forwardAgent = true
    let configured = try sshConfiguration(enabled)
    try require(configured.contains("serveraliveinterval 36\n") && configured.contains("compression yes\n") && configured.contains("port 2222\n"), "OpenSSH confirms 36-second keepalive, compression and explicit port")
    try require(configured.contains("forwardagent yes\n"), "OpenSSH confirms enabled agent forwarding")
    var forwardingOff = enabled; forwardingOff.forwardAgent = false
    let restored = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(forwardingOff))
    let restoredConfig = try sshConfiguration(restored)
    try require(!restored.forwardsAgent && restoredConfig.contains("forwardagent no\n"), "explicit false survives saving and disables agent forwarding")
    let legacyData = try JSONEncoder().encode(c)
    let legacy = try JSONDecoder().decode(Connection.self, from: legacyData)
    try require(legacy.keepAlive == nil && legacy.compression == nil && legacy.forwardAgent == nil && !legacy.forwardsAgent && legacy.autoOpenRemoteFiles == nil && legacy.opensRemoteFiles, "legacy sessions retain agent-off and remote-files-on fallbacks")
    var manualFiles = c; manualFiles.autoOpenRemoteFiles = false
    let manualRoundTrip = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(manualFiles))
    try require(!manualRoundTrip.opensRemoteFiles && manualRoundTrip.autoOpenRemoteFiles == false, "disabled remote-file opening survives session encoding without falling back to true")
    let automaticTab = TerminalTab(title: "automatic", connection: legacy)
    let manualTab = TerminalTab(title: "manual", connection: manualRoundTrip)
    try require(!automaticTab.filesHidden && manualTab.filesHidden, "SSH tabs apply their own automatic or manual file visibility preference")
    manualTab.toggleFiles()
    try require(!manualTab.filesHidden && !automaticTab.filesHidden, "manual Files action remains available when automatic opening is disabled")
    try require(!automaticTab.shouldShowFiles(isActiveSession: true), "SSH authentication alone cannot automatically open the SFTP sidebar")
    automaticTab.remoteFilesReady = true
    try require(automaticTab.shouldShowFiles(isActiveSession: true) && !automaticTab.shouldShowFiles(isActiveSession: false), "connected SFTP opens automatically only for its active tab")
    let disabledTab = TerminalTab(title: "disabled", connection: manualRoundTrip)
    disabledTab.remoteFilesReady = true
    try require(!disabledTab.shouldShowFiles(isActiveSession: true), "successful SFTP does not bypass a disabled automatic-open preference")
    try require(manualTab.shouldShowFiles(isActiveSession: true) && !manualTab.shouldShowFiles(isActiveSession: false), "manual Files can show loading or errors without replacing another tab's sidebar")
    automaticTab.toggleFiles()
    try require(!automaticTab.shouldShowFiles(isActiveSession: true), "hiding Files stays hidden after SFTP becomes ready")
    automaticTab.stopFiles()
    try require(!automaticTab.remoteFilesReady, "stopping file operations clears SFTP readiness")
    var invalid = c; invalid.host = "-oProxyCommand=bad"
    do { try invalid.validate(); throw HarborError.message("FAIL: option injection accepted") } catch HarborError.message(let message) where !message.hasPrefix("FAIL:") { print("PASS: option injection rejected") }
    invalid = c; invalid.user = "name\ncommand"; do { try invalid.validate(); throw HarborError.message("FAIL: newline injection accepted") } catch HarborError.message(let message) where !message.hasPrefix("FAIL:") { print("PASS: username newline rejected") }
    invalid = c; invalid.port = 65536
    do { try invalid.validate(); throw HarborError.message("FAIL: invalid port accepted") } catch HarborError.message(let message) where !message.hasPrefix("FAIL:") { print("PASS: invalid port rejected") }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try SessionStore(url: temp.appendingPathComponent("sessions.json")); store.connections = [enabled]; try store.save()
    let loaded = try SessionStore(url: store.url)
    try require(loaded.connections.first?.id == c.id && loaded.connections.first?.port == 2222, "session persistence round trip")
    try require(loaded.connections.first?.keepAlive == true && loaded.connections.first?.compression == true && loaded.connections.first?.forwardAgent == true, "SSH option choices including agent forwarding survive session persistence")
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "saved session permissions are 0600")
    try remoteFilesSelfTest()
    let terminal = PTYSession(); var output = Data(); var ended = false
    terminal.onOutput = { output.append($0) }; terminal.onExit = { ended = true }
    try terminal.start(executable: "/bin/sh", arguments: ["-c", "printf 'harbor-pty-ok\\n'"])
    let deadline = Date().addingTimeInterval(4)
    while !ended && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    try require(String(decoding: output, as: UTF8.self).contains("harbor-pty-ok"), "real PTY shell launch and output")
    try require(ended, "PTY child exit is detected")
    let paste = PTYSession(); var pasteOutput = Data(); var pasteEnded = false; var sent = false
    paste.onOutput = { data in
        pasteOutput.append(data)
        if !sent && String(decoding: pasteOutput, as: UTF8.self).contains("READY") {
            sent = true; paste.send(Data(repeating: 120, count: 131072))
        }
    }
    paste.onExit = { pasteEnded = true }
    try paste.start(executable: "/bin/sh", arguments: ["-c", "stty -echo -icanon; printf READY; dd bs=1 count=131072 2>/dev/null | wc -c"])
    let pasteDeadline = Date().addingTimeInterval(8)
    while !pasteEnded && Date() < pasteDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    defer { paste.stop() }
    try require(pasteEnded && String(decoding: pasteOutput, as: UTF8.self).contains("131072"), "large PTY input survives nonblocking backpressure")
    #if GHOSTTY
    let awkward = ["space name", "single'quote", "$(printf INJECTED)", "semi;colon", "line\nbreak"]
    let bridge = try GhosttyTerminalView.shellCommand(executable:"/usr/bin/printf",arguments:["%s\u{1f}"] + awkward)
    let probe = Process(), pipe = Pipe(); probe.executableURL = URL(fileURLWithPath:"/bin/sh"); probe.arguments = ["-c",bridge]; probe.standardOutput = pipe
    try probe.run(); let actual = pipe.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
    try require(probe.terminationStatus == 0 && String(decoding:actual,as:UTF8.self) == awkward.joined(separator:"\u{1f}") + "\u{1f}", "Ghostty shell bridge preserves exact arguments without expansion")
    var nulRejected = false
    do { _ = try GhosttyTerminalView.shellCommand(executable:"/bin/echo",arguments:["bad\u{0}arg"]) } catch { nulRejected = true }
    try require(nulRejected,"Ghostty shell bridge rejects NUL")
    let routed = try SSHFileSession(connection:Connection(name:"Ghostty config check",host:"example.invalid",user:"test",port:2222))
    defer { routed.stop() }
    let sshArgs = ["-G", "-F", "/dev/null"] + routed.masterOptions + routed.connection.command().1
    let configProbe = Process(), configPipe = Pipe()
    configProbe.executableURL = URL(fileURLWithPath:"/bin/sh")
    configProbe.arguments = ["-c",try GhosttyTerminalView.shellCommand(executable:"/usr/bin/ssh",arguments:sshArgs)]
    configProbe.standardOutput = configPipe; configProbe.standardError = FileHandle.nullDevice
    try configProbe.run(); let configText = String(decoding:configPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self); configProbe.waitUntilExit()
    try require(configProbe.terminationStatus == 0 && configText.contains("port 2222\n") && configText.contains("controlpath \(routed.socket)\n") && configText.contains("controlmaster auto\n"), "Ghostty command bridge preserves SSH master socket and port without connecting")
    #endif
    print("Harbor self-check passed. No network or credentials were used.")
}

@main
struct HarborMain {
    static func main() {
        L10n.configureSystemControls()
        if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--serial-bridge" {
            exit(SerialBridge.main(CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : nil))
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTest() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }; return
        }
        let app = NSApplication.shared
        InterfaceAppearance.apply()
        app.setActivationPolicy(.regular)
        let controller = AppController(); app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

// Presentation titles must never become serial parameters or engine config values.
extension NSPopUpButton {
    func addLocalizedItems(withValues values: [String]) {
        for value in values { addItem(withTitle:L10n.text(value)); lastItem?.representedObject = value }
    }
    var rawSelectedValue: String? { selectedItem?.representedObject as? String }
    func selectRawValue(_ value: String) {
        if let item = itemArray.first(where: { $0.representedObject as? String == value }) { select(item) }
    }
}
