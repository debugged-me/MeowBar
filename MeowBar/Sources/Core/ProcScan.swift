import Darwin
import Foundation

// In-process process table. Replaces spawning `/bin/ps` every 2s (~43k
// launches a day) with a handful of syscalls. CPU % is measured between
// consecutive samples of the same pid.
final class ProcScan: @unchecked Sendable {
    struct Proc: Equatable {
        let pid: Int32
        let name: String        // executable name, as `ps -o ucomm` shows it
        let cpuPercent: Double  // since the previous sample; 0 on first sight
    }

    private var last: [Int32: (cpu: UInt64, at: UInt64)] = [:]  // nanoseconds
    private let lock = NSLock()
    // Task times come in Mach ticks (41.67ns on Apple Silicon, 1ns on Intel).
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    func sample(names: Set<String>) -> [Proc] {
        lock.lock(); defer { lock.unlock() }
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride)))
        let now = DispatchTime.now().uptimeNanoseconds
        let tb = Self.timebase
        var seen: [Int32: (cpu: UInt64, at: UInt64)] = [:]
        var out: [Proc] = []
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            guard proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 else { continue }
            let name = String(cString: nameBuf)
            guard names.contains(name) else { continue }
            var usage = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard rc == 0 else { continue }
            let cpu = (usage.ri_user_time + usage.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
            seen[pid] = (cpu, now)
            var pct = 0.0
            if let prev = last[pid], now > prev.at, cpu >= prev.cpu {
                pct = Double(cpu - prev.cpu) / Double(now - prev.at) * 100
            }
            out.append(Proc(pid: pid, name: name, cpuPercent: pct))
        }
        last = seen  // exited pids drop out — the table never grows
        return out
    }
}
