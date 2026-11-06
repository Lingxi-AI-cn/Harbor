import Foundation
import Darwin

struct SerialSettings: Codable, Equatable {
    var device: String
    var baud = 115200
    var dataBits = 8
    var parity = "None"
    var stopBits = 1
    var flow = "None"
    var lineEnding = "CR"
    var localEcho = false
    static let baudRates = [300,600,1200,2400,4800,9600,19200,38400,57600,115200,230400]
    static let parities = ["None","Even","Odd"]
    static let flows = ["None","RTS/CTS","XON/XOFF"]
    static let endings = ["CR","LF","CRLF"]
    var summary: String { "\(device) · \(baud) · \(dataBits)\(parity.prefix(1))\(stopBits) · \(flow)" }
    func validate() throws {
        // Only device nodes, never regular files or arbitrary paths. /dev/ttys* also
        // supports reproducible PTY acceptance without physical hardware.
        guard device.range(of:#"^/dev/(?:cu\.[A-Za-z0-9._-]+|tty\.[A-Za-z0-9._-]+|ttys[0-9]+)$"#,options:.regularExpression) != nil,
              Self.baudRates.contains(baud), (5...8).contains(dataBits), Self.parities.contains(parity),
              [1,2].contains(stopBits), Self.flows.contains(flow), Self.endings.contains(lineEnding) else { throw SerialFailure(L("Invalid serial device or parameters.")) }
    }
    static func devices() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath:"/dev")) ?? []).filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/"+$0 }
    }
    func encodeArgument() -> String { (try! JSONEncoder().encode(self)).base64EncodedString() }
}
struct SerialFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
private var serialInterrupted: sig_atomic_t = 0

