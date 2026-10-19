import Foundation

// Runs a configured Process to completion → (exit status, stdout).
// -1 = could not launch, -2 = timed out (killed).
//
// Never parks a thread: exit arrives via terminationHandler and output via
// readabilityHandler, so a call costs one waiting caller and nothing else.
// The first version called waitUntilExit() on GCD workers, which can wait
// forever (seen after sleep/wake); with `ps` every 2s, 64 stuck workers
// filled GCD's pool within hours and every later command — Keychain reads
// included — timed out.
enum ProcessRunner {
    static func run(_ p: Process, timeout: TimeInterval,
                    onLaunch: ((Int32) -> Void)? = nil) -> (status: Int32, output: Data) {
        let pipe = Pipe(), lock = NSLock(), reader = pipe.fileHandleForReading
        let exited = DispatchSemaphore(value: 0), eof = DispatchSemaphore(value: 0)
        var out = Data(), closed = false
        // The read end is closed explicitly — releasing a handle that had a
        // readabilityHandler does not reliably close its fd (measured: ~0.7
        // fds leaked per run, fatal at one `ps` every 2s for weeks). Reads and
        // the close share `lock`, so a late handler call never touches a
        // closed handle (which would raise).
        func closeReader() {
            guard !closed else { return }
            closed = true
            reader.readabilityHandler = nil
            try? reader.close()
        }
        p.standardOutput = pipe
        if p.standardError == nil { p.standardError = FileHandle.nullDevice }
        if p.standardInput == nil { p.standardInput = FileHandle.nullDevice }
        p.terminationHandler = { _ in exited.signal() }
        // Drained as it arrives: a >64KB write would otherwise fill the pipe
        // and the child would never exit.
        reader.readabilityHandler = { h in
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            let chunk = h.availableData
            if chunk.isEmpty { closeReader(); eof.signal(); return }
            out.append(chunk)
        }
        do { try p.run() } catch {
            lock.lock(); closeReader(); lock.unlock()
            try? pipe.fileHandleForWriting.close()
            return (-1, Data())
        }
        onLaunch?(p.processIdentifier)
        var status: Int32 = -2
        if exited.wait(timeout: .now() + timeout) == .success {
            status = p.terminationStatus
        } else {
            // A stuck child (e.g. an unanswered Keychain prompt) must not hang a caller.
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        // EOF follows exit immediately unless a grandchild still holds the
        // pipe — then take what arrived rather than wait on it.
        _ = eof.wait(timeout: .now() + 1)
        lock.lock(); defer { lock.unlock() }
        closeReader()
        return (status, out)
    }
}
