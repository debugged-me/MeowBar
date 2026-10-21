import Cocoa
import QuartzCore
import ServiceManagement
import SwiftUI

final class UsageStore: ObservableObject {
    @Published var claude = ProviderUsage(name: "Claude")
    @Published var codex = ProviderUsage(name: "Codex")
    @Published var devin = ProviderUsage(name: "Devin")
    @Published var claudeRunning = false
    @Published var codexRunning = false
    @Published var devinRunning = false
    // Newest write to a Devin session log — shown as "last active" in the popover.
    @Published var devinLastActive: Date?
    @Published var lastUpdated: Date?
    @Published var history: [String: [UsageSample]] = [:]
    // Finished work stretches per provider, for "3 tasks · 1h24m today".
    @Published var taskSpans: [TaskSpan] = []
    // In-flight task starts (memory only — a quit mid-task just isn't counted).
    var taskStart: [String: Date] = [:]
    // Bumps while the popover is open and an agent runs, so live durations tick.
    @Published var liveTick = Date()
    @Published var clockStarting = false
    @Published var update: UpdateInfo?
    // Set briefly when a window resets (usage drops tens of points at once);
    // the cat celebrates while it's in the future.
    @Published var celebrateUntil: Date?
    // The popover's view stays alive while closed; anything animated must
    // check this or it keeps burning CPU off screen.
    @Published var popoverShown = false
    var onUpdate: (() -> Void)?
    var onAlert: (() -> Void)?
    // Per-animation-tick refresh: title + island only, no tooltip/a11y churn.
    var onFrame: (() -> Void)?
    private var timer: Timer?
    private var activityTimer: Timer?
    private var updateTimer: Timer?
    private var lastClockAttempt: Date?
    private var activityCheckInFlight = false
    // Transient menu-bar alerts: armed on state edges (task finished, limit
    // reached), auto-clear after alertTTL or instantly on click. armedAt feeds
    // the typewriter reveal — each letter lands on its own tick.
    private var alertText: [String: String] = [:]
    private var alertUntil: [String: Date] = [:]
    private var alertArmedAt: [String: Date] = [:]
    private var motionTimer: Timer?
    private var wakeTimer: Timer?
    // A CPU spike is not a task. Rapid samples let IDE-hosted agents appear as
    // running promptly, while confirmation in both directions filters helper
    // startup and prevents false "task done" messages.
    private var busySamples: [String: Int] = [:]
    private var idleSamples: [String: Int] = [:]
    private var confirmedRunning: [String: Bool] = [:]
    private var prevWorst: [String: Double] = [:]
    private let alertTTL: TimeInterval = 6
    private var demoActive = false

