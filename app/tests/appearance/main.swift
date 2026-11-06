import AppKit
L10n.configureSystemControls()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["HARBOR_APPEARANCE_OUTPUT"]!)
try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
var failures=0, assertions=0
func check(_ ok:Bool,_ name:String){ assertions+=1; print("\(ok ? "PASS":"FAIL"): \(name)");fflush(stdout);if !ok{failures+=1} }
func until(_ condition:()->Bool)->Bool {let end=Date().addingTimeInterval(6);while !condition() && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.02))};return condition()}
func pump(){RunLoop.current.run(until:Date().addingTimeInterval(0.15))}
func luminance(_ color:NSColor)->CGFloat {let rgb=color.usingColorSpace(.deviceRGB)!;return (rgb.redComponent+rgb.greenComponent+rgb.blueComponent)/3}
if CommandLine.arguments.contains("--persist") {
    check(InterfaceAppearance.preference == .dark,"appearance choice survives new process")
    TerminalPreferences.defaults.removePersistentDomain(forName:ProcessInfo.processInfo.environment["HARBOR_TEST_PREFERENCES_DOMAIN"]!)
    TerminalPreferences.defaults.synchronize();exit(failures == 0 ? 0:1)
}
check(InterfaceAppearance.preference == .system,"new profile follows system")
check(TerminalPreferences.theme == "Follow Appearance","new terminal theme follows interface")
InterfaceAppearance.apply()
check(app.appearance == nil,"system mode clears application override")
let controller=AppController()
controller.store=try! SessionStore(url:output.appendingPathComponent("sessions.json"))
controller.store.connections=[Connection(name:"Production 主机",host:"example.invalid",user:"tester")]
controller.makeMenu()
controller.window=NSWindow(contentRect:NSRect(x:100,y:100,width:1240,height:860),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
controller.window.isReleasedWhenClosed=false;controller.window.title="Harbor Appearance Checks"
controller.workspace=WorkspaceView(owner:controller);controller.window.contentView=controller.workspace
controller.window.makeKeyAndOrderFront(nil)
Timer.scheduledTimer(withTimeInterval:0.3,repeats:false){ _ in
    let tabs:[TerminalTab] = [TerminalBackend.ghostty,.legacy].map { backend in
        TerminalBackend.selected=backend
        return controller.launch(title:backend.rawValue,executable:"/bin/sh",arguments:["-c","stty -echo; printf 'READY:%s\\n' \"$$\"; while IFS= read -r line; do printf 'OUT:%s:%s\\n' \"$$\" \"$line\"; done"])!
    }
    for tab in tabs {check(until{tab.view.transcript()?.contains("READY:") == true},"\(tab.title) shell ready")}
    let identities=tabs.map{$0.view.transcript()!.components(separatedBy:"READY:").last!.components(separatedBy:.newlines).first!.trimmingCharacters(in:.whitespaces)}
    for choice in [InterfaceAppearance.light,.dark,.light] {
        let item=NSMenuItem();item.representedObject=choice.rawValue;controller.changeAppearance(item);pump()
        let light=choice == .light
        check(InterfaceAppearance.isDark == !light,"application resolves \(choice.rawValue)")
        check(controller.window.appearance == nil,"window inherits application appearance")
        check(TerminalPreferences.engineConfig.contains(light ? "background = f5f5f5":"background = 0b1118"),"terminal configuration follows \(choice.rawValue)")
        let bg=NSColor(cgColor:controller.workspace.layer!.backgroundColor!)!
        check(light ? luminance(bg)>0.8:luminance(bg)<0.2,"existing canvas layer refreshes \(choice.rawValue)")
        let editor=SerialEditor(owner:controller,existing:nil)
        check(editor.window!.appearance == nil,"new serial editor inherits appearance")
        check((editor.window!.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .aqua) == light,"serial editor resolves \(choice.rawValue)")
        for (index,tab) in tabs.enumerated() {
            _=tab.view.input("appearance-"+choice.rawValue,submit:true)
            check(until{tab.view.transcript()?.contains("OUT:"+identities[index]+":appearance-"+choice.rawValue) == true},"\(tab.title) keeps same shell and output after \(choice.rawValue)")
        }
        controller.selectTab(-1);controller.workspace.layoutSubtreeIfNeeded();controller.capture(output.appendingPathComponent(choice.rawValue+"-home.png").path)
        let view=editor.window!.contentView!;view.layoutSubtreeIfNeeded()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){view.cacheDisplay(in:view.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(choice.rawValue+"-serial.png"))}
        }
    }
    TerminalPreferences.theme="Harbor Dark"; InterfaceAppearance.preference = .light;InterfaceAppearance.apply();pump()
    check(TerminalPreferences.engineConfig.contains("background = 0b1118"),"explicit terminal theme survives light interface")
    TerminalPreferences.theme="Follow Appearance"
    InterfaceAppearance.preference = .system;InterfaceAppearance.apply();pump()
    check(app.appearance == nil && controller.window.appearance == nil,"follow-system removes overrides immediately")
    // Exercise the same effective-appearance propagation used by a system change without modifying macOS preferences.
    for name in [NSAppearance.Name.darkAqua,.aqua] {
        app.appearance=NSAppearance(named:name);pump()
        let bg=NSColor(cgColor:controller.workspace.layer!.backgroundColor!)!
        check(name == .aqua ? luminance(bg)>0.8:luminance(bg)<0.2,"inherited appearance change refreshes existing layer")
    }
    InterfaceAppearance.preference = .dark;InterfaceAppearance.apply();TerminalPreferences.defaults.synchronize()
    tabs.forEach{$0.stopTerminal()}
    print("RESULT assertions=\(assertions) failures=\(failures)");fflush(stdout);exit(failures == 0 ? 0:1)
}
app.run()
