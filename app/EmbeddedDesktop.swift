import AppKit
import Darwin

private extension Data {
    mutating func u32(_ value: UInt32) { var v=value.bigEndian; Swift.withUnsafeBytes(of:&v) { append(contentsOf:$0) } }
    mutating func u16(_ value: UInt16) { var v=value.bigEndian; Swift.withUnsafeBytes(of:&v) { append(contentsOf:$0) } }
    func number(_ offset: Int) -> UInt32 { self[offset..<offset+4].reduce(0) { ($0<<8)|UInt32($1) } }
}

final class EmbeddedDesktop: NSWindowController, NSWindowDelegate {
    weak var run: DesktopRun?
    let surface=DesktopSurface(frame:.zero), status=NSTextField(labelWithString:L("Preparing…"))
    let process=Process(), input=Pipe(), output=Pipe()
    private var stopped=false, started=false
    let content=NSView(frame:NSRect(x:0,y:0,width:1024,height:700))
    var remoteClipboard:String?,copyRequested=false
    var inWorkspace=false
    private var focusObserver:NSObjectProtocol?
    private let sendQueue=DispatchQueue(label:"harbor.desktop.input")
    private let frameLock=NSLock()
    private var latestFrame: Data?, frameScheduled=false
    static var helper: URL {
        let bundled=Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/harbor-desktop-engine")
        if FileManager.default.isExecutableFile(atPath:bundled.path) { return bundled }
        return URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("vendor/desktop-engine/harbor-desktop-engine")
    }
    init(run: DesktopRun) {
        self.run=run
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1024,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title="\(run.connection.kind) · \(run.connection.name)"; w.isReleasedWhenClosed=false; w.minSize=NSSize(width:480,height:320); w.center()
        super.init(window:w); w.delegate=self
        let root=content; root.autoresizingMask=[.width,.height]; w.contentView=root
        surface.frame=NSRect(x:0,y:70,width:root.bounds.width,height:root.bounds.height-70); surface.autoresizingMask=[.width,.height]; surface.client=self; surface.kind=run.connection.kind
        status.frame=NSRect(x:12,y:44,width:root.bounds.width-24,height:20);status.autoresizingMask=[.width];status.font = .systemFont(ofSize:11)
        root.addSubview(surface);root.addSubview(status)
        let controls:[(String,Selector)]=[(L("Send clipboard"),#selector(sendClipboard)),(L("Copy remote text"),#selector(copyClipboard)),("Ctrl+Alt+Del",#selector(secureAttention)),("Alt+Tab",#selector(remoteAltTab)),(L("Reconnect"),#selector(reconnect))]
        let row=NSStackView(views:controls.map{NSButton(title:$0.0,target:self,action:$0.1)});row.orientation = .horizontal;row.distribution = .fillEqually;row.spacing=6;row.frame=NSRect(x:8,y:6,width:root.bounds.width-16,height:28);row.autoresizingMask=[.width];root.addSubview(row)
        focusObserver=NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:nil,queue:.main){[weak self] n in guard let self,let w=n.object as? NSWindow,w === self.surface.window else{return};self.surface.releaseKeys()}

    }
    required init?(coder:NSCoder) { fatalError() }
    func start(password: String) throws {
        guard let run else { return }
        let c=run.connection,d=c.desktop ?? DesktopSettings(),endpoint=DesktopConfiguration.endpoint(c)
        process.environment=ProcessInfo.processInfo.environment.merging(["XDG_CONFIG_HOME":run.directory.path]) { _,new in new }
        process.executableURL=Self.helper;process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        process.terminationHandler={ [weak self] p in DispatchQueue.main.async { guard let self else { return };self.run?.cleanup();guard !self.stopped else { return };self.finish(p.terminationStatus == 0 ? L("Disconnected") : L("Connection ended · check credentials, server and certificate")) } }
        try process.run();started=true
        var data=Data();data.u32(UInt32(endpoint.1));data.u32(UInt32(d.width));data.u32(UInt32(d.height))
        for value in [c.kind,endpoint.0,c.user,password,d.domain] { let bytes=Data(value.utf8);data.u32(UInt32(bytes.count));data.append(bytes) }
        send("I",data);data.resetBytes(in:0..<data.count)
        if let owner=run.owner,owner.window != nil {inWorkspace=true;window?.contentView=nil;owner.selectDesktop(run)}
        else {showWindow(nil);window?.makeKeyAndOrderFront(nil);window?.makeFirstResponder(surface)}
        if d.fullscreen {surface.window?.toggleFullScreen(nil)}
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in self?.readLoop() }
    }
    func send(_ type: Character,_ payload: Data=Data()) {
        guard !stopped else { return };var data=Data([type.asciiValue!]);data.u32(UInt32(payload.count));data.append(payload)
        let handle=input.fileHandleForWriting
        sendQueue.async { try? handle.write(contentsOf:data) }
    }
    private func readExact(_ size:Int) -> Data? {
        var result=Data();while result.count<size { guard let next=try? output.fileHandleForReading.read(upToCount:size-result.count),!next.isEmpty else { return nil };result.append(next) };return result
    }
    private func readLoop() {
        while let h=readExact(5) {
            let n=Int(h.number(1));guard n<=64*1024*1024+8,let data=readExact(n) else { break }
            if h[0]==70 { // F: bounded RGBA frame, latest frame wins while main queue is busy.
                guard n>=8 else { break };let w=Int(data.number(0)),height=Int(data.number(4))
                guard w>0,height>0,w<=8192,height<=8192,w*height*4==n-8 else { break }
                frameLock.lock();latestFrame=data;let schedule = !frameScheduled;frameScheduled=true;frameLock.unlock()
                if schedule { DispatchQueue.main.async { [weak self] in self?.presentFrame() } }
            } else {
                let type=h[0],text=String(decoding:data,as:UTF8.self)
                DispatchQueue.main.async { [weak self] in
                    guard let self,!self.stopped else { return }
                    if type==76 {
                        self.remoteClipboard=self.run?.connection.kind == "VNC" ? String(data:data,encoding:.isoLatin1):text
                        if self.copyRequested {self.copyRequested=false;self.writeRemoteClipboard()}
                    }
                    else if type==78 {self.status.stringValue=L10n.desktopMessage(text);self.copyRequested=false}
                    else if type==65 {self.status.stringValue=L("Connected · clipboard ready")}
                    else if type==67 { self.certificate(text) }
                    else if type==69 { self.finish(L("Failed · \(L10n.desktopMessage(text))")) }
                    else if type==83 { self.status.stringValue=L10n.desktopMessage(text);self.run?.state=L10n.desktopMessage(text) }
                    else if type==66 { NSSound.beep() }
                }
            }
        }
    }
    private func presentFrame() {
        frameLock.lock();let data=latestFrame;latestFrame=nil;frameScheduled=false;frameLock.unlock()
        guard !stopped,let data else { return };surface.setFrame(data)
    }
    private func certificate(_ text:String) {
        guard !stopped else { return }
        let alert=NSAlert();alert.messageText=L("Verify remote desktop certificate");alert.informativeText=L("The certificate could not be verified automatically. Compare the fingerprint with the server administrator before accepting. Trust applies only to this connection.\n\n")+text
        alert.addButton(withTitle:L("Reject"));alert.addButton(withTitle:L("Trust this connection"))
        let accepted=alert.runModal() == .alertSecondButtonReturn
        if !stopped { send("T",Data([accepted ? 1:0])) }
    }
    private func finish(_ message:String) { guard !stopped else { return };status.stringValue=message;run?.state=message;run?.active=false;run?.tunnel?.stop();run?.cleanup();stop(closeWindow:false) }
    func stop(closeWindow: Bool=true) {
        guard !stopped else { if closeWindow, inWorkspace,let run {run.owner?.removeDesktop(run)};return };stopped=true
        surface.releaseKeys()
        if started && process.isRunning { process.terminate();let p=process;DispatchQueue.global().asyncAfter(deadline:.now()+2) { if p.isRunning { kill(p.processIdentifier,SIGKILL) } } }
        try? input.fileHandleForWriting.close();if closeWindow { if inWorkspace,let run {run.owner?.removeDesktop(run)};close() }
    }
    func windowWillClose(_ n:Notification) { run?.stop() }
    func windowDidResignKey(_ n:Notification) { surface.releaseKeys() }
    @objc func sendClipboard() {
        guard !stopped,let text=NSPasteboard.general.string(forType:.string) else{return}
        let data=run?.connection.kind == "VNC" ? text.data(using:.isoLatin1):text.data(using:.utf8)
        guard let data,data.count<=65536 else{status.stringValue=L("Clipboard limit: 64 KiB; classic VNC supports Latin-1 text.");return};send("L",data)
    }
    @objc func copyClipboard(){guard !stopped else{return};if run?.connection.kind == "RDP" {copyRequested=true;send("G")}else{writeRemoteClipboard()}}
    func writeRemoteClipboard(){guard let text=remoteClipboard else{status.stringValue=L("No text received from remote clipboard yet.");return};NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string);status.stringValue=L("Copied remote text")}
    func chord(_ codes:[UInt32]){guard !stopped else{return};surface.releaseKeys();for code in codes{surface.key(code,down:true)};for code in codes.reversed(){surface.key(code,down:false)}}
    @objc func secureAttention(){chord(run?.connection.kind == "VNC" ? [0xffe3,0xffe9,0xffff]:[0x1d,0x38,0x153])}
    @objc func remoteAltTab(){chord(run?.connection.kind == "VNC" ? [0xffe9,0xff09]:[0x38,0x0f])}
    @objc func reconnect(){guard let run,let owner=run.owner else{return};if run.active {let a=NSAlert();a.messageText=L("Disconnect and reconnect this desktop?");a.addButton(withTitle:L("Reconnect"));a.addButton(withTitle:L("Cancel"));guard a.runModal() == .alertFirstButtonReturn else{return}};let c=run.connection;run.stop();do{try owner.connectDesktop(c)}catch{owner.showError(error)}}
    deinit { if let focusObserver {NotificationCenter.default.removeObserver(focusObserver)};if process.isRunning { process.terminate() } }
}

