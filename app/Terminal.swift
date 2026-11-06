import AppKit
import Darwin

struct TerminalCell {
    var text = " "
    var color = 7
    var background = -1
    var bold = false
    var inverse = false
}

/// Stores only lines received, with constant-time eviction at the original's larger limit.
struct ScrollbackBuffer {
    let limit: Int
    private var lines: [[TerminalCell]] = []
    private var head = 0
    init(limit: Int) { self.limit = limit }
    var count: Int { lines.count }
    subscript(index: Int) -> [TerminalCell] { lines[(head + index) % lines.count] }
    mutating func append(_ line: [TerminalCell]) {
        guard limit > 0 else { return }
        if lines.count < limit { lines.append(line) }
        else { lines[head] = line; head = (head + 1) % limit }
    }
    mutating func removeAll() { lines.removeAll(); head = 0 }
}

/// A deliberately small VT parser: cursor motion, erase, SGR and alternate screen.
/// This is an independent implementation, not an xterm compatibility claim.
final class TerminalGrid {
    var rows: Int
    var cols: Int
    var cells: [[TerminalCell]]
    var history: ScrollbackBuffer
    var x = 0, y = 0
    var savedX = 0, savedY = 0
    var foreground = 7, background = -1, bold = false
    var inverse = false
    var cursorVisible = true
    var applicationCursorKeys = false
    var bracketedPaste = false
    var autoWrap = true
    var originMode = false
    var graphicCharsets = [false, false]
    var activeCharset = 0
    var charsetTarget: UInt8 = 0
    private var alternateCursor = (x: 0, y: 0)
    var savedScreen: [[TerminalCell]]?
    var scrollTop = 0, scrollBottom: Int
    var mode = 0
    var sequence = ""
    var utf8: [UInt8] = []
    var needed = 0
    var wrapPending = false
    var onReply: ((Data) -> Void)?

