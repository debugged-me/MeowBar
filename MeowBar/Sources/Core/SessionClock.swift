import Foundation

// Claude's 5h window only opens on the first message; while idle the usage
// API reports 0% with no reset time. Starting it on purpose — as soon as you're
// at the Mac — means it also resets sooner.
enum SessionClock {
    static func isIdle(_ w: UsageWindow?, now: Date = Date()) -> Bool {
        guard let w else { return false }
        if let reset = w.resetsAt { return reset <= now }
        return w.usedPercent == 0
    }

    static let retryInterval: TimeInterval = 15 * 60
    static let activeWithin: TimeInterval = 5 * 60

    static func shouldStart(session: UsageWindow?, dataIsStale: Bool,
                            userIdleSeconds: TimeInterval, screenLocked: Bool,
                            running: Bool, lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard isIdle(session, now: now), !dataIsStale, !running, !screenLocked,
              userIdleSeconds < activeWithin else { return false }
        if let last = lastAttempt, now.timeIntervalSince(last) < retryInterval { return false }
        return true
    }

    // Observed resets land on the hour (…T22:59:59.8Z), so a window opened now
    // resets five hours after the top of the current hour. Only shown until
    // the usage API reports the real reset time.
    static func estimatedReset(startedAt: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: startedAt)?.start ?? startedAt
        return hour.addingTimeInterval(5 * 3600)
    }
}
