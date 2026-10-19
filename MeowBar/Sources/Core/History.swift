import Foundation

// Local usage history: one sample per observed change (plus a heartbeat), kept
// for 8 days. The APIs only expose "% of window used", so burn is measured in
// percentage points of the weekly budget (session points when a provider has
// no weekly window).
struct UsageSample: Codable, Equatable {
    var t: Date
    var session: Double?
    var weekly: Double?
}

enum UsageHistory {
    static let retention: TimeInterval = 8 * 86400
    static let heartbeat: TimeInterval = 30 * 60

    // Appends when the numbers moved or the heartbeat is due; drops samples
    // past retention. Returns whether anything changed (i.e. worth saving).
    @discardableResult
    static func append(_ s: UsageSample, to samples: inout [UsageSample]) -> Bool {
        var changed = false
        if let last = samples.last {
            let moved = last.session != s.session || last.weekly != s.weekly
            if moved || s.t.timeIntervalSince(last.t) >= heartbeat {
                samples.append(s); changed = true
            }
        } else {
            samples.append(s); changed = true
        }
        let cutoff = s.t.addingTimeInterval(-retention)
        if let first = samples.first, first.t < cutoff {
            samples.removeAll { $0.t < cutoff }
            changed = true
        }
        return changed
    }

    // Points burned between two consecutive samples, attributed to the later
    // one. A drop means the window reset in between: what's on the meter now
    // was all burned since.
    static func burns(_ samples: [UsageSample]) -> [(t: Date, points: Double)] {
        let useWeekly = samples.contains { $0.weekly != nil }
        var out: [(Date, Double)] = []
        for (a, b) in zip(samples, samples.dropFirst()) {
            guard let x = useWeekly ? a.weekly : a.session,
                  let y = useWeekly ? b.weekly : b.session else { continue }
            let p = y >= x ? y - x : y
            if p > 0 { out.append((b.t, p)) }
        }
        return out
    }

    // Burn per calendar day, oldest first, today last.
    static func dailyBurn(_ samples: [UsageSample], days: Int = 7,
                          now: Date = Date(), calendar: Calendar = .current) -> [Double] {
        let today = calendar.startOfDay(for: now)
        var totals = [Double](repeating: 0, count: days)
        for b in burns(samples) {
            let day = calendar.startOfDay(for: b.t)
            guard let ago = calendar.dateComponents([.day], from: day, to: today).day,
                  ago >= 0, ago < days else { continue }
            totals[days - 1 - ago] += b.points
        }
        return totals
    }

    // Start hour of the busiest 3-hour block of the day, or nil until there's
    // enough signal to say anything (≥ 3 points burned in total).
    static func busiestBlock(_ samples: [UsageSample], calendar: Calendar = .current) -> Int? {
        var hours = [Double](repeating: 0, count: 24)
        for b in burns(samples) { hours[calendar.component(.hour, from: b.t)] += b.points }
        guard hours.reduce(0, +) >= 3 else { return nil }
        let block = { (h: Int) in (0..<3).reduce(0.0) { $0 + hours[(h + $1) % 24] } }
        return (0..<24).max { block($0) < block($1) }
    }

    // 14 → "2–5 PM", 10 → "10 AM–1 PM", 23 → "11 PM–2 AM".
    static func blockLabel(startHour h: Int) -> String {
        func parts(_ hour: Int) -> (Int, String) {
            let h24 = hour % 24
            return (h24 % 12 == 0 ? 12 : h24 % 12, h24 < 12 ? "AM" : "PM")
        }
        let (a, am) = parts(h), (b, bm) = parts(h + 3)
        return am == bm ? "\(a)–\(b) \(bm)" : "\(a) \(am)–\(b) \(bm)"
    }
}
