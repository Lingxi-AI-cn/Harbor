import AppKit

final class SerialEditor: NSWindowController, NSWindowDelegate {
    weak var hostController: AppController?
    let original: Connection?
    let name = NSTextField(), device = NSTextField(), folder = NSTextField()
    let devices = NSPopUpButton(frame:.zero,pullsDown:false)
    let baud = NSPopUpButton(frame:.zero,pullsDown:false), bits = NSPopUpButton(frame:.zero,pullsDown:false)
    let parity = NSPopUpButton(frame:.zero,pullsDown:false), stop = NSPopUpButton(frame:.zero,pullsDown:false)
    let flow = NSPopUpButton(frame:.zero,pullsDown:false), ending = NSPopUpButton(frame:.zero,pullsDown:false)
    let echo = NSButton(checkboxWithTitle:L("Local echo (off when the device echoes input)"),target:nil,action:nil)
    let saveSession = NSButton(checkboxWithTitle:L("Save this session"),target:nil,action:nil)
    let favorite = NSButton(checkboxWithTitle:L("Favorite"),target:nil,action:nil)
    init(owner: AppController, existing: Connection?) {
        hostController = owner; original = existing
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = existing == nil ? L("Serial connection") : L("Edit serial session")
        window.isReleasedWhenClosed = false; window.appearance = nil
        super.init(window:window); window.delegate = self
        let content = Canvas(); window.contentView = content
        let settings = existing?.serial ?? SerialSettings(device:"")
        baud.addItems(withTitles:SerialSettings.baudRates.map(String.init)); baud.selectItem(withTitle:String(settings.baud))
        bits.addItems(withTitles:["5","6","7","8"]); bits.selectItem(withTitle:String(settings.dataBits))
        parity.addLocalizedItems(withValues:SerialSettings.parities); parity.selectRawValue(settings.parity)
        stop.addItems(withTitles:["1","2"]); stop.selectItem(withTitle:String(settings.stopBits))
        flow.addLocalizedItems(withValues:SerialSettings.flows); flow.selectRawValue(settings.flow)
        ending.addLocalizedItems(withValues:SerialSettings.endings); ending.selectRawValue(settings.lineEnding)
        name.stringValue = existing?.name ?? ""; name.placeholderString = L("Device console")
        device.stringValue = settings.device; device.placeholderString = "/dev/cu.usbserial-…"
        folder.stringValue = existing?.folder ?? ""; folder.placeholderString = "Devices/Development"
        favorite.state = existing?.favorite == true ? .on : .off; echo.state = settings.localEcho ? .on : .off
        saveSession.state = .on; saveSession.isEnabled = existing == nil
        devices.target = self; devices.action = #selector(selectDevice)
        let rows: [(String,NSView)] = [(L("Session name"),name),(L("Detected devices"),devices),(L("Device path"),device),(L("Baud rate"),baud),(L("Data bits"),bits),(L("Parity"),parity),(L("Stop bits"),stop),(L("Flow control"),flow),(L("Return sends"),ending),(L("Folder"),folder)]
        for (i,row) in rows.enumerated() {
            let y = CGFloat(20+i*43)
            let title = label(row.0,size:12,color:muted); title.frame = NSRect(x:20,y:y+5,width:140,height:23)
            row.1.frame = NSRect(x:170,y:y,width:i == 1 ? 330 : 450,height:28)
            content.addSubview(title); content.addSubview(row.1)
        }
        let refresh = ActionButton(L("Refresh")) { [weak self] in self?.refreshDevices() }; refresh.frame = NSRect(x:510,y:63,width:110,height:28); content.addSubview(refresh)
        echo.frame = NSRect(x:170,y:455,width:450,height:24); content.addSubview(echo)
        saveSession.frame = NSRect(x:170,y:488,width:220,height:24); content.addSubview(saveSession)
        favorite.frame = NSRect(x:425,y:488,width:160,height:24); content.addSubview(favorite)
        let note = label(L("Opening a serial port may toggle device control lines. No automatic reconnect.\nClose the terminal tab before another application uses this device.\nCR/LF conversion applies to Return (CR) bytes; received bytes are unchanged."),size:11,color:muted)
        note.frame = NSRect(x:20,y:528,width:610,height:60); content.addSubview(note)
        let cancel = ActionButton(L("Cancel")) { [weak self] in self?.dismiss() }; cancel.frame = NSRect(x:390,y:610,width:105,height:30)
        let submit = ActionButton(existing == nil ? L("Connect") : L("Save"),primary:true) { [weak self] in self?.submit() }; submit.frame = NSRect(x:510,y:610,width:110,height:30)
        content.addSubview(cancel); content.addSubview(submit); refreshDevices()
    }
    required init?(coder:NSCoder) { fatalError() }
    func refreshDevices() {
        let available = SerialSettings.devices()
        devices.removeAllItems(); devices.addItem(withTitle:available.isEmpty ? L("No callout devices detected") : L("Choose a device…"))
        devices.addItems(withTitles:available)
        if available.contains(device.stringValue) { devices.selectItem(withTitle:device.stringValue) }
    }
    @objc func selectDevice() { if devices.indexOfSelectedItem > 0 { device.stringValue = devices.titleOfSelectedItem ?? "" } }
    func show() { guard let window, let parent = hostController?.window else { return }; parent.beginSheet(window) }
    func dismiss() { if let window { hostController?.window.endSheet(window); window.orderOut(nil) }; hostController?.serialEditor = nil }
    func windowShouldClose(_ sender:NSWindow) -> Bool { dismiss(); return false }
    func submit() {
        let path = device.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let settings = SerialSettings(device:path,baud:Int(baud.titleOfSelectedItem ?? "") ?? 0,dataBits:Int(bits.titleOfSelectedItem ?? "") ?? 0,parity:parity.rawSelectedValue ?? "",stopBits:Int(stop.titleOfSelectedItem ?? "") ?? 0,flow:flow.rawSelectedValue ?? "",lineEnding:ending.rawSelectedValue ?? "",localEcho:echo.state == .on)
        var c = original ?? Connection(name:"",host:path,user:"",kind:"Serial")
        c.name = name.stringValue.isEmpty ? (path as NSString).lastPathComponent : name.stringValue
        c.host = path; c.serial = settings; c.folder = folder.stringValue; c.favorite = favorite.state == .on
        do {
            try c.validate()
            if original != nil || saveSession.state == .on { try hostController?.saveConnection(c) }
            let owner = hostController; dismiss(); if original == nil { owner?.connect(c) }
        } catch { hostController?.showError(error) }
    }
}
extension AppController {
    @objc func newSerial() { showSerial() }
    func showSerial(existing: Connection? = nil) {
        guard serialEditor == nil, editor == nil else { return }
        let value = SerialEditor(owner:self,existing:existing); serialEditor = value; value.show()
    }
}
