import AppKit
import Darwin
if CommandLine.arguments.dropFirst().first == "--serial-bridge" { exit(SerialBridge.main(CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : nil)) }
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let controller = AppController(); app.delegate = controller
var assertions = 0, failures = 0
func check(_ condition: Bool,_ name: String) { assertions += 1; print("\(condition ? "PASS" : "FAIL"): \(name)"); fflush(stdout); if !condition { failures += 1 } }
func until(_ seconds: Double = 5,_ condition: () -> Bool) -> Bool { let end = Date().addingTimeInterval(seconds); while !condition() && Date() < end { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }; return condition() }
func rejects(_ name: String,_ work: () throws -> Void) { do { try work(); check(false,name) } catch { check(true,name) } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-serial-native-\(UUID().uuidString)")
Timer.scheduledTimer(withTimeInterval:0.2,repeats:false) { _ in
    if controller.window == nil { controller.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification)) }
    var master: Int32 = -1, slave: Int32 = -1
    defer { if master >= 0 { Darwin.close(master) }; if slave >= 0 { Darwin.close(slave) }; try? FileManager.default.removeItem(at:root) }
    do {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        controller.store = try SessionStore(url:root.appendingPathComponent("sessions.json"))
        var path = [CChar](repeating:0,count:256)
        guard openpty(&master,&slave,&path,nil,nil) == 0 else { throw SerialFailure("openpty failed") }
        _ = fcntl(master,F_SETFL,O_NONBLOCK)
        _ = fcntl(master,F_SETFD,FD_CLOEXEC); _ = fcntl(slave,F_SETFD,FD_CLOEXEC)
        var connection = Connection(name:"Serial fixture",host:String(cString:path),user:"",kind:"Serial")
        connection.serial = SerialSettings(device:connection.host,lineEnding:"CRLF")
        connection.folder = "Devices/Test"; connection.favorite = true
        try controller.saveConnection(connection)
        let restored = try SessionStore(url:controller.store.url)
        check(restored.connections.first?.serial == connection.serial && restored.connections.first?.favorite == true,"serial settings and session metadata persist")
        let archive = try SessionArchive(connections:[connection]).data()
        let imported = try SessionArchive.decode(archive)
        check(imported.first?.serial == connection.serial,"serial configuration survives Harbor import/export")
        let old = Data("{\"name\":\"old\",\"host\":\"example.invalid\",\"user\":\"test\",\"id\":\"\(UUID())\",\"port\":22,\"kind\":\"SSH\",\"identity\":\"\",\"x11\":false}".utf8)
        check(try JSONDecoder().decode(Connection.self,from:old).serial == nil,"pre-serial saved SSH sessions remain decodable")
        var invalid = connection; invalid.serial?.device = "/tmp/not-a-device"
        rejects("mismatched or arbitrary device path rejected") { try invalid.validate() }
        check(SessionRules.route(connection).contains("115200") && !SessionRules.route(connection).hasSuffix(":22"),"serial route displays parameters instead of an SSH port")
        let editor = SerialEditor(owner:controller,existing:connection)
        check(editor.device.stringValue == connection.host && editor.ending.titleOfSelectedItem == "CRLF" && editor.baud.titleOfSelectedItem == "115200","editor reloads saved device and serial parameters")
        editor.refreshDevices()
        check(editor.device.stringValue == connection.host,"refresh never silently substitutes a device path")
        controller.connect(connection); controller.workspace.layoutSubtreeIfNeeded()
        guard let tab = controller.tabs.last else { throw SerialFailure("No terminal launched") }
        check(until { tab.view.transcript()?.contains("Serial open:") == true },"serial helper starts inside real terminal backend")
        check(!InputDelivery.eligible(tab),"serial terminal is excluded from broadcast recipients")
        check(tab.remoteFiles == nil,"serial connection does not start SSH or SFTP")
        let snapshot = controller.workspaceSnapshot()
        check(snapshot.groups.count == 1,"serial session is included in workspace snapshot")
        rejects("restoring already-owned serial device is rejected before launching") { try controller.restoreWorkspaceSnapshot(snapshot) }
        check(controller.tabs.count == 1,"rejected workspace restore leaves existing serial terminal intact")
        tab.view.input("serial中文",submit:true)
        var received = Data()
        let expected = Data("serial中文\r\n".utf8)
        check(until { var bytes = [UInt8](repeating:0,count:4096); let n = read(master,&bytes,bytes.count); if n > 0 { received.append(contentsOf:bytes.prefix(n)) }; return received.count >= expected.count } && received == expected,"terminal Unicode input and Return reach serial device with configured CRLF")
        let output = Data("\r\nDEVICE_REPLY中文\r\n".utf8)
        output.withUnsafeBytes { _ = write(master,$0.baseAddress,output.count) }
        check(until { tab.view.transcript()?.contains("DEVICE_REPLY中文") == true },"serial device reply renders in terminal")
        controller.closePane(tab)
        check(until { !controller.tabs.contains(where:{$0 === tab}) },"closing serial tab removes its session")
        check(until { let fd = Darwin.open(connection.host,O_RDWR | O_NOCTTY | O_NONBLOCK); if fd < 0 { return false }; defer { Darwin.close(fd) }; return flock(fd,LOCK_EX | LOCK_NB) == 0 },"closing terminal releases bridge device lock")
        try controller.restoreWorkspaceSnapshot(snapshot); controller.workspace.layoutSubtreeIfNeeded()
        guard let restoredTab = controller.tabs.last else { throw SerialFailure("Restore failed") }
        check(until { restoredTab.view.transcript()?.contains("Serial open:") == true },"explicit workspace restore can reopen a released serial port")
        Darwin.close(master); master = -1
        check(until { !restoredTab.running },"device disconnect updates terminal lifecycle")
        check(restoredTab.view.transcript()?.contains("disconnected") == true,"disconnect reason is visible in the terminal")
        controller.closePane(restoredTab)
    } catch { check(false,error.localizedDescription) }
    controller.tabs.forEach { $0.stopTerminal() }
    print("RESULT assertions=\(assertions) failures=\(failures)"); fflush(stdout)
    exit(failures == 0 ? 0 : 1)
}
app.run()
