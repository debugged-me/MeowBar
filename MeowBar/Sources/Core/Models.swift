import Foundation

// Pure data + math, Foundation only. Package.swift builds this folder alone as
// MeowBarCore for `swift test`; build.sh compiles it straight into the app.

struct UsageWindow: Codable, Equatable {
    var usedPercent: Double = 0
    var resetsAt: Date? = nil
    var windowSeconds: TimeInterval? = nil
}

// What the user can do about an error state — rendered as a button under it.
enum ProviderAction: Equatable {
    case renewClaude            // launch `claude` briefly so it self-renews
    case runInTerminal(String)  // e.g. "codex login"
    case openApp(String)        // e.g. "Devin" in /Applications

    var title: String {
        switch self {
        case .renewClaude: return "Renew sign-in"
        case .runInTerminal(let cmd): return "Run `\(cmd)` in Terminal"
        case .openApp(let app): return "Open \(app)"
        }
    }
}

struct ProviderUsage: Codable {
    var name: String
    var session: UsageWindow? = nil
    var weekly: UsageWindow? = nil
    var error: String? = nil
    var action: ProviderAction? = nil
    var note: String? = nil       // plan label, e.g. "Pro" — shown alongside bars
    var noteAccent: String? = nil // emphasized word, e.g. "unlimited" (green)
    var fetchedAt: Date = Date()
    // Showing a fallback copy (rate-limited, transient failure, or last run's
    // cache) rather than a fresh answer.
    var isStale = false
    var hasData: Bool { session != nil || weekly != nil }
    var isVisible: Bool { hasData || note != nil || noteAccent != nil }

    // Persist the numbers only — errors, actions and staleness are per-fetch.
    private enum CodingKeys: String, CodingKey {
        case name, session, weekly, note, noteAccent, fetchedAt
    }
}

extension ProviderUsage {
    var worstUsed: Double? {
        [session, weekly].compactMap { $0 }.map(\.usedPercent).max()
    }

    // Menu-bar number: weekly % left only when the weekly itself is the blocker
    // (≥90% used); otherwise the session % left.
    var displayLeft: Double? {
        let s = session?.usedPercent, w = weekly?.usedPercent
        if let w, w >= 90 { return 100 - w }
        return (s ?? w).map { 100 - $0 }
    }

    // The window the bar is displaying — same rule as displayLeft.
    var displayReset: Date? {
        if let w = weekly, w.usedPercent >= 90 { return w.resetsAt }
        return session?.resetsAt ?? weekly?.resetsAt
    }

    // A transient failure (rate limit, network, server hiccup — anything
    // without a fix-it action) keeps the last good numbers, marked stale, for
    // up to 6h instead of flashing an error. Sign-in problems still show.
    static func merge(_ new: ProviderUsage, over old: ProviderUsage, now: Date = Date()) -> ProviderUsage {
        if !new.hasData, new.action == nil, old.hasData,
           now.timeIntervalSince(old.fetchedAt) < 6 * 3600 {
            var kept = old.normalized(now: now)
            kept.isStale = true
            return kept
        }
        return new.normalized(now: now)
    }

    // Copy with every window brought up to date (see UsageWindow.normalized).
    func normalized(now: Date = Date()) -> ProviderUsage {
        var u = self
        u.session = session?.normalized(now: now)
        u.weekly = weekly?.normalized(now: now)
        return u
    }
}

extension UsageWindow {
    // A window whose reset has passed no longer describes reality. 5h windows
    // go idle (the next one opens on the next message); daily and weekly ones
    // are anchored, so they roll forward to their next reset.
    func normalized(now: Date = Date()) -> UsageWindow {
        guard let reset = resetsAt, reset <= now else { return self }
        var w = self
        w.usedPercent = 0
        if let win = windowSeconds, win >= 86400 {
            var next = reset
            while next <= now { next += win }
            w.resetsAt = next
        } else {
            w.resetsAt = nil
        }
        return w
    }

    // Fraction of the window already elapsed — where an even burn would be.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let win = windowSeconds, win > 0, let reset = resetsAt else { return nil }
        return min(1, max(0, (win - reset.timeIntervalSince(now)) / win))
    }

    // Projected usage at reset (linear burn since the window opened) → a
    // short verdict, worded as the guess it is. Silent until there's signal:
    // 10% of the window gone (30 min of a 5h window, ~17h of a week) unless
    // usage is already high — 3h into a week says little about Friday.
    func paceVerdict(now: Date = Date()) -> String {
        guard let win = windowSeconds, let reset = resetsAt else { return "" }
        if usedPercent >= 100 { return "maxed" }
        let remaining = reset.timeIntervalSince(now)
        let elapsed = win - remaining
        guard elapsed > 600, elapsed >= win * 0.1 || usedPercent >= 30 else { return "" }
        let usedFrac = usedPercent / 100
        let projected = usedFrac * win / elapsed
        if projected >= 1 {
            let secondsToFull = (1 - usedFrac) * elapsed / max(usedFrac, 0.001)
            guard secondsToFull < remaining else { return "cutting it close" }
            return "may run out in ~\(Countdown.rough(secondsToFull))"
        }
        if projected < 0.55 { return "plenty left" }
        if projected < 0.85 { return "comfortable" }
        return "cutting it close"
    }
}

enum Countdown {
    // "in 4h 52m" / "in 6d 22h" / "in <1m" — never "in 0m".
    static func long(to date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return m > 0 ? "in \(m)m" : "in <1m"
    }

    // "4h59m" / "6d10h" / "<1m" — the menu bar's countdown mode.
    static func compact(to date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return m > 0 ? "\(m)m" : "<1m"
    }

    // Coarse durations for projections — no false precision: 5-min steps
    // under an hour, 15-min steps under a day, 6-hour steps beyond.
    static func rough(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 3600 {
            let m = max(5, Int((s / 300).rounded()) * 5)
            return m >= 60 ? "1h" : "\(m)m"
        }
        if s < 86400 {
            let q = Int((s / 900).rounded()), h = q / 4, m = (q % 4) * 15
            if h >= 24 { return "1d" }
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        let h6 = Int((s / 21600).rounded()) * 6, d = h6 / 24, h = h6 % 24
        return h == 0 ? "\(d)d" : "\(d)d \(h)h"
    }

    // "just now" / "4m ago" / "2h ago" — footer freshness.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

enum AppVersion {
    // Dotted numeric compare: "1.10" > "1.9", "1.1" == "1.1.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
