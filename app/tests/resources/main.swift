import AppKit
final class ResourceCheck: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let terminal = GhosttyTerminalView(frame:NSRect(x:0,y:0,width:1000,height:300))
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect:terminal.bounds,styleMask:.titled,backing:.buffered,defer:false)
        window.contentView = terminal
        do { try terminal.start(executable:"/bin/sh",arguments:["-c","printf '%s\\n%s\\n' \"$GHOSTTY_RESOURCES_DIR\" \"$TERMINFO\"; sleep 10"]) }
        catch { print("FAIL: \(error)"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            let expected = Bundle.main.bundlePath+"/Contents/Resources"
            let text = GhosttyTerminalView.clipboardText(self.terminal.readText() ?? "")
            let pass = text.contains(expected+"/ghostty") && text.contains(expected+"/terminfo")
            print("\(pass ? "PASS" : "FAIL"): relocated engine discovers bundled resources without environment override")
            let record: [String:Any] = ["passed":pass,"bundle":Bundle.main.bundlePath,"child_resource_paths":text,"scope":"same host engine/view code in a test executable inside a copied actual resource bundle"]
            if let data = try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
            self.terminal.stop(); exit(pass ? 0 : 1)
        }
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let delegate = ResourceCheck(); app.delegate = delegate; app.run()
