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
    @Published var lastUpdated: Date?
    @Published var history: [String: [UsageSample]] = [:]
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
    private var timer: Timer?
    private var activityTimer: Timer?
    private var updateTimer: Timer?
    private var lastClockAttempt: Date?
    private var activityCheckInFlight = false
    // Transient menu-bar alerts: armed on state edges (task finished, limit
    // reached), auto-clear after alertTTL or instantly on click.
    private var alertText: [String: String] = [:]
    private var alertUntil: [String: Date] = [:]
    // A CPU spike is not a task. Rapid samples let IDE-hosted agents appear as
    // running promptly, while confirmation in both directions filters helper
    // startup and prevents false "task done" messages.
    private var busySamples: [String: Int] = [:]
    private var idleSamples: [String: Int] = [:]
    private var confirmedRunning: [String: Bool] = [:]
    private var prevWorst: [String: Double] = [:]
    private let alertTTL: TimeInterval = 15
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
                    }
                }
                self.lastUpdated = now
                for u in [self.claude, self.codex, self.devin] {
                    let pct = u.displayLeft, worst = u.worstUsed
                    let prevW = self.prevWorst[u.name] ?? -1
                    if let w = worst { self.prevWorst[u.name] = w }
                    if let w = worst, w >= 90, prevW < 90 {
                        self.arm(u.name, (pct ?? 0) <= 0 ? "limit reached" : "nearing limit", now: now)
                    } else if (pct ?? 1) <= 0, self.alertText[u.name] == "nearing limit" {
                        self.arm(u.name, "limit reached", now: now)
                    }
                }
                Notifier.evaluate(self.claude, others: [self.codex])
                Notifier.evaluate(self.codex, others: [self.claude])
                Notifier.evaluate(self.devin)
                self.persist(now: now)
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
                    if self.recordActivity(for: sample.0, isBusy: sample.1) {
                        self.arm(sample.0, "task done", now: now)
                        self.refresh() // the finished task just moved the numbers
                    }
                }
                // Publish only changes: every assignment re-renders the
                // popover's view graph, even while it's closed.
                let c = self.confirmedRunning["Claude"] == true
                let x = self.confirmedRunning["Codex"] == true
                let d = self.confirmedRunning["Devin"] == true
                if self.claudeRunning != c { self.claudeRunning = c }
                if self.codexRunning != x { self.codexRunning = x }
                if self.devinRunning != d { self.devinRunning = d }
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
        onAlert?()
    }

    // Click = "seen it": clear all live alerts immediately.
    func acknowledgeAlerts() {
        alertText.removeAll()
        alertUntil.removeAll()
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

    var menuTitle: NSAttributedString {
        // Always keep the usage metric visible. Transient state is appended,
        // so an alert or running task never hides the useful percentage.
        func entry(_ resource: String, _ name: String, _ pct: Double?, _ sev: Double?,
                   _ resetAt: Date?, _ running: Bool) -> NSAttributedString {
            let color: NSColor = sev == nil ? .secondaryLabelColor
                : sev! >= 90 ? .systemRed : sev! >= 75 ? .systemOrange : .labelColor
            let s = NSMutableAttributedString()
            if let img = iconImage(resource) {
                let att = NSTextAttachment()
                att.image = img
                att.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
                s.append(NSAttributedString(attachment: att))
            }

            let mode = UserDefaults.standard.string(forKey: "meowbar.displayMode") ?? "percent"
            let metric: String
            if mode == "countdown", let reset = resetAt {
                metric = Countdown.compact(to: reset)
            } else {
                metric = pct.map { String(format: "%.0f%%", $0) } ?? "–"
            }
            s.append(NSAttributedString(
                string: " " + metric,
                attributes: [
                    .foregroundColor: color,
                    // Tabular digits: 98% → 97% shouldn't nudge the item's width.
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                ]))

            let status: String?
            let statusColor: NSColor
            if let alert = alertText[name], (alertUntil[name] ?? .distantPast) > Date() {
                status = alert
                switch alert {
                case "task done": statusColor = .systemGreen
                case "nearing limit": statusColor = .systemOrange
                default: statusColor = .systemRed
                }
            } else if running {
                status = "running"
                statusColor = .systemGreen
            } else {
                status = nil
                statusColor = .labelColor
            }
            if let status {
                s.append(NSAttributedString(
                    string: " · \(status)",
                    attributes: [
                        .foregroundColor: statusColor,
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                    ]))
            }
            return s
        }
        let t = NSMutableAttributedString()
        t.append(entry("claude", "Claude", claude.displayLeft, claude.worstUsed,
                       claude.displayReset, claudeRunning))
        t.append(NSAttributedString(string: "   "))
        t.append(entry("codex", "Codex", codex.displayLeft, codex.worstUsed,
                       codex.displayReset, codexRunning))
        return t
    }

    var menuToolTip: String {
        func line(_ u: ProviderUsage) -> String {
            func lbl(_ w: UsageWindow?) -> String? {
                guard let w else { return nil }
                let span = (w.windowSeconds ?? 0) >= 86400 ? "1d" : "\(Int((w.windowSeconds ?? 18000) / 3600))h"
                return String(format: "%@ %.0f%% left", span, 100 - w.usedPercent)
            }
            let nums = [lbl(u.session), lbl(u.weekly)].compactMap { $0 }.joined(separator: " · ")
            return "\(u.name): " + (nums.isEmpty ? (u.error ?? "…") : nums)
        }
        return [line(claude), line(codex)].joined(separator: "    ")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    // Clicking the status item while the popover is open can auto-dismiss it
    // AND fire the action — without this guard the click reopens instead of
    // closing. 0.4s is below human double-tap speed for a deliberate reopen.
    private var popoverClosedAt = Date.distantPast
    // The close animation runs ~0.5s with isShown still true. If an outside
    // click started it and you then click the bar, that click means "open".
    private var popoverClosing = false
    private var closedByOutsideClick = false
    private var reopenAfterClose = false
    // The view the popover's arrow points at: the status button, or the
    // island capsule in "middle" mode.
    private weak var popoverAnchor: NSView?
    let store = UsageStore()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let hotKey = HotKey()
    private var islandPanel: NSPanel?
    private var islandField: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐱"
        statusItem.button?.toolTip = "Claude / Codex usage"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .semitransient
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        store.onUpdate = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.attributedTitle = self.store.menuTitle
            self.statusItem.button?.toolTip = self.store.menuToolTip
            self.statusItem.button?.setAccessibilityLabel("MeowBar. " + self.store.menuToolTip)
            self.layoutIsland()
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
        NotificationCenter.default.addObserver(forName: .meowbarSettingsChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyPosition()
            self?.applyHotKey()
            self?.store.onUpdate?()
            self?.store.refresh()
        }
        NotificationCenter.default.addObserver(forName: .init("meowbar.openSettings"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }
        NotificationCenter.default.addObserver(forName: .init("meowbar.checkUpdates"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.store.checkForUpdate()
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
            guard self.popover.isShown else { return }
            if !self.popoverClosing { self.closedByOutsideClick = true }
            self.popover.performClose(nil)
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
                    self.popover.performClose(nil)
                    self.openSettings()
                    return nil
                case "1", "2", "3":
                    NotificationCenter.default.post(name: .init("meowbar.toggleProvider"), object: key)
                    return nil
                default:
                    break
                }
            }
            self.popover.performClose(nil)
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
            w.isReleasedWhenClosed = false
            w.level = .floating
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
            let tf = NSTextField(labelWithAttributedString: NSAttributedString())
            tf.drawsBackground = false
            bg.addSubview(tf)
            p.contentView = bg
            islandPanel = p
            islandField = tf
        }
        islandPanel?.orderFrontRegardless()
        layoutIsland()
    }

    private func layoutIsland() {
        guard let p = islandPanel, let tf = islandField,
              let screen = NSScreen.main, p.isVisible else { return }
        let title = store.menuTitle
        tf.attributedStringValue = title
        tf.sizeToFit() // attributed .size() under-measures image attachments
        let sz = tf.fittingSize
        let pad: CGFloat = 12, h: CGFloat = 26
        let w = sz.width + pad * 2
        // Hang just below the notch/menu area: safeAreaInsets.top covers the
        // notch on modern MacBooks, 0 elsewhere (sits flush at top edge).
        let drop = screen.safeAreaInsets.top
        let y = screen.frame.maxY - drop - h - 2
        p.setFrame(NSRect(x: screen.frame.midX - w / 2, y: y, width: w, height: h),
                   display: true)
        tf.frame = NSRect(x: pad, y: 3, width: sz.width, height: h - 6)
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
        if popover.isShown { popover.close() }
        clearOrphanedPopover()
        store.popoverShown = false
    }

    @objc private func togglePopover() {
        if clearOrphanedPopover() { return }
        if popover.isShown {
            // Clicked away, then straight back on the bar mid-fade: reopen
            // once the close lands instead of swallowing the click.
            if popoverClosing && closedByOutsideClick {
                reopenAfterClose = true
                return
            }
            popover.performClose(nil)
            return
        }
        if Date().timeIntervalSince(popoverClosedAt) < 0.4 { return }
        store.acknowledgeAlerts()
        store.refresh()
        if let bg = islandPanel?.contentView, islandPanel?.isVisible == true {
            popoverAnchor = bg
        } else {
            popoverAnchor = statusItem.button
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

// The island's capsule view: glass background, dimmed at rest, brightens on
// hover, click opens the popover.
private final class IslandView: NSVisualEffectView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 13
        alphaValue = 0.85
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1.0 }
    override func mouseExited(with event: NSEvent) { animator().alphaValue = 0.85 }
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1 { onClick?() }
    }
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
        popoverClosedAt = Date()
        popoverClosing = false
        closedByOutsideClick = false
        if reopenAfterClose {
            reopenAfterClose = false
            popoverClosedAt = .distantPast
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
