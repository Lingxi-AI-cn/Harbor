import AppKit
L10n.configureSystemControls()
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let controller = AppController()
let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["HARBOR_I18N_OUTPUT"]!)
try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
var failures=0
func check(_ ok:Bool,_ name:String){print("\(ok ? "PASS":"FAIL"): \(name)");fflush(stdout);if !ok{failures+=1}}
func until(_ condition:()->Bool)->Bool {let end=Date().addingTimeInterval(8);while !condition() && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.02))};return condition()}
let chinese=L10n.activeLanguage == .simplifiedChinese
controller.store=try! SessionStore(url:root.appendingPathComponent("sessions.json"))
controller.store.connections=[Connection(name:"Connect",host:"example.invalid",user:"tester")]
controller.makeMenu()
controller.window=NSWindow(contentRect:NSRect(x:100,y:100,width:1240,height:860),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
controller.window.isReleasedWhenClosed=false;controller.window.title=L("Harbor — Remote workspace");controller.window.appearance=NSAppearance(named:.darkAqua)
controller.workspace=WorkspaceView(owner:controller);controller.window.contentView=controller.workspace
controller.window.makeKeyAndOrderFront(nil)
Timer.scheduledTimer(withTimeInterval:0.4,repeats:false){_ in
 let home=controller.workspace.welcome
 check(home.activityTitle.stringValue == (chinese ? "你的会话":"Your sessions"),"home uses selected language")
 check(home.sessionTags.first?.title == "Connect","user session name is never translated")
 check(home.sessionTags.first?.toolTip?.contains(chinese ? "主机：example.invalid":"Host: example.invalid") == true,"session tooltip labels translated; host preserved")
 let menu=NSApp.mainMenu!.items
 check(menu.contains{$0.title == (chinese ? "会话":"Session")},"menu titles localized")
 let languages=menu[0].submenu!.items.first{$0.submenu?.items.contains{$0.identifier?.rawValue == "language.system"} == true}!.submenu!.items
 check(languages.count==3 && languages.contains{$0.representedObject as? String == "system"},"language chooser has System, English and Chinese")
 check(languages.first{$0.representedObject as? String == L10n.preference.rawValue}?.state == .on,"selected preference checkmark")
 check(languages.allSatisfy{$0.action == #selector(AppController.changeLanguage(_:))},"all language choices use the persistence action")
 var c=Connection(name:"Device",host:"/dev/cu.test",user:"",kind:"Serial");c.serial=SerialSettings(device:c.host,parity:"Even",flow:"RTS/CTS")
 let serial=SerialEditor(owner:controller,existing:c)
 check(serial.parity.rawSelectedValue=="Even" && serial.parity.titleOfSelectedItem == (chinese ? "偶校验":"Even"),"serial display is separate from stored parity")
 check(serial.flow.rawSelectedValue=="RTS/CTS" && serial.ending.rawSelectedValue=="CR","flow and line endings retain protocol values")
 let theme=NSPopUpButton();theme.addLocalizedItems(withValues:["Harbor Dark","Light","High Contrast"]);theme.selectRawValue("Light")
 check(theme.rawSelectedValue=="Light" && theme.titleOfSelectedItem == (chinese ? "浅色":"Light"),"theme display preserves engine configuration value")
 let config=TerminalPreferences.engineConfig
 check(config.contains("font-family =") && config.contains("cursor-style =") && !config.contains("光标"),"engine configuration keys stay untranslated")
 var bad=Connection(name:"",host:"",user:"");bad.kind="SSH"
 do {try bad.validate();check(false,"invalid connection rejected")}catch{check(error.localizedDescription==(chinese ? "请输入主机名或 IP 地址，不要包含空格或 URL 前缀。":"Enter a hostname or IP address, without spaces or a URL prefix."),"validation message localized")}
 let original=Connection(name:"Connect",host:"example.invalid",user:"tester",port:2222)
 check(original.command().1.last=="tester@example.invalid" && original.command().1.contains("2222"),"SSH destination and port unaffected")
 let rdp=Connection(name:"RDP",host:"example.invalid",user:"tester",kind:"RDP")
 check((try? DesktopConfiguration.rdp(rdp))?.contains("full address:s:example.invalid:22") == true,"RDP file fields stay protocol-compatible")
 let input="Connect {1} 100% 中文"
 let tab=controller.launch(title:"Literal input",executable:"/bin/sh",arguments:["-c","stty -echo; printf 'READY\\n'; while IFS= read -r line; do printf 'OUT:%s\\n' \"$line\"; done"])!
 check(until{tab.view.transcript()?.contains("READY") == true},"real local terminal ready")
 _=tab.view.input(input,submit:true)
 check(until{tab.view.transcript()?.contains("OUT:"+input) == true},"terminal input and output are never translated")
 tab.stopTerminal();tab.running=false;controller.closePane(tab);controller.selectTab(-1)
 controller.workspace.layoutSubtreeIfNeeded();controller.capture(root.appendingPathComponent("home.png").path)
 let screen=serial.window!.contentView!;screen.layoutSubtreeIfNeeded()
 if let bitmap=screen.bitmapImageRepForCachingDisplay(in:screen.bounds){screen.cacheDisplay(in:screen.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("serial.png"))}
 print("RESULT language=\(L10n.activeLanguage.rawValue) failures=\(failures)");fflush(stdout)
 if ProcessInfo.processInfo.environment["HARBOR_I18N_REVIEW"] == "1" { app.delegate=controller;controller.window.delegate=controller;return }
 exit(failures == 0 ? 0:1)
}
app.run()