    init(rows: Int = 24, cols: Int = 80, scrollbackLimit: Int = HarborDefaults.scrollbackLines) {
        history = ScrollbackBuffer(limit: max(0, scrollbackLimit))
        self.rows = rows; self.cols = cols; scrollBottom = rows - 1
        cells = Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows)
    }
    func resize(rows newRows: Int, cols newCols: Int) {
        guard newRows != rows || newCols != cols else { return }
        for i in cells.indices {
            if newCols > cols { cells[i] += Array(repeating: TerminalCell(), count: newCols - cols) }
            else { cells[i] = Array(cells[i].prefix(newCols)) }
        }
        if newRows > rows { cells += Array(repeating: Array(repeating: TerminalCell(), count: newCols), count: newRows - rows) }
        else { cells = Array(cells.prefix(newRows)) }
        rows = newRows; cols = newCols; x = min(x, cols - 1); y = min(y, rows - 1)
        scrollTop = 0; scrollBottom = rows - 1; wrapPending = false
        // Preserve the shell buffer while a full-screen program owns the display.
        if let screen = savedScreen {
            savedScreen = (0..<rows).map { row in
                let line = row < screen.count ? Array(screen[row].prefix(cols)) : []
                return line + Array(repeating: TerminalCell(), count: cols - line.count)
            }
        }
    }
    func feed(_ data: Data) {
        for byte in data {
            if mode == 3 { if byte == 7 { mode = 0 }; if byte == 27 { mode = 4 }; continue }
            if mode == 4 { mode = byte == 92 ? 0 : 3; continue }
            // ESC ( B and ESC ( 0 designate a charset; their final byte is not text.
            if mode == 5 {
                if byte >= 0x20 && byte <= 0x2f { continue }
                if charsetTarget == 40 || charsetTarget == 41 { graphicCharsets[Int(charsetTarget - 40)] = byte == 48 }
                mode = 0; continue
            }
            if mode == 1 {
                if byte == 91 { mode = 2; sequence = "" }
                else if [UInt8(80), 93, 94, 95].contains(byte) { mode = 3 }
                else if byte >= 0x20 && byte <= 0x2f { charsetTarget = byte; mode = 5 }
                else if byte == 55 { savedX = x; savedY = y; mode = 0 }
                else if byte == 56 { x = min(cols - 1, savedX); y = min(rows - 1, savedY); wrapPending = false; mode = 0 }
                else if byte == 68 { newline(); mode = 0 }
                else if byte == 69 { x = 0; newline(); mode = 0 }
                else if byte == 77 { reverseIndex(); mode = 0 }
                else { mode = 0 }
                continue
            }
            if mode == 2 {
                if byte >= 0x40 && byte <= 0x7e { csi(Character(UnicodeScalar(byte)), sequence); mode = 0 }
                else if sequence.count < 128 { sequence.append(Character(UnicodeScalar(byte))) }
                else { mode = 0 }
                continue
            }
            switch byte {
            case 27: mode = 1; utf8 = []; needed = 0
            case 13: x = 0; wrapPending = false
            case 10, 11, 12: newline()
            case 8: x = max(0, x - 1); wrapPending = false
            case 9: x = min(cols - 1, ((x / 8) + 1) * 8)
            case 14: activeCharset = 1
            case 15: activeCharset = 0
            case 0...31, 127: break
            default:
                if needed > 0 && byte & 0xc0 == 0x80 {
                    utf8.append(byte); needed -= 1
                    if needed == 0 { put(String(decoding: utf8, as: UTF8.self)); utf8 = [] }
                } else if byte < 128 {
                    needed = 0; utf8 = []
                    let graphics: [UInt8: String] = [96: "◆", 97: "▒", 102: "°", 103: "±", 106: "┘", 107: "┐", 108: "┌", 109: "└", 110: "┼", 111: "⎺", 112: "⎻", 113: "─", 114: "⎼", 115: "⎽", 116: "├", 117: "┤", 118: "┴", 119: "┬", 120: "│", 121: "≤", 122: "≥", 123: "π", 124: "≠", 125: "£", 126: "·"]
                    put(graphicCharsets[activeCharset] ? (graphics[byte] ?? String(UnicodeScalar(byte))) : String(UnicodeScalar(byte)))
                }
                else {
                    utf8 = [byte]
                    needed = byte & 0xe0 == 0xc0 ? 1 : byte & 0xf0 == 0xe0 ? 2 : byte & 0xf8 == 0xf0 ? 3 : 0
                    if needed == 0 { put("�") }
                }
            }
        }
    }
    func put(_ text: String) {
        if wrapPending { if autoWrap { x = 0; newline() }; wrapPending = false }
        let wide = text.unicodeScalars.first.map { $0.value >= 0x1100 && ($0.value <= 0x115f || $0.value >= 0x2e80) } ?? false
        if wide && x == cols - 1 { x = 0; newline() }
        cells[y][x] = TerminalCell(text: text, color: foreground, background: background, bold: bold, inverse: inverse)
        if wide && x + 1 < cols { x += 1; cells[y][x] = TerminalCell(text: "", color: foreground, background: background, inverse: inverse) }
        if x == cols - 1 { wrapPending = autoWrap } else { x += 1 }
    }
    private var blank: TerminalCell { TerminalCell(color: foreground, background: background) }
    private var blankLine: [TerminalCell] { Array(repeating: blank, count: cols) }
    private func scrollUp(_ count: Int, top: Int, bottom: Int, saveHistory: Bool = false) {
        for _ in 0..<min(count, bottom - top + 1) {
            if saveHistory && top == 0 && savedScreen == nil { history.append(cells[top]) }
            cells.remove(at: top); cells.insert(blankLine, at: bottom)
        }
    }
    private func scrollDown(_ count: Int, top: Int, bottom: Int) {
        for _ in 0..<min(count, bottom - top + 1) { cells.remove(at: bottom); cells.insert(blankLine, at: top) }
    }
    func reverseIndex() {
        wrapPending = false
        if y == scrollTop { scrollDown(1, top: scrollTop, bottom: scrollBottom) }
        else { y = max(0, y - 1) }
    }
    func newline() {
        wrapPending = false
        if y == scrollBottom {
            scrollUp(1, top: scrollTop, bottom: scrollBottom, saveHistory: true)
        } else { y = min(rows - 1, y + 1) }
    }
    func csi(_ command: Character, _ raw: String) {
        let privateMode = raw.hasPrefix("?")
        let p = raw.replacingOccurrences(of: "?", with: "").split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func value(_ i: Int, _ fallback: Int = 1) -> Int { i < p.count && p[i] > 0 ? p[i] : fallback }
        let first = p.first ?? 0
        let top = originMode ? scrollTop : 0, bottom = originMode ? scrollBottom : rows - 1
        switch command {
        case "A": y = max(y >= scrollTop ? scrollTop : 0, y - value(0))
        case "B": y = min(y <= scrollBottom ? scrollBottom : rows - 1, y + value(0))
        case "C": x = min(cols - 1, x + value(0))
        case "D": x = max(0, x - value(0))
        case "E": y = min(rows - 1, y + value(0)); x = 0
        case "F": y = max(0, y - value(0)); x = 0
        case "G", "`": x = min(cols - 1, value(0) - 1)
        case "d": y = min(bottom, top + value(0) - 1)
        case "H", "f": y = min(bottom, top + value(0) - 1); x = min(cols - 1, value(1) - 1)
        case "J":
            if first == 2 || first == 3 { cells = Array(repeating: blankLine, count: rows); if first == 3 { history.removeAll() } }
            else if first == 0 { for row in y..<rows { for col in (row == y ? x : 0)..<cols { cells[row][col] = blank } } }
            else { for row in 0...y { for col in 0..<(row == y ? x + 1 : cols) { cells[row][col] = blank } } }
        case "K":
            let start = first == 0 ? x : 0, end = first == 1 ? x + 1 : cols
            for col in start..<end { cells[y][col] = blank }
        case "L": if y >= scrollTop && y <= scrollBottom { scrollDown(value(0), top: y, bottom: scrollBottom) }
        case "M": if y >= scrollTop && y <= scrollBottom { scrollUp(value(0), top: y, bottom: scrollBottom) }
        case "S": scrollUp(value(0), top: scrollTop, bottom: scrollBottom, saveHistory: true)
        case "T": scrollDown(value(0), top: scrollTop, bottom: scrollBottom)
        case "@":
            let n = min(value(0), cols - x)
            cells[y].insert(contentsOf: Array(repeating: blank, count: n), at: x); cells[y].removeLast(n)
        case "P":
            let n = min(value(0), cols - x)
            cells[y].removeSubrange(x..<(x + n)); cells[y] += Array(repeating: blank, count: n)
        case "X": for col in x..<min(cols, x + value(0)) { cells[y][col] = blank }
        case "m":
            var i = 0
            while i < p.count {
                let n = p[i]
                if n == 0 { foreground = 7; background = -1; bold = false; inverse = false }
                else if n == 1 { bold = true } else if n == 22 { bold = false }
                else if n == 7 { inverse = true } else if n == 27 { inverse = false }
                else if n >= 30 && n <= 37 { foreground = n - 30 }
                else if n >= 90 && n <= 97 { foreground = n - 90 + 8 }
                else if n >= 40 && n <= 47 { background = n - 40 }
                else if n >= 100 && n <= 107 { background = n - 100 + 8 }
                else if n == 39 { foreground = 7 } else if n == 49 { background = -1 }
                else if (n == 38 || n == 48) && i + 2 < p.count && p[i + 1] == 5 { if n == 38 { foreground = p[i + 2] } else { background = p[i + 2] }; i += 2 }
                else if (n == 38 || n == 48) && i + 4 < p.count && p[i + 1] == 2 {
                    let rgb = 0x1000000 | (min(255, max(0, p[i + 2])) << 16) | (min(255, max(0, p[i + 3])) << 8) | min(255, max(0, p[i + 4]))
                    if n == 38 { foreground = rgb } else { background = rgb }; i += 4
                }
                i += 1
            }
        case "r":
            let newTop = min(rows - 1, value(0) - 1), newBottom = min(rows - 1, value(1, rows) - 1)
            if newTop < newBottom { scrollTop = newTop; scrollBottom = newBottom; x = 0; y = originMode ? scrollTop : 0 }
        case "s": savedX = x; savedY = y
        case "u": x = min(cols - 1, savedX); y = min(rows - 1, savedY)
        case "h", "l":
            if privateMode {
                let enabled = command == "h"
                for flag in p {
                    switch flag {
                    case 1: applicationCursorKeys = enabled
                    case 6: originMode = enabled; x = 0; y = enabled ? scrollTop : 0
                    case 7: autoWrap = enabled
                    case 25: cursorVisible = enabled
                    case 2004: bracketedPaste = enabled
                    default: break
                    }
                }
            }
            if privateMode && p.contains(1049) {
                if command == "h" && savedScreen == nil { savedScreen = cells; alternateCursor = (x, y); cells = Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows); x = 0; y = 0; scrollTop = 0; scrollBottom = rows - 1 }
                else if command == "l", let screen = savedScreen { cells = screen; savedScreen = nil; x = min(cols - 1, alternateCursor.x); y = min(rows - 1, alternateCursor.y); scrollTop = 0; scrollBottom = rows - 1 }
            }
        case "n": if first == 6 { onReply?(Data("\u{1b}[\(y + 1);\(x + 1)R".utf8)) }
        default: break
        }
        if command != "m" { wrapPending = false }
    }
    var plainText: String {
        (0..<(history.count + cells.count)).map { index in
            let line = index < history.count ? history[index] : cells[index - history.count]
            return line.map(\.text).joined().replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }
    func pasteData(_ text: String) -> Data {
        Data((bracketedPaste ? "\u{1b}[200~" + text + "\u{1b}[201~" : text).utf8)
    }
    func visibleLines(historyOffset: Int) -> [[TerminalCell]] {
        // Full-screen programs own the entire viewport even if the user had
        // scrolled back in the shell before the alternate screen was entered.
        let offset = savedScreen == nil ? min(history.count, max(0, historyOffset)) : 0
        let end = history.count + cells.count - offset
        return ((end - rows)..<end).map { $0 < history.count ? history[$0] : cells[$0 - history.count] }
    }
}

