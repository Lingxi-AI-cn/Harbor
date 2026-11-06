import AppKit
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let controller=AppController();app.delegate=controller
var assertions=0,failures=0
func check(_ value:Bool,_ name:String){assertions+=1;print("\(value ? "PASS":"FAIL"): \(name)");fflush(stdout);if !value{failures+=1}}
func rejects(_ name:String,_ block:()throws->Void){do{try block();check(false,name)}catch{check(true,name)}}
func until(_ seconds:Double=6,_ condition:()->Bool)->Bool{let end=Date().addingTimeInterval(seconds);while !condition() && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.02))};return condition()}
var preview:DesktopRun?
var reconnectChecked=false
var previewWindow:NSWindow?,previewSession:SSHFileSession?,previewRoot:URL?
Timer.scheduledTimer(withTimeInterval:0.2,repeats:false){ _ in
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("harbor-workflows-\(UUID().uuidString)")
 do {
    if controller.window == nil{controller.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))}
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let source=root.appendingPathComponent("source"),remote=root.appendingPathComponent("remote"),download=root.appendingPathComponent("download"),edit=root.appendingPathComponent("editor")
    for url in [source,remote,download,edit]{try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)}
    let tree=source.appendingPathComponent("tree"),nested=tree.appendingPathComponent("子目录")
    try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
    let payload=Data("text 中文\n".utf8);try payload.write(to:nested.appendingPathComponent("a 'quote'.txt"));try Data([0,255,10]).write(to:tree.appendingPathComponent("binary"));try payload.write(to:source.appendingPathComponent("second"))
    let proc=Process(),input=Pipe(),output=Pipe();proc.executableURL=URL(fileURLWithPath:"/usr/libexec/sftp-server");proc.arguments=["-d",remote.path];proc.standardInput=input;proc.standardOutput=output;proc.standardError=FileHandle.nullDevice;try proc.run()
    defer{try? input.fileHandleForWriting.close();if proc.isRunning{proc.terminate()};proc.waitUntilExit()}
    let client=try SFTPClient(input:output.fileHandleForReading,output:input.fileHandleForWriting)
    let plan=try RemoteTransferPlan.upload([tree,source.appendingPathComponent("second")],to:remote.path)
    check(plan.count==5,"multi-selection recursive upload plan")
    var count=0;try client.transfer(plan,uploading:true){i,_ in count=i}
    check(try count==5 && (Data(contentsOf:remote.appendingPathComponent("tree/子目录/a 'quote'.txt")))==payload,"real SFTP directory and Unicode filename upload")
    let down=try client.planDownload([remote.appendingPathComponent("tree").path,remote.appendingPathComponent("second").path],to:download)
    try client.transfer(down,uploading:false){_,_ in}
    check(try Data(contentsOf:download.appendingPathComponent("tree/binary"))==Data([0,255,10]),"binary recursive download")
    try client.transfer(down,uploading:false){_,_ in};check(true,"existing destination directories merge")
    let file=remote.appendingPathComponent("second");let replacement=Data("edited 中文".utf8)
    try client.saveText(file.path,expected:payload,replacement:replacement,workspace:edit)
    check(try Data(contentsOf:file)==replacement,"remote text save commits exact UTF-8")
    rejects("remote edit detects concurrent modification"){try client.saveText(file.path,expected:payload,replacement:Data("wrong".utf8),workspace:edit)}
    check(try Data(contentsOf:file)==replacement,"conflicting edit preserves server bytes")
    rejects("editor download enforces byte limit"){try client.download(file.path,to:edit.appendingPathComponent("limit"),maxBytes:2)}
    try FileManager.default.createSymbolicLink(atPath:tree.appendingPathComponent("link").path,withDestinationPath:source.path)
    rejects("upload preflight rejects symlink cycles"){_=try RemoteTransferPlan.upload([tree],to:remote.path)}
    try FileManager.default.createSymbolicLink(atPath:remote.appendingPathComponent("tree/link").path,withDestinationPath:remote.path)
    rejects("download preflight rejects remote symlinks"){_=try client.planDownload([remote.appendingPathComponent("tree").path],to:download)}
    rejects("remote name traversal rejected"){try RemoteTransferPlan.safeName("../escape")}
    let renamed=try client.planDownload([file.path],to:download,names:["renamed"]);try client.transfer(renamed,uploading:false){_,_ in}
    check(try Data(contentsOf:download.appendingPathComponent("renamed"))==replacement,"Finder promised destination name respected")
    let session=try SSHFileSession(connection:Connection(name:"fixture",host:"fixture",user:""),testTransport:{let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/libexec/sftp-server");p.arguments=["-d",remote.path];return p})
    let browser=RemoteFileBrowser(session:session);check(until{!browser.busy},"browser loads real SFTP listing")
    check(browser.table.allowsMultipleSelection,"browser permits multiple selection")
    browser.follow.state = .on;browser.receiveDirectory(remote.appendingPathComponent("tree").path)
    check(until{browser.directory.hasSuffix("/tree")},"OSC 7 path notification follows remote directory")
    browser.follow.state = .off;browser.receiveDirectory(remote.path);check(browser.directory.hasSuffix("/tree"),"manual browse mode ignores directory following")
    let replyCount=NSMutableArray();let reply=FilePromiseReply{_ in replyCount.add(1)};reply.finish(nil);reply.finish(nil);check(replyCount.count==1,"file promise completes once")
    let promiseFolder=download.appendingPathComponent("promises");try FileManager.default.createDirectory(at:promiseFolder,withIntermediateDirectories:false)
    var promisesDone=0,promisesFailed=0
    for name in ["one","two"] {let provider=NSFilePromiseProvider(fileType:"public.data",delegate:browser);provider.userInfo=file.path;browser.filePromiseProvider(provider,writePromiseTo:promiseFolder.appendingPathComponent(name)){error in promisesDone+=1;if error != nil{promisesFailed+=1}}}
    check(until(10){promisesDone==2} && promisesFailed==0,"queued file promises finish both downloads")
    check(try Data(contentsOf:promiseFolder.appendingPathComponent("two"))==replacement,"file promise callback writes exact bytes")
    if ProcessInfo.processInfo.environment["HARBOR_UI_PREVIEW"] == "1" {
        previewRoot=root;previewSession=session
        let w=NSWindow(contentRect:NSRect(x:50,y:100,width:280,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);w.title="SFTP workflow fixture";w.appearance=NSAppearance(named:.darkAqua);w.contentView=browser;w.isReleasedWhenClosed=false;w.makeKeyAndOrderFront(nil);previewWindow=w
        let ed=try RemoteTextEditor(session:session,remote:file.path,folder:edit,data:replacement);ed.showWindow(nil)
    } else {browser.disconnected();session.stop()}
    let canonical=realpath(source.path,nil)!;let sourcePath=String(cString:canonical);free(canonical)
    for shell in ["/bin/bash","/bin/zsh"] {let p=Process(),out=Pipe();p.executableURL=URL(fileURLWithPath:shell);p.arguments=["-c",RemoteShellReporting.command];p.currentDirectoryURL=source;p.standardOutput=out;p.standardError=FileHandle.nullDevice;try p.run();let data=out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();check(p.terminationStatus==0 && String(decoding:data,as:UTF8.self).contains("file://localhost"+sourcePath),"shell reporting hook emits OSC 7 · \(shell)")}
    let port=Int(ProcessInfo.processInfo.environment["HARBOR_EMBEDDED_PORT"]!)!
    var connection=Connection(name:"Desktop workflow fixture",host:"127.0.0.1",user:"",port:port,kind:"VNC");connection.desktop=DesktopSettings(embedded:true)
    let run=try DesktopRun(connection,owner:controller);controller.desktopRuns.append(run);preview=run
    let v=EmbeddedDesktop(run:run);run.viewer=v;try v.start(password:"");run.active=true
    check(until{v.surface.image != nil},"desktop framebuffer connects")
    check(controller.selectedDesktop === run && v.surface.window === controller.window,"desktop is hosted by main workspace tab")
    check(controller.workspace.tabItems.count == controller.paneGroups.count+1,"desktop shares session tab strip")
    v.secureAttention();v.remoteAltTab()
    if !controller.tabs.isEmpty {controller.selectTab(0);check(controller.selectedDesktop == nil,"switch from desktop to terminal");controller.selectDesktop(run);check(controller.selectedDesktop === run,"switch back to desktop tab")}
    print("PREVIEW_READY");fflush(stdout)
    if ProcessInfo.processInfo.environment["HARBOR_UI_PREVIEW"] != "1" {run.stop();check(until{!v.process.isRunning},"closing desktop tab stops helper");check(run.closed && controller.selectedDesktop !== run,"desktop tab removed");finish()}
 }catch{check(false,error.localizedDescription);finish()}
 if ProcessInfo.processInfo.environment["HARBOR_UI_PREVIEW"] != "1" {try? FileManager.default.removeItem(at:root)}
}
func finish(){previewSession?.stop();if let root=previewRoot{try? FileManager.default.removeItem(at:root)};controller.tabs.forEach{$0.stopTerminal()};print("RESULT assertions=\(assertions) failures=\(failures)");fflush(stdout);exit(failures==0 ? 0:1)}
Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){_ in
    guard ProcessInfo.processInfo.environment["HARBOR_UI_PREVIEW"] == "1",let preview else{return}
    if let replacement=controller.desktopRuns.first(where:{$0 !== preview && !$0.closed}),replacement.viewer?.surface.image != nil,!reconnectChecked {
        reconnectChecked=true;check(preview.closed && preview.viewer?.process.isRunning==false,"reconnect cleans previous viewer");check(controller.selectedDesktop === replacement,"reconnect renders in a new workspace tab")
    }
    if preview.closed && controller.desktopRuns.allSatisfy({$0.closed}) {check(until{preview.viewer?.process.isRunning==false},"UI tab close stops helper");finish()}
}
app.run()
