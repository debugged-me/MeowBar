import XCTest
@testable import MeowBarCore

// The failure modes that matter for an app left running for weeks: commands
// that hang, flood output, leave children behind, or run thousands of times.
final class ProcessRunnerTests: XCTestCase {
    private func shell(_ script: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        return p
    }

    private func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    private func openFDs() -> Int {
        (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    func testCapturesOutputAndStatus() {
        let r = ProcessRunner.run(shell("echo hello; exit 3"), timeout: 5)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(String(data: r.output, encoding: .utf8), "hello\n")
    }

    func testLargeOutputDoesNotDeadlock() {
        // Far past the 64KB pipe buffer.
        let start = Date()
        let r = ProcessRunner.run(shell("head -c 1000000 /dev/zero | tr '\\\\0' a"), timeout: 10)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.output.count, 1_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testHungCommandIsKilledAtTimeout() {
        let start = Date()
        var pid: Int32 = 0
        let r = ProcessRunner.run(shell("exec sleep 60"), timeout: 0.5) { pid = $0 }
        XCTAssertEqual(r.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertNotEqual(kill(pid, 0), 0, "timed-out child should be gone")
    }

    func testChildIgnoringSIGTERMIsKilled() {
        let start = Date()
        var pid: Int32 = 0
        let r = ProcessRunner.run(shell("trap '' TERM; while :; do sleep 0.1; done"), timeout: 0.5) { pid = $0 }
        XCTAssertEqual(r.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testGrandchildHoldingThePipeDoesNotHang() {
        // The shell exits at once, but its background child keeps stdout open.
        let start = Date()
        let r = ProcessRunner.run(shell("echo hi; sleep 5 &"), timeout: 10)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(String(data: r.output, encoding: .utf8), "hi\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testMissingBinary() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/nonexistent/tool")
        XCTAssertEqual(ProcessRunner.run(p, timeout: 1).status, -1)
    }

    // Hours of polling compressed: a second identical batch must add nothing.
    // (GCD's worker pool grows to ~10 threads on the first concurrent batch
    // and reaps them when idle — measured flat at 11–12 across 3000 runs, so
    // the comparison is batch-to-batch, not against a cold start.)
    func testThousandsOfRunsLeakNothing() {
        func batch() {
            for _ in 0..<300 { _ = ProcessRunner.run(shell("echo x"), timeout: 5) }
            DispatchQueue.concurrentPerform(iterations: 100) { _ in
                _ = ProcessRunner.run(self.shell("echo y"), timeout: 5)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        batch()
        let threads1 = threadCount(), fds1 = openFDs()
        batch()
        batch()
        XCTAssertLessThanOrEqual(threadCount() - threads1, 3, "threads grew between batches")
        XCTAssertLessThanOrEqual(openFDs() - fds1, 0, "file descriptors leaked")
    }
}

final class ProcScanTests: XCTestCase {
    private func spawn(_ path: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        return p
    }

    func testMeasuresBusyAndIdleProcesses() throws {
        // `yes` spins a core; `sleep` uses none.
        let busy = try spawn("/usr/bin/yes", [])
        let idle = try spawn("/bin/sleep", ["10"])
        defer { busy.terminate(); idle.terminate() }
        let scan = ProcScan()
        _ = scan.sample(names: ["yes", "sleep"])
        Thread.sleep(forTimeInterval: 1)
        let procs = scan.sample(names: ["yes", "sleep"])
        let busyPct = procs.first { $0.pid == busy.processIdentifier }?.cpuPercent ?? -1
        let idlePct = procs.first { $0.pid == idle.processIdentifier }?.cpuPercent ?? -1
        XCTAssertGreaterThan(busyPct, 50, "busy process should read near 100%")
        XCTAssertGreaterThanOrEqual(idlePct, 0)
        XCTAssertLessThan(idlePct, 1.5, "sleeping process should read ~0%")
    }

    func testFirstSightReadsZeroAndExitedPidsDropOut() throws {
        let p = try spawn("/bin/sleep", ["10"])
        let scan = ProcScan()
        XCTAssertEqual(scan.sample(names: ["sleep"]).first { $0.pid == p.processIdentifier }?.cpuPercent, 0)
        p.terminate(); p.waitUntilExit()
        XCTAssertNil(scan.sample(names: ["sleep"]).first { $0.pid == p.processIdentifier })
    }
}

final class MergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func good(fetched: TimeInterval) -> ProviderUsage {
        var u = ProviderUsage(name: "Claude")
        u.session = UsageWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(3600), windowSeconds: 18000)
        u.fetchedAt = now.addingTimeInterval(-fetched)
        return u
    }

    func testTransientFailureKeepsLastGoodNumbers() {
        var failed = ProviderUsage(name: "Claude")
        failed.error = "Anthropic is rate-limiting usage checks"
        let m = ProviderUsage.merge(failed, over: good(fetched: 600), now: now)
        XCTAssertEqual(m.session?.usedPercent, 40)
        XCTAssertTrue(m.isStale)
        XCTAssertNil(m.error)
    }

    func testSignInProblemsStillShow() {
        var failed = ProviderUsage(name: "Claude")
        failed.error = "Claude session rejected"
        failed.action = .renewClaude
        let m = ProviderUsage.merge(failed, over: good(fetched: 600), now: now)
        XCTAssertNil(m.session)
        XCTAssertEqual(m.error, "Claude session rejected")
    }

    func testVeryOldNumbersAreNotKept() {
        var failed = ProviderUsage(name: "Claude")
        failed.error = "offline"
        XCTAssertNil(ProviderUsage.merge(failed, over: good(fetched: 7 * 3600), now: now).session)
    }

    func testFreshDataWins() {
        var fresh = good(fetched: 0)
        fresh.session?.usedPercent = 55
        let m = ProviderUsage.merge(fresh, over: good(fetched: 600), now: now)
        XCTAssertEqual(m.session?.usedPercent, 55)
        XCTAssertFalse(m.isStale)
    }
}
