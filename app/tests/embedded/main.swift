import AppKit
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let controller=AppController();app.delegate=controller
var assertions=0,failures=0
func check(_ value:Bool,_ name:String){assertions+=1;print("\(value ? "PASS":"FAIL"): \(name)");fflush(stdout);if !value{failures+=1}}
func until(_ seconds:Double=5,_ condition:()->Bool)->Bool{let end=Date().addingTimeInterval(seconds);while !condition() && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.02))};return condition()}
var run:DesktopRun?, viewer:EmbeddedDesktop?
Timer.scheduledTimer(withTimeInterval:0.2,repeats:false){ _ in
    do {
        if controller.window == nil {controller.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))}
        let port=Int(ProcessInfo.processInfo.environment["HARBOR_EMBEDDED_PORT"]!)!
        var c=Connection(name:"Embedded VNC fixture",host:"127.0.0.1",user:"",port:port,kind:"VNC");c.desktop=DesktopSettings(embedded:true)
        let r=try DesktopRun(c,owner:controller);run=r;controller.desktopRuns.append(r)
        let v=EmbeddedDesktop(run:r);viewer=v;r.viewer=v
        try v.start(password:"")
        check(until(8){v.surface.image != nil},"real helper framebuffer reaches native view")
        check(v.surface.image?.width == 800 && v.surface.image?.height == 600,"native framebuffer dimensions")
        check(r.state.contains("Connected"),"connected state follows protocol handshake")
        check(v.window?.firstResponder === v.surface,"viewer receives keyboard focus")
        let rect=v.surface.imageRect
        check(abs(rect.width/rect.height-4.0/3.0)<0.001,"letterboxing preserves aspect ratio")
        let bytes=v.surface.image?.dataProvider?.data as Data?
        check(bytes?[4*8010] == 230 && bytes?[4*8010+3] == 255,"frame colors and opacity reach CoreGraphics")
        v.surface.key(0xff0d,down:true);v.surface.key(0xff0d,down:false)
        check(until{let url=URL(fileURLWithPath:"checks/embedded-ui-events.json");guard let data=try? Data(contentsOf:url),let a=try? JSONSerialization.jsonObject(with:data) as? [[String:Any]] else{return false};return a.filter{$0["key"] as? Int == 0xff0d}.count>=2},"native input reaches actual RFB server")
        let encoded=try JSONEncoder().encode(c);let decoded=try JSONDecoder().decode(Connection.self,from:encoded)
        check(decoded.desktop?.embedded == true,"embedded mode survives session coding")
        print("PREVIEW_READY");fflush(stdout)
        if ProcessInfo.processInfo.environment["HARBOR_UI_PREVIEW"] != "1" {finish()}
    } catch {check(false,error.localizedDescription);finish()}
}
func finish(){
    run?.stop();check(until{viewer?.process.isRunning == false},"closing viewer terminates helper")
    check(run?.active == false,"closing viewer marks desktop inactive")
    if let dir=run?.directory {check(!FileManager.default.fileExists(atPath:dir.path),"temporary desktop directory removed")}
    controller.tabs.forEach{$0.stopTerminal()};print("RESULT assertions=\(assertions) failures=\(failures)");fflush(stdout);exit(failures == 0 ? 0:1)
}
// Preview closes through the production window delegate; a timer then verifies cleanup.
Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){_ in if ProcessInfo.processInfo.environment["HARBOR_UI_PREVIEW"] == "1",let run,!run.active {finish()}}
app.run()