final class DesktopSurface: NSView {
    weak var client: EmbeddedDesktop?
    var kind="RDP", image:CGImage?, tracking:NSTrackingArea?, buttons:UInt8=0
    private var held:[UInt16:UInt32]=[:], modifiers:NSEvent.ModifierFlags=[]
    override var acceptsFirstResponder:Bool { true }
    override var isFlipped:Bool { true }
    override func updateTrackingAreas() { super.updateTrackingAreas();if let tracking { removeTrackingArea(tracking) };let area=NSTrackingArea(rect:bounds,options:[.activeInKeyWindow,.mouseMoved,.inVisibleRect],owner:self);addTrackingArea(area);tracking=area }
    func setFrame(_ data:Data) {
        let w=Int(data.number(0)),h=Int(data.number(4)),bytes=data.subdata(in:8..<data.count)
        guard let provider=CGDataProvider(data:bytes as CFData) else { return }
        image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent);needsDisplay=true
    }
    var imageRect:NSRect { guard let image else { return bounds };let scale=min(bounds.width/CGFloat(image.width),bounds.height/CGFloat(image.height));let size=NSSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale);return NSRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height) }
    override func draw(_ dirtyRect:NSRect) { NSColor.black.setFill();bounds.fill();guard let image else { return };NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)).draw(in:imageRect,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.none]) }
    func key(_ key:UInt32,down:Bool,unicode:Bool=false) { var data=Data([down ? 1:0]);data.u32(key);client?.send(kind == "VNC" ? "V" : unicode ? "U":"K",data) }
    // macOS hardware key codes -> PC set-1 scan codes (extended flag is FreeRDP 0x100).
    static let scan:[UInt16:UInt32]=[0:0x1e,1:0x1f,2:0x20,3:0x21,4:0x23,5:0x22,6:0x2c,7:0x2d,8:0x2e,9:0x2f,11:0x30,12:0x10,13:0x11,14:0x12,15:0x13,16:0x15,17:0x14,18:2,19:3,20:4,21:5,22:7,23:6,24:13,25:10,26:8,27:12,28:9,29:11,30:27,31:24,32:22,33:26,34:23,35:25,36:28,37:38,38:36,39:40,40:37,41:39,42:43,43:51,44:53,45:49,46:50,47:52,48:15,49:57,50:41,51:14,53:1,55:0x15b,56:42,57:58,58:56,59:29,60:54,61:0x138,62:0x11d,76:0x11c,96:63,97:64,98:65,99:61,100:66,101:67,103:87,109:68,111:88,115:0x147,116:0x149,117:0x153,118:62,119:0x14f,120:60,121:0x151,122:59,123:0x14b,124:0x14d,125:0x150,126:0x148]
    static let special:[UInt16:UInt32]=[36:0xff0d,48:0xff09,51:0xff08,53:0xff1b,55:0xffeb,56:0xffe1,57:0xffe5,58:0xffe9,59:0xffe3,60:0xffe2,61:0xffea,62:0xffe4,76:0xff8d,115:0xff50,116:0xff55,117:0xffff,119:0xff57,121:0xff56,123:0xff51,124:0xff53,125:0xff54,126:0xff52,122:0xffbe,120:0xffbf,99:0xffc0,118:0xffc1,96:0xffc2,97:0xffc3,98:0xffc4,100:0xffc5,101:0xffc6,109:0xffc7,103:0xffc8,111:0xffc9]
    override func keyDown(with e:NSEvent) {
        if kind == "VNC" { let value=Self.special[e.keyCode] ?? e.charactersIgnoringModifiers?.unicodeScalars.first.map { $0.value<=255 ? $0.value:0x01000000|$0.value };if let value {held[e.keyCode]=value;key(value,down:true)} }
        else if Self.special[e.keyCode]==nil,!e.modifierFlags.contains(.control),!e.modifierFlags.contains(.command),let text=e.characters,!text.isEmpty {for unit in text.utf16 {key(UInt32(unit),down:true,unicode:true);key(UInt32(unit),down:false,unicode:true)} }
        else if let value=Self.scan[e.keyCode] { held[e.keyCode]=value;key(value,down:true) }
    }
    override func keyUp(with e:NSEvent) { if let value=held.removeValue(forKey:e.keyCode) { key(value,down:false) } }
    override func flagsChanged(with e:NSEvent) {
        let flags:[(NSEvent.ModifierFlags,UInt16)]=[(.shift,56),(.control,59),(.option,58),(.command,55)]
        for (flag,code) in flags where e.modifierFlags.contains(flag) != modifiers.contains(flag) {let value=kind == "VNC" ? Self.special[code]!:Self.scan[code]!;key(value,down:e.modifierFlags.contains(flag));if e.modifierFlags.contains(flag){held[code]=value}else{held.removeValue(forKey:code)}}
        if e.modifierFlags.contains(.capsLock) != modifiers.contains(.capsLock) {let value=kind == "VNC" ? Self.special[57]!:Self.scan[57]!;key(value,down:true);key(value,down:false)}
        modifiers=e.modifierFlags
    }
    func releaseKeys() {for value in held.values {key(value,down:false)};held.removeAll();modifiers=[];let old=buttons;buttons=0;for (bit,flag) in [(UInt8(1),UInt16(0x1000)),(UInt8(4),UInt16(0x2000)),(UInt8(2),UInt16(0x4000))] where old & bit != 0 {pointer(x:0,y:0,flags:flag)} }
    private func pointer(x:UInt16,y:UInt16,flags:UInt16) {var data=Data();if kind == "VNC" {data.append(buttons);data.u16(x);data.u16(y);client?.send("P",data)}else{data.u16(flags);data.u16(x);data.u16(y);data.u16(0);client?.send("M",data)} }
    private func mouse(_ e:NSEvent,flags:UInt16) {guard let image else{return};let point=convert(e.locationInWindow,from:nil),rect=imageRect;let x=UInt16(max(0,min(CGFloat(image.width-1),(point.x-rect.minX)/rect.width*CGFloat(image.width)))),y=UInt16(max(0,min(CGFloat(image.height-1),(point.y-rect.minY)/rect.height*CGFloat(image.height))));pointer(x:x,y:y,flags:flags) }
    override func mouseMoved(with e:NSEvent){mouse(e,flags:0x0800)}
    override func mouseDragged(with e:NSEvent){mouseMoved(with:e)}
    override func rightMouseDragged(with e:NSEvent){mouseMoved(with:e)}
    override func otherMouseDragged(with e:NSEvent){mouseMoved(with:e)}
    override func mouseDown(with e:NSEvent){window?.makeFirstResponder(self);buttons|=1;mouse(e,flags:0x9000)}
    override func mouseUp(with e:NSEvent){buttons &= ~1;mouse(e,flags:0x1000)}
    override func rightMouseDown(with e:NSEvent){buttons|=4;mouse(e,flags:0xa000)}
    override func rightMouseUp(with e:NSEvent){buttons &= ~4;mouse(e,flags:0x2000)}
    override func otherMouseDown(with e:NSEvent){buttons|=2;mouse(e,flags:0xc000)}
    override func otherMouseUp(with e:NSEvent){buttons &= ~2;mouse(e,flags:0x4000)}
    override func scrollWheel(with e:NSEvent){guard e.scrollingDeltaY != 0 else{return};let up=e.scrollingDeltaY>0;if kind == "VNC" {let old=buttons;buttons|=up ? 8:16;mouse(e,flags:0);buttons=old;mouse(e,flags:0)}else{mouse(e,flags:up ? 0x0278:0x0388)} }
}