    func start() {
        if injectDemo() { return }
        loadCache()
        refresh()
        sampleActivity()
        checkForUpdate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshIfDue()
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sampleActivity()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    // Last run's numbers, shown (marked stale) until the first fetch lands.
    private func loadCache() {
        for var u in AppFiles.load([ProviderUsage].self, from: AppFiles.usageCache) ?? [] {
            u = u.normalized()
            u.isStale = true
            switch u.name {
            case "Claude": claude = u
            case "Codex": codex = u
            case "Devin": devin = u
            default: break
            }
        }
        history = AppFiles.load([String: [UsageSample]].self, from: AppFiles.history) ?? [:]
        var spans = AppFiles.load([TaskSpan].self, from: AppFiles.taskLog) ?? []
        spans.removeAll { Date().timeIntervalSince($0.end) > TaskStats.retention }
        taskSpans = spans
        onUpdate?()
    }

    func checkForUpdate() {
        Task {
            let info = await UpdateCheck.check()
            await MainActor.run { self.update = info }
        }
    }

    // Sample data for screenshots/demos — only active when launched with
    // MEOWBAR_DEMO=normal or MEOWBAR_DEMO=alerts in the environment.
    private func injectDemo() -> Bool {
        guard let mode = ProcessInfo.processInfo.environment["MEOWBAR_DEMO"] else { return false }
        let now = Date()
        func win(_ used: Double, _ inSecs: TimeInterval, _ span: TimeInterval) -> UsageWindow {
            UsageWindow(usedPercent: used, resetsAt: now + inSecs, windowSeconds: span)
        }
        claude.session = win(58, 3.2 * 3600, 18000)
        claude.weekly = win(29, 4.4 * 86400, 604800)
        claude.extras = [NamedWindow(label: "Sonnet", window: win(46, 4.4 * 86400, 604800))]
        codex.session = win(14, 2.1 * 3600, 18000)
        codex.weekly = win(45, 5.2 * 86400, 604800)
        devin.note = "Pro"; devin.noteAccent = "unlimited"
        // A week of afternoon-heavy history for the expanded view.
        for (name, scale) in [("Claude", 1.0), ("Codex", 0.6)] {
            var samples: [UsageSample] = [], w = 0.0
            for i in stride(from: 7 * 24, through: 0, by: -1) {
                let t = now.addingTimeInterval(-Double(i) * 3600)
                let hour = Calendar.current.component(.hour, from: t)
                let busy = (13...17).contains(hour) ? 1.6 : (9...12).contains(hour) ? 0.7 : 0.05
                w += busy * scale * (1 + 0.5 * sin(Double(i) / 9))
                samples.append(UsageSample(t: t, session: nil, weekly: min(w, 100)))
            }
            history[name] = samples
        }
        if mode == "alerts" {
            claude.session = win(96, 0.8 * 3600, 18000)
            claude.weekly = win(100, 3.7 * 86400, 604800)
            codexRunning = true
            arm("Claude", "limit reached", now: now)
        }
        taskSpans = [
            TaskSpan(provider: "Claude", start: now - 5400, end: now - 3300),
            TaskSpan(provider: "Claude", start: now - 1800, end: now - 600),
            TaskSpan(provider: "Codex", start: now - 7200, end: now - 6900),
        ]
        lastUpdated = now
        demoActive = true
        onUpdate?()
        return true
    }

    // Usage only moves while an agent works. Idle (nothing running, popover
    // closed) → every 2 min instead of every 30s: a quarter of the API calls
    // and `codex app-server` launches, and fewer Anthropic 429s.
    private func refreshIfDue() {
        let busy = popoverShown || claudeRunning || codexRunning || devinRunning
        if !busy, let last = lastUpdated, Date().timeIntervalSince(last) < 115 { return }
        refresh()
    }

    // One refresh at a time. A slow round (Keychain prompt, CLI timeouts,
    // offline) can outlast the 30s timer; without this they'd pile up.
    private var refreshInFlight = false

    func refresh() {
        if demoActive || refreshInFlight { return }
        refreshInFlight = true
        Task {
            async let c = UsageService.fetchClaude()
            async let x = UsageService.fetchCodex()
            async let d = UsageService.fetchDevin()
            let (cl, co, dv) = await (c, x, d)
            await MainActor.run {
                self.refreshInFlight = false
                let now = Date()
                let olds = ["Claude": self.claude, "Codex": self.codex, "Devin": self.devin]
                self.claude = self.withClock(ProviderUsage.merge(cl, over: self.claude, now: now), now: now)
                self.codex = ProviderUsage.merge(co, over: self.codex, now: now)
                self.devin = ProviderUsage.merge(dv, over: self.devin, now: now)
                // A window that just reset drops tens of points in one step —
                // nothing else moves usage backwards. The cat celebrates.
                for u in [self.claude, self.codex, self.devin] where u.hasData && !u.isStale {
                    guard let old = olds[u.name] else { continue }
                    for (a, b) in [(old.session, u.session), (old.weekly, u.weekly)]
                    where (a?.usedPercent ?? 0) - (b?.usedPercent ?? 0) >= 40 {
                        self.celebrateUntil = now.addingTimeInterval(60)
                        CatSound.play(.mew)
                    }
                }
                self.lastUpdated = now
                for u in [self.claude, self.codex, self.devin] {
                    let pct = u.displayLeft, worst = u.worstUsed
                    let prevW = self.prevWorst[u.name] ?? -1
                    if let w = worst { self.prevWorst[u.name] = w }
                    if let w = worst, w >= 90, prevW < 90 {
                        let text = (pct ?? 0) <= 0 ? "limit reached" : "nearing limit"
                        self.arm(u.name, text, now: now)
                        if text == "limit reached" { CatSound.play(.sad) }
                    } else if (pct ?? 1) <= 0, self.alertText[u.name] == "nearing limit" {
                        self.arm(u.name, "limit reached", now: now)
                        CatSound.play(.sad)
                    }
                }
                let working = self.claudeRunning || self.codexRunning || self.devinRunning
                Notifier.evaluate(self.claude, others: [self.codex], active: working)
                Notifier.evaluate(self.codex, others: [self.claude], active: working)
                Notifier.evaluate(self.devin, active: working)
                self.persist(now: now)
                for u in [self.claude, self.codex, self.devin] where u.hasData && !u.isStale {
                    Notifier.evaluateSpike(u, samples: self.history[u.name] ?? [],
                                           active: working)
                }
                self.maybeStartClock(now: now)
                self.onUpdate?()
            }
        }
    }

    private func persist(now: Date) {
        let visible = [claude, codex, devin].filter(\.isVisible)
        if !visible.isEmpty { AppFiles.save(visible, to: AppFiles.usageCache) }
        var changed = false
        for u in visible where u.hasData && !u.isStale {
            let sample = UsageSample(t: now, session: u.session?.usedPercent, weekly: u.weekly?.usedPercent)
            if UsageHistory.append(sample, to: &history[u.name, default: []]) { changed = true }
        }
        if changed { AppFiles.save(history, to: AppFiles.history) }
    }

    // MARK: Session clock

    private var autoClockEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "meowbar.autoClock") == nil || d.bool(forKey: "meowbar.autoClock")
    }

    // Idle Claude session + you're at the Mac → open the 5h window now, so its
    // reset comes sooner. Retried at most every 15 min.
    private func maybeStartClock(now: Date) {
        guard autoClockEnabled, !clockStarting, !demoActive,
              SessionClock.shouldStart(session: claude.session, dataIsStale: claude.isStale,
                                       userIdleSeconds: UserPresence.idleSeconds,
                                       screenLocked: UserPresence.screenLocked,
                                       running: claudeRunning, lastAttempt: lastClockAttempt, now: now)
        else { return }
        lastClockAttempt = now
        clockStarting = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = UsageService.startClaudeClock()
            DispatchQueue.main.async {
                guard let self else { return }
                self.clockStarting = false
                if ok { UserDefaults.standard.set(Date(), forKey: "meowbar.clockStartedAt") }
                self.refresh()
            }
        }
    }

    // After MeowBar opens the window the usage API can lag (or be rate-
    // limited) — show the estimated reset until it reports the real one.
    private func withClock(_ u: ProviderUsage, now: Date) -> ProviderUsage {
        guard let started = UserDefaults.standard.object(forKey: "meowbar.clockStartedAt") as? Date,
              SessionClock.isIdle(u.session, now: now) else { return u }
        let reset = SessionClock.estimatedReset(startedAt: started)
        guard reset > now else { return u }
        var out = u
        out.session?.resetsAt = reset
        return out
    }

    private func sampleActivity() {
        guard !activityCheckInFlight else { return }
        activityCheckInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let activity = UsageService.activeCLIs()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activityCheckInFlight = false
                let now = Date()
                for sample in [("Claude", activity.claude),
                               ("Codex", activity.codex),
                               ("Devin", activity.devin)] {
                    let wasRunning = self.confirmedRunning[sample.0] == true
                    if self.recordActivity(for: sample.0, isBusy: sample.1) {
                        // The run just ended — bank the span for today's stats.
                        if let st = self.taskStart[sample.0],
                           TaskStats.append(TaskSpan(provider: sample.0, start: st, end: now),
                                            to: &self.taskSpans) {
                            AppFiles.save(self.taskSpans, to: AppFiles.taskLog)
                        }
                        self.taskStart[sample.0] = nil
                        self.arm(sample.0, "task done", now: now)
                        CatSound.play(.done)
                        self.refresh() // the finished task just moved the numbers
                    } else if !wasRunning, self.confirmedRunning[sample.0] == true,
                              self.taskStart[sample.0] == nil {
                        self.taskStart[sample.0] = now
                    }
                    if !wasRunning, self.confirmedRunning[sample.0] == true,
                              (self.alertUntil[sample.0] ?? .distantPast) <= now {
                        // A blip, not a badge: "running" lands when work starts
                        // and fades on its own — no fade-pulse, it's not an alert.
                        self.alertText[sample.0] = "running"
                        self.alertUntil[sample.0] = now.addingTimeInterval(self.alertTTL)
                        self.alertArmedAt[sample.0] = now
                        self.kickStatusAnimation()
                    }
                }
                if let last = activity.devinLastActive, last != self.devinLastActive {
                    self.devinLastActive = last
                }
                // Publish only changes: every assignment re-renders the
                // popover's view graph, even while it's closed.
                let c = self.confirmedRunning["Claude"] == true
                let x = self.confirmedRunning["Codex"] == true
                let d = self.confirmedRunning["Devin"] == true
                if self.claudeRunning != c { self.claudeRunning = c }
                if self.codexRunning != x { self.codexRunning = x }
                if self.devinRunning != d { self.devinRunning = d }
                if self.popoverShown && (c || x || d) { self.liveTick = now }
                self.onUpdate?()
            }
        }
    }

    private func recordActivity(for name: String, isBusy: Bool) -> Bool {
        if isBusy {
            busySamples[name, default: 0] += 1
            idleSamples[name] = 0
            if busySamples[name, default: 0] >= 2 { confirmedRunning[name] = true }
            return false
        }

        busySamples[name] = 0
        guard confirmedRunning[name] == true else {
            idleSamples[name] = 0
            return false
        }
        idleSamples[name, default: 0] += 1
        guard idleSamples[name, default: 0] >= 3 else { return false }
        confirmedRunning[name] = false
        idleSamples[name] = 0
        return true
    }

    private func arm(_ name: String, _ text: String, now: Date) {
        alertText[name] = text
        alertUntil[name] = now.addingTimeInterval(alertTTL)
        alertArmedAt[name] = now
        kickStatusAnimation()
        onAlert?()
    }

    // Status letters ride a two-wave curve: each fades in while rising ~1.5pt
    // on an ease-out settle, holds fully formed, then sinks out left-to-right.
    // A 60fps timer exists only while a letter is actually mid-flight; during
    // the static hold a one-shot wake resumes motion exactly at the outro.
    private static let letterStagger: TimeInterval = 0.024
    private static let letterFade: TimeInterval = 0.26
    private static let outroStagger: TimeInterval = 0.018
    private static let outroFade: TimeInterval = 0.2
    private static let letterRise: CGFloat = 1.6
    private static let letterSink: CGFloat = 0.9
    private static let statusFont = NSFont.systemFont(
        ofSize: NSFont.smallSystemFontSize - 2, weight: .medium)

    private static func clamp01(_ x: TimeInterval) -> Double { min(1, max(0, x)) }

    // Any live status mid-flight? If not but one is holding, when does the
    // earliest outro begin — the wake that resumes the 60fps timer.
    private func statusMotion(now: Date) -> (moving: Bool, wake: Date?) {
        var moving = false
        var wake: Date?
        for (name, text) in alertText {
            guard let until = alertUntil[name], until > now,
                  let armed = alertArmedAt[name] else { continue }
            let n = Double(max(0, text.count - 1))
            let introEnd = armed.addingTimeInterval(
                Self.letterStagger * n + Self.letterFade)
            let outroStart = until.addingTimeInterval(
                -(Self.outroStagger * n + Self.outroFade))
            if now < introEnd || now >= outroStart { moving = true }
            else if wake == nil || outroStart < wake! { wake = outroStart }
        }
        return (moving, wake)
    }

    private func kickStatusAnimation() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard motionTimer == nil else { return }
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onFrame?()
            let (moving, wake) = self.statusMotion(now: Date())
            if !moving {
                self.motionTimer?.invalidate()
                self.motionTimer = nil
                if let wake {
                    self.wakeTimer = Timer.scheduledTimer(
                        withTimeInterval: max(0.01, wake.timeIntervalSinceNow),
                        repeats: false) { [weak self] _ in self?.kickStatusAnimation() }
                }
            }
        }
    }

    // Click = "seen it": clear all live alerts immediately.
    func acknowledgeAlerts() {
        alertText.removeAll()
        alertUntil.removeAll()
        alertArmedAt.removeAll()
        motionTimer?.invalidate()
        motionTimer = nil
        wakeTimer?.invalidate()
        wakeTimer = nil
        onUpdate?()
    }

    // Loaded once — the menu title is rebuilt every 2s.
    private var iconCache: [String: NSImage] = [:]

    private func iconImage(_ resource: String) -> NSImage? {
        if let img = iconCache[resource] { return img }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 16, height: 16)
        iconCache[resource] = img
        return img
    }


    // Per-provider visibility toggles (Settings → Menu bar). Claude & Codex
    // default on; Devin is opt-in and only qualifies when it's actually set up.
    private func shownInMenuBar(_ u: ProviderUsage) -> Bool {
        if u.name == "Devin" && !u.isVisible { return false }
        let key = "meowbar.show" + u.name
        let ud = UserDefaults.standard
        return u.name == "Devin" ? ud.bool(forKey: key)
            : (ud.object(forKey: key) == nil || ud.bool(forKey: key))
    }

    var menuTitle: NSAttributedString {
        let ud = UserDefaults.standard

        // Compact mode: the cat mark tinted by the worst window, then
        // each provider's % left in small type — the minimal readout.
        if ud.bool(forKey: "meowbar.compact") {
            let worst = [claude, codex, devin].compactMap(\.worstUsed).max()
            let catColor: NSColor = worst == nil ? .secondaryLabelColor
                : worst! >= 90 ? .systemRed : worst! >= 75 ? .systemOrange : .labelColor
            let s = NSMutableAttributedString()
            let att = NSTextAttachment()
            att.image = CatGlyph.tintedImage(
                CatGlyph.image(size: 15), catColor,
                key: "compact-\(catColor.description)")
            att.bounds = CGRect(x: 0, y: -3.4, width: 15, height: 13.8)
            s.append(NSAttributedString(attachment: att))
            s.append(NSAttributedString(string: "  "))
            let small = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            let faint = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            for (i, u) in [claude, codex, devin].filter(shownInMenuBar).enumerated() {
                if i > 0 {
                    s.append(NSAttributedString(string: " | ", attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor, .font: faint]))
                }
                let sev = u.worstUsed
                let c: NSColor = sev == nil ? .secondaryLabelColor
                    : sev! >= 90 ? .systemRed : sev! >= 75 ? .systemOrange : .labelColor
                s.append(NSAttributedString(
                    string: u.displayLeft.map { String(format: "%.0f%%", $0) }
                        ?? (u.noteAccent == "unlimited" ? "∞" : "–"),
                    attributes: [.foregroundColor: c, .font: small]))
            }
            return s
        }

        // Always keep the usage metric visible. Transient state is appended,
        // so an alert or running task never hides the useful percentage.
        func entry(_ resource: String, _ name: String, _ pct: Double?, _ sev: Double?,
                   _ resetAt: Date?, _ eta: TimeInterval?) -> NSAttributedString {
            // Freshly-reset limits glow green for a minute — a flash, not a state.
            let celebrating = (celebrateUntil ?? .distantPast) > Date()
            let color: NSColor = celebrating ? .systemGreen
                : sev == nil ? .secondaryLabelColor
                : sev! >= 90 ? .systemRed : sev! >= 75 ? .systemOrange : .labelColor
            let s = NSMutableAttributedString()
            if let img = iconImage(resource) {
                let att = NSTextAttachment()
                // Single-ink glyph in the severity color — still, like Drive's.
                att.image = CatGlyph.tintedImage(
                    img, color, key: "\(resource)-\(color.description)")
                att.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
                s.append(NSAttributedString(attachment: att))
            }

            let mode = UserDefaults.standard.string(forKey: "meowbar.displayMode") ?? "percent"
            let metric: String
            switch mode {
            case "countdown" where resetAt != nil:
                metric = Countdown.compact(to: resetAt!)
            case "eta" where eta != nil:
                metric = "~" + Countdown.compact(to: Date().addingTimeInterval(eta!))
            case "eta" where resetAt != nil:
                metric = Countdown.compact(to: resetAt!)
            case "maxed" where (sev ?? 0) >= 100 && (resetAt ?? .distantPast) > Date():
                metric = "↻ " + Countdown.compact(to: resetAt!)
            default:
                // Unlimited plans carry no windows — a ∞ reads truer than "–".
                metric = pct.map { String(format: "%.0f%%", $0) }
                    ?? (resource == "devin" && devin.noteAccent == "unlimited" ? "∞" : "–")
            }
            s.append(NSAttributedString(
                string: " " + metric,
                attributes: [
                    .foregroundColor: color,
                    // Tabular digits a touch under menu-bar size: 98% → 97%
                    // stays quiet and never nudges the item's width.
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium),
                ]))

            // Status text rides along small and brief: armed on edges only,
            // letters rise in on an ease-out wave, hold, then sink away —
            // gone in seconds, never sticks for a task.
            if let alert = alertText[name],
               let until = alertUntil[name], until > Date() {
                let statusColor: NSColor
                switch alert {
                case "task done", "running": statusColor = .systemGreen
                case "nearing limit": statusColor = .systemOrange
                default: statusColor = .systemRed
                }
                let now = Date()
                let armed = alertArmedAt[name] ?? now
                let n = max(0, alert.count - 1)
                let outroStart = until.addingTimeInterval(
                    -(Self.outroStagger * Double(n) + Self.outroFade))
                // Each letter: p = rise-in progress (ease-out), q = sink-out
                // progress (ease-in). alpha = p·(1−q), baseline drifts from
                // −rise up to 0, then eases down −sink as it leaves.
                func letterFrame(_ i: Int) -> (alpha: Double, baseline: CGFloat) {
                    let p = Self.clamp01((now.timeIntervalSince(armed)
                        - Double(i) * Self.letterStagger) / Self.letterFade)
                    let q = Self.clamp01((now.timeIntervalSince(outroStart)
                        - Double(i) * Self.outroStagger) / Self.outroFade)
                    return ((1 - (1 - p) * (1 - p) * (1 - p)) * (1 - q * q),
                            (1 - p * (2 - p)) * -Self.letterRise - q * q * Self.letterSink)
                }
                let head = letterFrame(0)
                s.append(NSAttributedString(string: " · ", attributes: [
                    .foregroundColor: statusColor.withAlphaComponent(head.alpha),
                    .font: Self.statusFont]))
                for (i, ch) in alert.enumerated() {
                    let f = letterFrame(i)
                    s.append(NSAttributedString(string: String(ch), attributes: [
                        .foregroundColor: statusColor.withAlphaComponent(f.alpha),
                        .baselineOffset: f.baseline,
                        .font: Self.statusFont]))
                }
            }
            return s
        }
        let t = NSMutableAttributedString()
        var entries: [(String, String, ProviderUsage)] = []
        if shownInMenuBar(claude) { entries.append(("claude", "Claude", claude)) }
        if shownInMenuBar(codex) { entries.append(("codex", "Codex", codex)) }
        if shownInMenuBar(devin) { entries.append(("devin", "Devin", devin)) }
        if entries.isEmpty {
            // Everything hidden: keep the cat so the item isn't an empty gap.
            let att = NSTextAttachment()
            att.image = CatGlyph.tintedImage(CatGlyph.image(size: 15), .labelColor, key: "bar-cat")
            att.bounds = CGRect(x: 0, y: -3.4, width: 15, height: 13.8)
            t.append(NSAttributedString(attachment: att))
            return t
        }
        for (i, e) in entries.enumerated() {
            if i > 0 {
                t.append(NSAttributedString(string: "  ·  ", attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)]))
            }
            t.append(entry(e.0, e.1, e.2.displayLeft, e.2.worstUsed,
                           e.2.displayReset, e.2.displayTimeToEmpty))
        }
        return t
    }

    var menuToolTip: String {
        func line(_ u: ProviderUsage) -> String {
            func lbl(_ w: UsageWindow?) -> String? {
                guard let w else { return nil }
                let span = (w.windowSeconds ?? 0) >= 86400 ? "1d" : "\(Int((w.windowSeconds ?? 18000) / 3600))h"
                return String(format: "%@ %.0f%% left", span, 100 - w.usedPercent)
            }
            var nums = [lbl(u.session), lbl(u.weekly)].compactMap { $0 }
            for e in u.extras ?? [] {
                nums.append("\(e.label.lowercased()) \(Int(max(0, 100 - e.window.usedPercent)))% left")
            }
            let numsJoined = nums.joined(separator: " · ")
            // No metered windows (Devin unlimited, errors) → reuse shareLine's
            // fallbacks ("Pro unlimited", the error) instead of "…".
            return numsJoined.isEmpty ? u.shareLine() : "\(u.name): " + numsJoined
        }
        return [claude, codex, devin].filter(shownInMenuBar).map(line).joined(separator: "    ")
    }
}