final class PTYSession {
    private(set) var fd: Int32 = -1
    private(set) var pid: pid_t = -1
    private var source: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var pendingInput = Data()
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?
    private var ended = false

    func start(executable: String, arguments: [String], rows: Int = 24, cols: Int = 80, workingDirectory: String? = nil) throws {
        let values = [executable] + arguments
        let cArgs = values.map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.merging(["TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8"]) { _, new in new }
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cArgs { free(p) }; for p in cEnv { free(p) } }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let directory = workingDirectory.flatMap { strdup($0) }
        defer { free(directory) }
        let child = forkpty(&fd, nil, nil, &size)
        if child == 0 {
            if let directory, chdir(directory) != 0 { _exit(126) }
            _ = cArgs.withUnsafeBufferPointer { argv in
                cEnv.withUnsafeBufferPointer { env in execve(argv[0]!, UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!)) }
            }
            _exit(127)
        }
        guard child > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        pid = child
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler { [weak self] in
            guard let self, !self.ended else { return }
            var buffer = [UInt8](repeating: 0, count: 32768)
            while true {
                let count = Darwin.read(self.fd, &buffer, buffer.count)
                if count > 0 { self.onOutput?(Data(buffer.prefix(count))) }
                else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { self.finish(); break }
                else { break }
            }
        }
        let handle = fd
        reader.setCancelHandler { Darwin.close(handle) }
        source = reader; reader.resume()
    }
    func send(_ data: Data) {
        guard !ended, fd >= 0 else { return }
        pendingInput.append(data)
        flushInput()
    }
    private func flushInput() {
        while !pendingInput.isEmpty && !ended {
            let count = pendingInput.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count > 0 { pendingInput.removeFirst(count); continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let writable = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
                    writable.setEventHandler { [weak self] in self?.flushInput() }
                    writer = writable; writable.resume()
                }
                return
            }
            finish(); return
        }
        writer?.cancel(); writer = nil
    }
    func resize(rows: Int, cols: Int) {
        guard fd >= 0, !ended else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, UInt(TIOCSWINSZ), &size)
    }
    private func finish() {
        guard !ended else { return }; ended = true
        writer?.cancel(); writer = nil; pendingInput.removeAll()
        source?.cancel(); source = nil
        let child = pid
        if child > 0 { DispatchQueue.global().async { var status: Int32 = 0; _ = waitpid(child, &status, 0) } }
        onExit?()
    }
    func stop() {
        if pid > 0 && !ended { kill(-pid, SIGHUP); kill(pid, SIGHUP) }
        finish()
    }
    deinit { stop() }
}

