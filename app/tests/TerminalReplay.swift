import AppKit

// Replays recorded PTY chunks, including explicit resize boundaries, through the
// production parser. Used by tmux_regression.py with an isolated local server.
@main
struct TerminalReplay {
    static func main() throws {
        let events = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        let grid = TerminalGrid()
        for event in events {
            if let rows = event["rows"] as? Int, let cols = event["cols"] as? Int { grid.resize(rows: rows, cols: cols) }
            if let encoded = event["data"] as? String { grid.feed(Data(base64Encoded: encoded)!) }
        }
        let lines = grid.cells.map { $0.map(\.text).joined() }
        let data = try JSONSerialization.data(withJSONObject: lines)
        FileHandle.standardOutput.write(data)
        if CommandLine.arguments.count > 2 {
            _ = NSApplication.shared
            let view = TerminalView(frame: NSRect(x: 0, y: 0, width: CGFloat(grid.cols) * 8 + 32, height: CGFloat(grid.rows) * 19 + 24))
            for event in events {
                if let rows = event["rows"] as? Int, let cols = event["cols"] as? Int { view.grid.resize(rows: rows, cols: cols) }
                if let encoded = event["data"] as? String { view.grid.feed(Data(base64Encoded: encoded)!) }
            }
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