enum SerialBridge {
    static func failure(_ action: String) -> SerialFailure { SerialFailure("\(action): \(String(cString:strerror(errno)))") }
    static func main(_ argument: String?) -> Int32 {
        do {
            guard let argument, argument.utf8.count < 8192, let bytes = Data(base64Encoded:argument) else { throw SerialFailure(L("Missing serial configuration.")) }
            let settings = try JSONDecoder().decode(SerialSettings.self,from:bytes)
            try run(settings)
            return 0
        } catch {
            fputs(L("\r\n[Serial: \(error.localizedDescription)]\r\n"),stderr)
            return 1
        }
    }
    static func run(_ settings: SerialSettings) throws {
        try settings.validate()
        let fd = Darwin.open(settings.device,O_RDWR | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw failure(L("Cannot open \(settings.device)")) }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd,&st) == 0, (st.st_mode & S_IFMT) == S_IFCHR, isatty(fd) == 1 else { throw SerialFailure(L("The selected path is not a serial TTY device.")) }
        // Advisory locking also protects concurrent Harbor processes on PTYs,
        // whose driver may accept TIOCEXCL without rejecting another open.
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw failure(L("Serial device is already in use")) }
        defer { _ = flock(fd,LOCK_UN) }
        guard ioctl(fd,TIOCEXCL) == 0 else { throw failure(L("Cannot exclusively claim serial device")) }
        defer { _ = ioctl(fd,TIOCNXCL) }
        var original = termios()
        guard tcgetattr(fd,&original) == 0 else { throw failure(L("Cannot read serial parameters")) }
        defer { _ = tcsetattr(fd,TCSANOW,&original) }
        var configured = original; cfmakeraw(&configured)
        configured.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
        configured.c_cflag |= tcflag_t(CLOCAL | CREAD)
        configured.c_cflag |= [5:tcflag_t(CS5),6:tcflag_t(CS6),7:tcflag_t(CS7),8:tcflag_t(CS8)][settings.dataBits]!
        if settings.parity != "None" { configured.c_cflag |= tcflag_t(PARENB); if settings.parity == "Odd" { configured.c_cflag |= tcflag_t(PARODD) } }
        if settings.stopBits == 2 { configured.c_cflag |= tcflag_t(CSTOPB) }
        configured.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        if settings.flow == "RTS/CTS" { configured.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW) }
        if settings.flow == "XON/XOFF" { configured.c_iflag |= tcflag_t(IXON | IXOFF) }
        guard cfsetspeed(&configured,speed_t(settings.baud)) == 0, tcsetattr(fd,TCSANOW,&configured) == 0 else { throw failure(L("Serial driver rejected these parameters")) }
        var inputOriginal = termios(); let inputIsTTY = tcgetattr(STDIN_FILENO,&inputOriginal) == 0
        if inputIsTTY { var raw = inputOriginal; cfmakeraw(&raw); guard tcsetattr(STDIN_FILENO,TCSANOW,&raw) == 0 else { throw failure(L("Cannot configure terminal input")) } }
        defer { if inputIsTTY { _ = tcsetattr(STDIN_FILENO,TCSANOW,&inputOriginal) } }
        let inFlags = fcntl(STDIN_FILENO,F_GETFL), outFlags = fcntl(STDOUT_FILENO,F_GETFL)
        guard inFlags >= 0, outFlags >= 0 else { throw failure(L("Cannot access terminal IO")) }
        _ = fcntl(STDIN_FILENO,F_SETFL,inFlags | O_NONBLOCK); _ = fcntl(STDOUT_FILENO,F_SETFL,outFlags | O_NONBLOCK)
        defer { _ = fcntl(STDIN_FILENO,F_SETFL,inFlags); _ = fcntl(STDOUT_FILENO,F_SETFL,outFlags) }
        serialInterrupted = 0
        signal(SIGTERM) { _ in serialInterrupted = 1 }; signal(SIGHUP) { _ in serialInterrupted = 1 }; signal(SIGINT) { _ in serialInterrupted = 1 }; signal(SIGPIPE,SIG_IGN)
        var toDevice = [UInt8](), toTerminal = Array(L("\r\n[Serial open: \(settings.summary). Close this tab to disconnect.]\r\n").utf8)
        var deviceEnded = false
        let limit = 65536
        while serialInterrupted == 0 {
            if deviceEnded && toTerminal.isEmpty { throw SerialFailure(L("Device disconnected or its driver closed the port. Reconnect explicitly when ready.")) }
            var descriptors = [pollfd(fd:STDIN_FILENO,events:(!deviceEnded && toDevice.count < limit && toTerminal.count < limit) ? Int16(POLLIN) : 0,revents:0),
                               pollfd(fd:fd,events:deviceEnded ? 0 : (toTerminal.count < limit ? Int16(POLLIN) : 0) | (toDevice.isEmpty ? 0 : Int16(POLLOUT)),revents:0),
                               pollfd(fd:STDOUT_FILENO,events:toTerminal.isEmpty ? 0 : Int16(POLLOUT),revents:0)]
            let count = poll(&descriptors,nfds_t(descriptors.count),250)
            if count < 0 { if errno == EINTR { continue }; throw failure(L("Serial poll failed")) }
            if descriptors[2].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                var buffer = [UInt8](repeating:0,count:4096); let n = read(STDIN_FILENO,&buffer,buffer.count)
                if n == 0 { return }
                if n < 0 { if errno != EAGAIN && errno != EINTR { return } }
                else {
                    let input = Array(buffer.prefix(n))
                    if settings.localEcho { toTerminal.append(contentsOf:input) }
                    for b in input {
                        if b == 13 && settings.lineEnding != "CR" { if settings.lineEnding == "CRLF" { toDevice.append(13) }; toDevice.append(10) }
                        else { toDevice.append(b) }
                    }
                }
            }
            if !deviceEnded && descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                var buffer = [UInt8](repeating:0,count:4096); let n = read(fd,&buffer,buffer.count)
                if n > 0 { toTerminal.append(contentsOf:buffer.prefix(n)) }
                else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { deviceEnded = true }
                else if descriptors[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { deviceEnded = true }
            }
            if !deviceEnded && descriptors[1].revents & Int16(POLLOUT) != 0 { try flush(fd,&toDevice) }
            if descriptors[2].revents & Int16(POLLOUT) != 0 { try flush(STDOUT_FILENO,&toTerminal) }
        }
    }
    private static func flush(_ fd: Int32,_ bytes: inout [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        let n = bytes.withUnsafeBytes { write(fd,$0.baseAddress,bytes.count) }
        if n > 0 { bytes.removeFirst(n) }
        else if n < 0 && errno != EAGAIN && errno != EINTR { throw failure(L("Serial IO failed")) }
    }
}
