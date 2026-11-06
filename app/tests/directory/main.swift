import AppKit
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harbor cwd 中文 ' \(UUID())").resolvingSymlinksInPath()
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:directory) }
let session = PTYSession()
var output = Data(), ended = false
session.onOutput = { output.append($0) }
session.onExit = { ended = true }
try session.start(executable:"/bin/sh",arguments:["-c","printf 'PWD=%s\\n' \"$PWD\""],workingDirectory:directory.path)
let deadline = Date().addingTimeInterval(5)
while !ended && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
session.stop()
let canonical = realpath(directory.path,nil)!
defer { free(canonical) }
let passed = ended && String(decoding:output,as:UTF8.self).contains("PWD="+String(cString:canonical))
print("\(passed ? "PASS" : "FAIL"): legacy PTY starts in requested directory")
if !passed { print("ended=\(ended) expected=\(directory.path) output=\(String(decoding:output,as:UTF8.self))") }
exit(passed ? 0 : 1)