final class TerminalView: NSView {
    var onMacroInput: ((TerminalMacroEvent)->Void)?
    var onRawOutput: ((Data)->Void)?
    var onFocused: (() -> Void)?
    override func becomeFirstResponder() -> Bool { onFocused?(); return true }
    let grid = TerminalGrid()
    let session = PTYSession()
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    let charWidth: CGFloat = 8
    let lineHeight: CGFloat = 19
    var historyOffset = 0
    var onEnded: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        session.onOutput = { [weak self] data in self?.onRawOutput?(data); self?.grid.feed(data); self?.needsDisplay = true }
        session.onExit = { [weak self] in self?.onEnded?() }
        grid.onReply = { [weak self] data in self?.session.send(data) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let cols = max(20, Int((bounds.width - 32) / charWidth)), rows = max(4, Int((bounds.height - 24) / lineHeight))
        grid.resize(rows: rows, cols: cols); session.resize(rows: rows, cols: cols)
        historyOffset = min(historyOffset, grid.history.count); needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    private let colorTheme = TerminalPreferences.theme
    private var resolvedColorTheme: String { colorTheme == "Follow Appearance" ? (InterfaceAppearance.isDark ? "Harbor Dark" : "Light") : colorTheme }
    var terminalBackground: NSColor { NSColor(hex:resolvedColorTheme == "Light" ? 0xf5f5f5 : resolvedColorTheme == "High Contrast" ? 0x000000 : 0x0b1118) }
    func color(_ index: Int) -> NSColor {
        if index >= 0x1000000 { return NSColor(hex: UInt32(index & 0xffffff)) }
        let palette: [UInt32] = resolvedColorTheme == "Light" ? [0x202020,0xa31c38,0x176b3b,0x806000,0x215ca6,0x7241a3,0x126d72,0x202020,0x566575,0xb52542,0x25733e,0x8a6500,0x2766b3,0x854daf,0x20777b,0x404040] : [0x17212c, 0xef7c8e, 0x8ed6ae, 0xe8c987, 0x88b6ee, 0xbba1e4, 0x78d3ce, 0xc7d2df, 0x65758b, 0xff9caa, 0xa6edbf, 0xf5dfaa, 0xaccfff, 0xd6bfff, 0x9aeae3, 0xf0f4f9]
        if index < 16 { return NSColor(hex: palette[max(0, index)]) }
        if index >= 232 { let g = CGFloat(min(255, 8 + (index - 232) * 10)) / 255; return NSColor(white: g, alpha: 1) }
        let n = index - 16
        func channel(_ v: Int) -> CGFloat { CGFloat(v == 0 ? 0 : 55 + v * 40) / 255 }
        return NSColor(red: channel(n / 36), green: channel((n / 6) % 6), blue: channel(n % 6), alpha: 1)
    }
    override func draw(_ dirtyRect: NSRect) {
        terminalBackground.setFill(); bounds.fill()
        for (row, cells) in grid.visibleLines(historyOffset: historyOffset).enumerated() {
            for (col, cell) in cells.prefix(grid.cols).enumerated() {
                let point = NSPoint(x: 16 + CGFloat(col) * charWidth, y: 12 + CGFloat(row) * lineHeight)
                let foreground = cell.inverse ? (cell.background < 0 ? terminalBackground : color(cell.background)) : color(cell.color)
                if cell.inverse || cell.background >= 0 {
                    (cell.inverse ? color(cell.color) : color(cell.background)).setFill()
                    NSRect(x: point.x, y: point.y, width: charWidth, height: lineHeight).fill()
                }
                if !cell.text.isEmpty && cell.text != " " { (cell.text as NSString).draw(at: point, withAttributes: [.font: cell.bold ? boldFont : font, .foregroundColor: foreground]) }
            }
        }
        if (historyOffset == 0 || grid.savedScreen != nil) && grid.cursorVisible {
            NSColor(hex: 0x78d3b0).withAlphaComponent(window?.firstResponder === self ? 0.75 : 0.25).setFill()
            NSRect(x: 16 + CGFloat(grid.x) * charWidth, y: 12 + CGFloat(grid.y) * lineHeight + 16, width: charWidth, height: 2).fill()
        }
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); needsDisplay = true }
    override func scrollWheel(with event: NSEvent) {
        guard grid.savedScreen == nil else { return }
        historyOffset = min(grid.history.count, max(0, historyOffset + Int(event.scrollingDeltaY))); needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v" { paste(nil) }
            else if event.charactersIgnoringModifiers == "c" { copy(nil) }
            return
        }
        historyOffset = 0
        var text: String
        switch event.keyCode {
        case 123: text = grid.applicationCursorKeys ? "\u{1b}OD" : "\u{1b}[D"
        case 124: text = grid.applicationCursorKeys ? "\u{1b}OC" : "\u{1b}[C"
        case 125: text = grid.applicationCursorKeys ? "\u{1b}OB" : "\u{1b}[B"
        case 126: text = grid.applicationCursorKeys ? "\u{1b}OA" : "\u{1b}[A"
        case 115: text = "\u{1b}[H"
        case 119: text = "\u{1b}[F"
        case 117: text = "\u{1b}[3~"
        case 51: text = "\u{7f}"
        default:
            text = event.characters ?? ""
            if event.modifierFlags.contains(.control), let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first, scalar.value >= 64 && scalar.value <= 127 { text = String(UnicodeScalar(scalar.value & 31)!) }
            else if event.modifierFlags.contains(.option) { text = "\u{1b}" + text }
        }
        onMacroInput?(TerminalMacroEvent(kind:"raw",text:text)); session.send(Data(text.utf8)); needsDisplay = true
    }
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            historyOffset = 0; onMacroInput?(TerminalMacroEvent(kind:"text",text:text)); session.send(grid.pasteData(text)); needsDisplay = true
        }
    }
    @objc func copy(_ sender: Any?) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(grid.plainText, forType: .string) }
}

extension NSColor {
    convenience init(hex: UInt32) { self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
}
