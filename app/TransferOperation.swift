import Foundation
import Darwin

/// Cancellation belongs to one transport, never the authenticated SSH master.
final class TransferOperation {
    private let lock = NSLock()
    private var process: Process?
    private var reason: String?
    func attach(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if let reason { throw NSError(domain:"HarborTransfer",code:1,userInfo:[NSLocalizedDescriptionKey:reason]) }
        try process.run(); self.process = process
    }
    func cancel(_ message: String = L("Operation cancelled. Refresh or retry when ready.")) {
        lock.lock(); if reason == nil { reason = message }; lock.unlock()
        terminateTransport()
    }
    func terminateTransport() {
        lock.lock(); let child = process; lock.unlock()
        guard let child else { return }
        if child.isRunning { child.terminate() }
        // A stuck transport must not leave a read/wait blocked indefinitely.
        DispatchQueue.global().asyncAfter(deadline:.now()+2) {
            if child.isRunning { _ = kill(child.processIdentifier,SIGKILL) }
        }
    }
    func check() throws {
        lock.lock(); let value = reason; lock.unlock()
        if let value { throw NSError(domain:"HarborTransfer",code:1,userInfo:[NSLocalizedDescriptionKey:value]) }
    }
    func finish() { lock.lock(); process = nil; lock.unlock() }
}