// Real cat sounds, three moments: a meow when a limit window resets, a
// short meow when an agent's task finishes, a sad mewl when a limit maxes.
// All off by default (Settings → Alerts).
enum CatSound {
    enum Kind: String {
        case mew = "meowbar.meowSound"
        case done = "meowbar.purrSound"
        case sad = "meowbar.sadSound"
        var resource: String {
            switch self {
            case .mew: return "cat-meow"
            case .done: return "meow"
            case .sad: return "sad-cat"
            }
        }
    }
    private static var sounds: [Kind: NSSound] = [:]

    static func play(_ kind: Kind) {
        guard UserDefaults.standard.bool(forKey: kind.rawValue) else { return }
        if sounds[kind] == nil {
            sounds[kind] = Bundle.main.url(forResource: kind.resource, withExtension: "mp3")
                .flatMap { NSSound(contentsOf: $0, byReference: false) }
        }
        sounds[kind]?.play()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    // True from the start of a close until popoverDidClose. AppKit's close
    // transaction outlasts the visible zoom-out by ~0.4s (see togglePopover).
    private var popoverClosing = false
    private var reopenAfterClose = false
    // The view the popover's arrow points at: the status button, or the
    // island capsule in "middle" mode.
    private weak var popoverAnchor: NSView?
    let store = UsageStore()
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let hotKey = HotKey()
    private var islandPanel: NSPanel?
    private var islandField: NSTextField?
    private var islandExpanded = false
    private var islandAnimating = false
    private var islandCollapseWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐱"
        statusItem.button?.toolTip = "Claude / Codex usage"
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Dismissal is managed explicitly below (outside clicks, keys,
        // sleep/lock, display changes).
        popover.behavior = .applicationDefined
        // AppKit's own animation zooms the whole surface — glass, arrow and
        // shadow — out of the menu-bar item and back into it. Don't replace
        // it with a snapshot morph: the glass is composited by the window
        // server, so a snapshot holds only bare text floating on the desktop.
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(store: store) { [weak self] size in
            self?.fitPopover(to: size)
        })
        // Sized by fitPopover, not .preferredContentSize: AppKit applies that
        // in one frame while SwiftUI animates the layout over 0.25s, so the
        // glass edge jumped and the content was clipped mid-expand.
        host.sizingOptions = []
        popover.contentViewController = host

        store.onUpdate = { [weak self] in
            guard let self else { return }
            let title = self.store.menuTitle
            self.statusItem.button?.attributedTitle = title
            self.statusItem.button?.toolTip = self.store.menuToolTip
            self.statusItem.button?.setAccessibilityLabel("MeowBar. " + self.store.menuToolTip)
            self.layoutIsland(title: title)
        }
        // Animation ticks: rebuild the title but skip tooltip/a11y — those
        // only change on real state updates, not mid-frame.
        store.onFrame = { [weak self] in
            guard let self else { return }
            let title = self.store.menuTitle
            self.statusItem.button?.attributedTitle = title
            self.layoutIsland(title: title)
        }
        store.onAlert = { [weak self] in self?.flashMenuItem() }
        // First run explains the Keychain prompt before anything triggers it.
        if UserDefaults.standard.bool(forKey: "meowbar.onboarded")
            || ProcessInfo.processInfo.environment["MEOWBAR_DEMO"] != nil {
            beginMonitoring()
        } else {
            showOnboarding()
        }

        applyPosition()
        applyHotKey()

        // Screenshot aid: float the popover mid-screen (MEOWBAR_POPOVER_SHOT).
        if ProcessInfo.processInfo.environment["MEOWBAR_POPOVER_SHOT"] != nil {
            PopoverShot.show()
        }
        // Sound test: MEOWBAR_MEOW=1 plays once through the real code path
        // (needs the Settings toggle on, like a real reset).
        if ProcessInfo.processInfo.environment["MEOWBAR_MEOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { CatSound.play(.mew) }
        }
        // Screenshot aid: open the real Settings window (MEOWBAR_SETTINGS_SHOT).
        if ProcessInfo.processInfo.environment["MEOWBAR_SETTINGS_SHOT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.openSettings() }
        }
        // Motion QA: open, close, then reopen through the real status-item
        // anchor so a short screen recording can inspect every keyframe.
        if ProcessInfo.processInfo.environment["MEOWBAR_MOTION_DEMO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.togglePopover() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.closePopover() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) { self.togglePopover() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) { self.closePopover() }
        }
        NotificationCenter.default.addObserver(forName: .meowbarSettingsChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyPosition()
            self?.applyHotKey()
            self?.store.onUpdate?()
            self?.store.refresh()
        }
        NotificationCenter.default.addObserver(forName: .init("meowbar.openSettings"),
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.closePopover()
            self.openSettings()
        }
        NotificationCenter.default.addObserver(forName: .init("meowbar.checkUpdates"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.store.checkForUpdate()
        }
        NotificationCenter.default.addObserver(forName: .init("meowbar.openAbout"),
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.closePopover()
            self.openAbout()
        }

        // .transient is unreliable for accessory apps — explicitly close on
        // any outside click while the popover is up. Recent macOS also routes
        // clicks on our own status item through here; those belong to
        // togglePopover, or one click would close and toggle at once.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            if self.statusItem.button?.window?.frame.contains(p) == true
                || (self.islandPanel?.isVisible == true && self.islandPanel?.frame.contains(p) == true) {
                return
            }
            if self.clearOrphanedPopover() { return }
            self.closePopover()
        }
        // Global monitors don't see clicks delivered to our own Settings or
        // About windows. With application-defined popover behavior, close on
        // those local clicks too while leaving the popover and its menus alone.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.window === self.popoverWindow
                || event.window === self.statusItem.button?.window
                || event.window === self.islandPanel
                || event.window?.level == .popUpMenu {
                return event
            }
            self.closePopover()
            return event
        }
        // A popover left open across sleep, screen lock or a display change
        // can lose its anchor: AppKit then reports it closed while its window
        // stays on screen, deaf to clicks. Close it first, like system menus.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.dismissPopover()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.dismissPopover()
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.dismissPopover()
        }
        // Popover never takes key (battery-menu behavior) — typing goes to
        // whatever app you're in. This only fires while we're key anyway
        // (e.g. Settings open), in which case the action keys below run and
        // any other key dismisses the popover, as before.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.clearOrphanedPopover() { return nil }
            guard self.popover.isShown else { return event }
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               let key = event.charactersIgnoringModifiers?.lowercased() {
                switch key {
                case "r":
                    self.store.refresh()
                    return nil
                case "q":
                    NSApp.terminate(nil)
                    return nil
                case ",":
                    self.closePopover()
                    self.openSettings()
                    return nil
                case "1", "2", "3":
                    NotificationCenter.default.post(name: .init("meowbar.toggleProvider"), object: key)
                    return nil
                default:
                    break
                }
            }
            self.closePopover()
            return nil
        }

        // The status item changes width constantly (" · running", alerts,
        // countdown text, and acknowledging an alert on click). The bar moves
        // the item's window a beat after the button resizes, and NSPopover
        // doesn't follow — the arrow ends up pointing at empty menu bar.
        // Re-anchor whenever the anchor's window moves or resizes.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil,
                                                   queue: .main) { [weak self] note in
                guard let self, let anchor = self.popoverAnchor, self.popover.isShown,
                      (note.object as? NSWindow) === anchor.window else { return }
                self.popover.positioningRect = anchor.bounds
            }
        }
    }

    private func beginMonitoring() {
        store.start()
        Notifier.requestPermission()
    }

    private func applyHotKey() {
        let id = UserDefaults.standard.string(forKey: "meowbar.hotkey") ?? HotKey.defaultID
        hotKey.register(id: id) { [weak self] in self?.togglePopover() }
    }

    // MARK: Onboarding (first launch only)

    private func showOnboarding() {
        let view = OnboardingView { [weak self] choices in self?.finishOnboarding(choices) }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Welcome to MeowBar"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        onboardingWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // nil = closed without "Get started": start with defaults, change nothing.
    private func finishOnboarding(_ choices: OnboardingView.Choices?) {
        guard !UserDefaults.standard.bool(forKey: "meowbar.onboarded") else { return }
        UserDefaults.standard.set(true, forKey: "meowbar.onboarded")
        if let choices {
            UserDefaults.standard.set(choices.autoClock, forKey: "meowbar.autoClock")
            if choices.alwaysFresh { try? StatuslineBridge.install() }
            if choices.launchAtLogin {
                try? SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "meowbar.launchAtLogin")
            }
        }
        let w = onboardingWindow
        onboardingWindow = nil
        w?.close()
        beginMonitoring()
    }

    // MARK: Settings window

    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            let w = NSWindow(contentViewController: host)
            w.title = "MeowBar Settings"
            w.styleMask = [.titled, .closable]
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.level = .floating
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            w.title = "About MeowBar"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.level = .floating
            aboutWindow = w
        }
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Positions — right (status item) or middle ("island" at top edge)

    func applyPosition() {
        let pos = UserDefaults.standard.string(forKey: "meowbar.position") ?? "right"
        if pos == "middle" {
            statusItem.isVisible = false
            showIsland()
        } else {
            islandPanel?.orderOut(nil)
            statusItem.isVisible = true
        }
        store.onUpdate?()
    }

    private func showIsland() {
        if islandPanel == nil {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar            // draws over the menu bar region
            p.isFloatingPanel = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false

            let bg = IslandView()
            bg.onClick = { [weak self] in self?.togglePopover() }
            bg.onRightClick = { [weak self] in
                guard let self else { return }
                self.dismissPopover()
                self.showStatusMenu(in: self.islandPanel?.contentView)
            }
            bg.onHoverChange = { [weak self] inside in self?.islandHover(inside) }
            let tf = NSTextField(labelWithAttributedString: NSAttributedString())
            tf.drawsBackground = false
            tf.alphaValue = 0
            bg.addSubview(tf)
            p.contentView = bg
            islandPanel = p
            islandField = tf
            bg.setContentVisible(false, animated: false)
        }
        islandPanel?.orderFrontRegardless()
        layoutIsland()
    }

    // The notch band + width: auxiliaryTopLeft/RightArea are the menu-bar
    // strips beside the camera housing, so the gap between them IS the
    // notch. Fall back to a plausible width on notch-free screens.
    private struct IslandGeometry { let cx: CGFloat, notchW: CGFloat, drop: CGFloat }
    private func islandGeometry(_ screen: NSScreen) -> IslandGeometry {
        let drop = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        var w: CGFloat = 190, cx = screen.frame.midX
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea,
           r.minX - l.maxX > 40 {
            w = r.minX - l.maxX
            cx = l.maxX + w / 2
        }
        return IslandGeometry(cx: cx, notchW: w, drop: drop)
    }

    // The panel always reaches up to the screen's top edge: the band region
    // is transparent and acts as the hover target over the notch itself,
    // while the visible black body hangs below the band (islandFrame only
    // sizes the window — IslandView draws the body in the lower part).
    private func islandFrame(expanded: Bool, screen: NSScreen, g: IslandGeometry) -> NSRect {
        let top = screen.frame.maxY
        if expanded {
            let textW = islandField?.fittingSize.width ?? 0
            let w = max(g.notchW + 16, textW + 24 + 17)
            let h = g.drop + 30
            return NSRect(x: g.cx - w / 2, y: top - h, width: w, height: h)
        }
        let h = g.drop + 10
        return NSRect(x: g.cx - g.notchW / 2, y: top - h, width: g.notchW, height: h)
    }

    private func islandHover(_ inside: Bool) {
        islandCollapseWork?.cancel()
        islandCollapseWork = nil
        if inside {
            setIslandExpanded(true)
            return
        }
        // Re-check after a beat: an exit can fire spuriously while the panel
        // shrinks under the cursor, and an open popover pins it expanded.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.islandPanel, p.isVisible else { return }
            if !p.frame.contains(NSEvent.mouseLocation), !self.popover.isShown {
                self.setIslandExpanded(false)
            }
        }
        islandCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func setIslandExpanded(_ expanded: Bool) {
        guard expanded != islandExpanded, let p = islandPanel, p.isVisible,
              let screen = NSScreen.main else { return }
        islandExpanded = expanded
        islandCollapseWork?.cancel()
        islandCollapseWork = nil
        let g = islandGeometry(screen)
        let target = islandFrame(expanded: expanded, screen: screen, g: g)
        islandAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = expanded ? 0.25 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: expanded ? .easeOut : .easeIn)
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(target, display: true)
            self.islandField?.animator().alphaValue = expanded ? 1 : 0
        }, completionHandler: { [weak self] in
            self?.islandAnimating = false
            self?.layoutIsland()
        })
        (p.contentView as? IslandView)?.setContentVisible(expanded, animated: true)
    }

    private func layoutIsland(title prebuilt: NSAttributedString? = nil) {
        guard let p = islandPanel, let tf = islandField,
              let screen = NSScreen.main, p.isVisible else { return }
        let bg = p.contentView as? IslandView
        let title = prebuilt ?? store.menuTitle
        tf.attributedStringValue = title
        tf.sizeToFit() // attributed .size() under-measures image attachments
        let g = islandGeometry(screen)
        bg?.bandHeight = g.drop
        if !islandAnimating {
            let target = islandFrame(expanded: islandExpanded, screen: screen, g: g)
            if !p.frame.equalTo(target) { p.setFrame(target, display: true) }
            tf.alphaValue = islandExpanded ? 1 : 0
            bg?.setContentVisible(islandExpanded, animated: false)
        }
        let bodyH = p.frame.height - g.drop
        let sz = tf.fittingSize
        tf.frame = NSRect(x: 29, y: (bodyH - sz.height) / 2,
                          width: sz.width, height: sz.height)
        bg?.showCat(true)
        bg?.setSeverity([store.claude, store.codex, store.devin].compactMap(\.worstUsed).max())
    }

    private var popoverWindow: NSWindow? { popover.contentViewController?.view.window }

    // AppKit says closed but the window is still up (anchor lost) — take it
    // down. True if there was one: the click that found it was a "close".
    @discardableResult
    private func clearOrphanedPopover() -> Bool {
        guard !popover.isShown, let w = popoverWindow, w.isVisible else { return false }
        w.orderOut(nil)
        store.popoverShown = false
        return true
    }

    // Immediate close (no animation) for sleep, lock and display changes.
    private func dismissPopover() {
        reopenAfterClose = false
        if popover.isShown { closePopover(animated: false) }
        clearOrphanedPopover()
        store.popoverShown = false
    }

    // Left click toggles the popover; right click gets the classic menu —
    // same items as the gear menu, for people who never open the popover.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            dismissPopover()
            showStatusMenu(in: statusItem.button)
            return
        }
        togglePopover()
    }

    private func showStatusMenu(in view: NSView?) {
        guard let view else { return }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            return i
        }
        let head = NSMenuItem(title: "MeowBar \(UpdateCheck.currentVersion)",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", #selector(menuRefresh)))
        menu.addItem(item("About MeowBar", #selector(menuAbout)))
        menu.addItem(item("Settings…", #selector(menuSettings)))
        if let update = store.update, UpdateCheck.downloadURL(update) != nil {
            menu.addItem(.separator())
            menu.addItem(item("Download MeowBar \(update.version)…", #selector(menuDownloadUpdate)))
        } else if UpdateCheck.feedURL != nil {
            menu.addItem(item("Check for Updates…", #selector(menuCheckUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit MeowBar", #selector(menuQuit)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }

    @objc private func menuRefresh() { store.refresh() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuAbout() { openAbout() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuCheckUpdates() { store.checkForUpdate() }
    @objc private func menuDownloadUpdate() {
        guard let update = store.update, let url = UpdateCheck.downloadURL(update) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func togglePopover() {
        if clearOrphanedPopover() { return }
        if popover.isShown {
            if popoverClosing {
                // The zoom-out is over in ~0.1s, but AppKit keeps isShown
                // true until didClose ~0.5s later and won't show before then.
                // A click in that gap means "open": do it once the close lands.
                reopenAfterClose = true
            } else {
                closePopover()
            }
            return
        }
        store.acknowledgeAlerts()
        store.refresh()
        if let bg = islandPanel?.contentView as? IslandView, islandPanel?.isVisible == true {
            // Anchor to the black body, not the hover strip — the arrow
            // should point at the island, not the notch band above it.
            popoverAnchor = bg.body
            setIslandExpanded(true)
        } else {
            popoverAnchor = statusItem.button
        }
        // Open at the right size: while closed, nothing re-measures the view.
        if let host = popover.contentViewController as? NSHostingController<PopoverView> {
            fitPopover(to: host.sizeThatFits(in: NSSize(width: 0, height: 0)))
        }
        if let anchor = popoverAnchor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        // The popover window is a non-activating panel: makeKey() gives it
        // key status WITHOUT activating our app — the front app keeps its
        // menus and colored traffic lights. Key status matters because
        // Tahoe glass (NSGlassView) and vibrant text render washed-out in
        // non-key windows, and there's no .active override for them.
        // Cost: a keystroke typed while the popover is open goes to us —
        // the local monitor below dismisses the popover on it.
        popover.contentViewController?.view.window?.makeKey()
    }

    // Animated: AppKit zooms the popover back into its anchor, isShown
    // staying true until popoverDidClose. Unanimated: gone this instant,
    // for sleep, lock and display changes.
    private func closePopover(animated: Bool = true) {
        guard popover.isShown else { return }
        if animated {
            guard !popoverClosing else { return }
            popoverClosing = true
            popover.performClose(nil)
        } else {
            popover.animates = false
            popover.close()
            popover.animates = true
        }
    }

    // While open, glide to a new size on the curve SwiftUI animates the
    // layout with (PopoverMotion), so the glass edge and content move as one.
    private func fitPopover(to size: NSSize) {
        guard size.width > 0, size.height > 0, size != popover.contentSize else { return }
        guard popover.isShown, !popoverClosing,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            popover.contentSize = size
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PopoverMotion.duration
            context.timingFunction = PopoverMotion.timingFunction
            context.allowsImplicitAnimation = true
            popover.contentSize = size
        }
    }

    // Triple fade-pulse on the status item (and island) so a new alert —
    // "task done", "limit reached" — catches the eye without a banner.
    private func flashMenuItem() {
        func pulse(_ view: NSView?) {
            guard let view else { return }
            view.wantsLayer = true
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0
            a.toValue = 0.25
            a.duration = 0.3
            a.autoreverses = true
            a.repeatCount = 3
            view.layer?.add(a, forKey: "meowbar.flash")
        }
        pulse(statusItem.button)
        pulse(islandPanel?.contentView)
    }

}

// The island view. The panel is taller than what draws: the top `bandHeight`
// points are a transparent hover strip over the notch/menu bar, and `body` —
// a black slab rounded only at the bottom — hangs below it so at rest it
// reads as a chin on the notch itself. Everything inside is forced dark so
// the label colors resolve to light-on-black.
private final class IslandView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    // Height of the transparent band above the body (notch/menu-bar strip).
    var bandHeight: CGFloat = 24
    let body = NSView()
    // A hairline under the text tinted by the worst window across providers:
    // the island alone tells you someone is near a limit.
    private let severityBar = NSView()
    private var catView: NSImageView?
    private let bodyMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor.black.cgColor
        body.layer?.mask = bodyMask
        addSubview(body)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        severityBar.wantsLayer = true
        severityBar.layer?.cornerRadius = 1
        severityBar.isHidden = true
        body.addSubview(severityBar)
    }

    required init?(coder: NSCoder) { fatalError() }

    // severity: worst used% across providers (nil → hide the line).
    func setSeverity(_ worst: Double?) {
        guard let worst else {
            severityBar.isHidden = true
            return
        }
        severityBar.isHidden = false
        severityBar.layer?.backgroundColor = (worst >= 90 ? NSColor.systemRed
            : worst >= 75 ? NSColor.systemOrange
            : NSColor.white.withAlphaComponent(0.4)).cgColor
    }

    // Cat mark at the island's leading edge, tinted like the text.
    func showCat(_ show: Bool) {
        if show && catView == nil {
            let img = CatGlyph.image(size: 15)
            let iv = NSImageView(image: img)
            iv.contentTintColor = .secondaryLabelColor
            body.addSubview(iv)
            catView = iv
        }
        catView?.isHidden = !show
    }

    // Text/cat/severity only exist in the expanded state — collapse fades
    // them rather than clipping mid-shrink.
    func setContentVisible(_ visible: Bool, animated: Bool) {
        let a: CGFloat = visible ? 1 : 0
        guard animated else {
            severityBar.alphaValue = a
            catView?.alphaValue = a
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.22 : 0.1
            severityBar.animator().alphaValue = a
            self.catView?.animator().alphaValue = a
        }
    }

    // Square top, rounded bottom: the body's top edge abuts the notch's
    // bottom edge, so rounding there would show daylight between them.
    private func updateBodyMask() {
        let b = body.bounds
        let r = min(11, b.height / 2, b.width / 2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: b.height))
        p.addLine(to: CGPoint(x: b.width, y: b.height))
        p.addLine(to: CGPoint(x: b.width, y: r))
        p.addArc(center: CGPoint(x: b.width - r, y: r), radius: r,
                 startAngle: 0, endAngle: -.pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: r, y: 0))
        p.addArc(center: CGPoint(x: r, y: r), radius: r,
                 startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
        p.closeSubpath()
        bodyMask.path = p
    }

    override func layout() {
        super.layout()
        // The body fills the whole view, band included: the part that lands
        // inside the physical notch cutout is invisible, so expanding reads
        // as the notch itself swelling down and sideways — not a pill below.
        body.frame = bounds
        updateBodyMask()
        // Content still lives in the below-band region — anything higher is
        // inside the notch cutout where it can't be seen.
        let h = max(0, body.bounds.height - bandHeight)
        severityBar.frame = NSRect(x: 10, y: 2.5, width: body.bounds.width - 20, height: 1.5)
        if let catView { catView.frame = NSRect(x: 9, y: (h - 12) / 2, width: 14, height: 12) }
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1 { onClick?() }
    }
    override func rightMouseUp(with event: NSEvent) { onRightClick?() }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === onboardingWindow { finishOnboarding(nil) }
    }
}

// No detaching: a click with a few pixels of drag turned the popover into a
// window, and afterwards AppKit left the popover's own window at alpha 0 —
// every later click showed it invisibly and it closed itself.
extension AppDelegate: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        store.popoverShown = true
    }

    func popoverDidShow(_ notification: Notification) {
        // Belt and braces: never leave a shown popover transparent.
        if let w = popover.contentViewController?.view.window, w.alphaValue < 1 {
            w.alphaValue = 1
        }
    }

    func popoverWillClose(_ notification: Notification) {
        popoverClosing = true
    }

    func popoverDidClose(_ notification: Notification) {
        store.popoverShown = false
        popoverClosing = false
        if let p = islandPanel, p.isVisible, !p.frame.contains(NSEvent.mouseLocation) {
            setIslandExpanded(false)
        }
        if reopenAfterClose {
            reopenAfterClose = false
            togglePopover()
        }
    }
}

// MeowBar talks to child processes over pipes; a write to one that just
// died must surface as an error, not kill the app (SIGPIPE's default).
signal(SIGPIPE, SIG_IGN)

// `MeowBar --json` prints the last-good numbers and exits (no UI).
if CommandLine.arguments.contains("--json") {
    exit(UsageJSON.printCached() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
