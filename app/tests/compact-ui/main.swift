import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController(); app.delegate = controller
let previous = TerminalPreferences.defaults.object(forKey:"sidebarHidden")
var failures = 0
func check(_ ok: Bool,_ name: String) { print("\(ok ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !ok { failures += 1 } }
DispatchQueue.main.asyncAfter(deadline:.now()+1) {
    let w = controller.workspace!
    controller.newLocal(); controller.newLocal()
    let active = controller.tabs.last!
    w.layoutSubtreeIfNeeded()
    check(w.top.frame.height == 48 && w.body.frame.minY == 48,"one toolbar row gives remaining height to content")
    let width = w.body.frame.width, hidden = w.sidebarHidden
    w.toggleSidebar()
    check(w.sidebar.isHidden != hidden && abs(w.body.frame.width-width) == 220 && controller.tabs.count == 2,"sidebar toggle reclaims width without changing sessions")
    w.toggleSidebar()
    check(w.body.frame.width == width,"sidebar restores original layout")
    w.toggleFiles(); w.layoutSubtreeIfNeeded()
    check(w.fileBrowser != nil && w.terminal?.frame.minX == 270,"file list reserves width")
    w.fileCollapseButton.performClick(nil); w.layoutSubtreeIfNeeded()
    check(w.fileBrowser == nil && w.terminal?.frame.minX == 0,"file header collapse returns width to terminal")
    w.filesButton.performClick(nil); w.layoutSubtreeIfNeeded()
    check(w.fileBrowser != nil,"toolbar restores file list")
    w.toggleFiles()
    // End the inactive shell to exercise close-icon routing without an alert.
    let inactive = controller.tabs.first!
    inactive.view.stop(); inactive.running = false
    w.tabItems.first!.closeButton.performClick(nil)
    check(controller.tabs.count == 1 && controller.tabs.first === active && controller.activeGroup?.active === active,"inactive tab close targets its own session and preserves selection")
    for _ in 0..<8 { controller.newLocal() }
    w.layoutSubtreeIfNeeded()
    check(w.tabBar.frame.width > w.tabScroll.contentSize.width && w.tabScroll.contentView.bounds.maxX >= w.tabItems.last!.frame.maxX,"overflow tabs scroll to newly selected session")
    let group = controller.paneGroups.last!
    let pane = group.active!
    let extra = TerminalTab(title:"ended test pane"); extra.running = false
    group.panes.append(extra); controller.tabs.append(extra)
    pane.view.stop(); pane.running = false
    let count = controller.tabs.count
    controller.closeGroup(group)
    check(controller.tabs.count == count-2 && !controller.paneGroups.contains(where:{$0 === group}),"closing a split tab removes every pane and its group")
    for tab in controller.tabs { tab.running = false; controller.closePane(tab) }
    controller.newLocal()
    let survivor = controller.tabs.first!
    let ended = controller.launch(title:"exit regression",executable:"/bin/sh",arguments:["-c","exit 0"],splitGroup:controller.activeGroup)!
    DispatchQueue.main.asyncAfter(deadline:.now()+2) {
        check(!ended.running && controller.tabs.count == 2,"exited split pane remains visible until a key is pressed")
        let ghost = ended.view.subviews.compactMap { $0 as? GhosttyTerminalView }.first!
        let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:controller.window.windowNumber,context:nil,characters:"a",charactersIgnoringModifiers:"a",isARepeat:false,keyCode:0)!
        ghost.keyDown(with:key)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
            check(controller.tabs.count == 1 && controller.tabs.first === survivor && survivor.running,"real Ghostty close callback removes only the exited split pane")
            let single = controller.launch(title:"exit single regression",executable:"/bin/sh",arguments:["-c","exit 0"])!
            DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                let singleGhost = single.view.subviews.compactMap { $0 as? GhosttyTerminalView }.first!
                singleGhost.keyDown(with:key)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    check(controller.tabs.count == 1 && controller.paneGroups.count == 1 && controller.tabs.first === survivor,"keypress removes an exited session tab and selects surviving session")
                    controller.tabs.forEach { $0.stopTerminal() }
                    if let previous { TerminalPreferences.defaults.set(previous,forKey:"sidebarHidden") } else { TerminalPreferences.defaults.removeObject(forKey:"sidebarHidden") }
                    print("RESULT failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1)
                }
            }
        }
    }
}
app.run()
