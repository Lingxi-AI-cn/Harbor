import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController(); app.delegate = controller
var failures = 0
func check(_ ok: Bool,_ name: String) { print("\(ok ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !ok { failures += 1 } }
let a = UUID(), b = UUID(), c = UUID()
let saved = WorkspaceSnapshot(groups:[
    .init(layout:.split(.right,0.3,.leaf(a),.split(.down,0.65,.leaf(b),.leaf(c))),focused:c,panes:[.init(id:a,session:.local("/tmp")),.init(id:b,session:.local("/Users")),.init(id:c,session:.local("/private"))])],selected:c)
DispatchQueue.main.asyncAfter(deadline:.now()+1) {
    controller.newLocal()
    let original = controller.tabs.first!
    do { try controller.restoreWorkspaceSnapshot(saved) } catch { check(false,error.localizedDescription) }
    DispatchQueue.main.asyncAfter(deadline:.now()+3) {
        check(controller.tabs.count == 4 && controller.paneGroups.count == 2 && controller.tabs.first === original,"restore appends new workspace without replacing existing session")
        let restored = Array(controller.tabs.dropFirst())
        print("DIRECTORIES",restored.map { $0.reportedWorkingDirectory ?? "nil" })
        check(restored.map { $0.reportedWorkingDirectory } == ["/tmp","/Users","/private"],"restored real shells report their saved directories")
        check(controller.tabs[controller.selected] === restored.last,"saved active pane is selected after asynchronous shell startup")
        let responder = controller.window.firstResponder as? NSView
        check(responder.map { $0 === restored.last!.view || $0.isDescendant(of:restored.last!.view) } == true,"keyboard responder belongs to saved active pane")
        check(controller.activeGroup?.layout.focusedID == restored.last?.id,"layout focus and selected pane agree")
        let frames = restored.compactMap { controller.activeGroup?.layout.paneFrame($0.id) }
        check(frames.count == 3 && frames[1].minY > frames[2].maxY,"real restored surfaces occupy nested split orientation")
        check(controller.tabs.allSatisfy { $0.running },"all restored terminal processes remain running")
        controller.tabs.forEach { $0.stopTerminal() }
        print("RESULT failures=\(failures)"); fflush(stdout); exit(failures == 0 ? 0 : 1)
    }
}
app.run()
