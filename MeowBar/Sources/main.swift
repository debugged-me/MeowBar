import Cocoa
import QuartzCore
import SwiftUI

final class UsageStore: ObservableObject {
    @Published var claude = ProviderUsage(name: "Claude")
    @Published var codex = ProviderUsage(name: "Codex")
    @Published var devin = ProviderUsage(name: "Devin")
    @Published var claudeRunning = false
    @Published var codexRunning = false
    @Published var devinRunning = false
    @Published var lastUpdated: Date?
    var onUpdate: (() -> Void)?
    var onAlert: (() -> Void)?
    private var timer: Timer?
    private var activityTimer: Timer?
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
        refresh()
        sampleActivity()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sampleActivity()
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

    func refresh() {
        if demoActive { return }
        Task {
            async let c = UsageService.fetchClaude()
            async let x = UsageService.fetchCodex()
            async let d = UsageService.fetchDevin()
            let (cl, co, dv) = await (c, x, d)
            await MainActor.run {
                self.claude = cl
                self.codex = co
                self.devin = dv
                self.lastUpdated = Date()
                let now = Date()
                for s in [(name: "Claude", pct: Self.dispLeft(cl), worst: Self.worstUsed(cl)),
                          (name: "Codex", pct: Self.dispLeft(co), worst: Self.worstUsed(co)),
                          (name: "Devin", pct: Self.dispLeft(dv), worst: Self.worstUsed(dv))] {
                    let prevW = self.prevWorst[s.name] ?? -1
                    if let w = s.worst { self.prevWorst[s.name] = w }
                    if let w = s.worst, w >= 90, prevW < 90 {
                        self.arm(s.name, (s.pct ?? 0) <= 0 ? "limit reached" : "nearing limit", now: now)
                    } else if (s.pct ?? 1) <= 0, self.alertText[s.name] == "nearing limit" {
                        self.arm(s.name, "limit reached", now: now)
                    }
                }
                Notifier.evaluate(cl)
                Notifier.evaluate(co)
                Notifier.evaluate(dv)
                self.onUpdate?()
            }
        }
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
                    }
                }
                self.claudeRunning = self.confirmedRunning["Claude"] == true
                self.codexRunning = self.confirmedRunning["Codex"] == true
                self.devinRunning = self.confirmedRunning["Devin"] == true
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

    static func worstUsed(_ u: ProviderUsage) -> Double? {
        [u.session, u.weekly].compactMap { $0 }.map(\.usedPercent).max()
    }

    // Menu-bar number: weekly % left only when the weekly itself is the blocker
    // (≥90% used); otherwise the session % left.
    static func dispLeft(_ u: ProviderUsage) -> Double? {
        let s = u.session?.usedPercent, w = u.weekly?.usedPercent
        if let w, w >= 90 { return 100 - w }
        return (s ?? w).map { 100 - $0 }
    }

    // The window the bar is displaying — same rule as dispLeft.
    static func dispReset(_ u: ProviderUsage) -> Date? {
        if let w = u.weekly, w.usedPercent >= 90 { return w.resetsAt }
        return u.session?.resetsAt ?? u.weekly?.resetsAt
    }

    // "4h59m" / "6d10h" — compact for the countdown display mode.
    static func compactCountdown(to date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
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

    private func iconImage(_ resource: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 16, height: 16)
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
                metric = Self.compactCountdown(to: reset)
            } else {
                metric = pct.map { String(format: "%.0f%%", $0) } ?? "–"
            }
            s.append(NSAttributedString(
                string: " " + metric,
                attributes: [
                    .foregroundColor: color,
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
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
        t.append(entry("claude", "Claude", Self.dispLeft(claude), Self.worstUsed(claude),
                       Self.dispReset(claude), claudeRunning))
        t.append(NSAttributedString(string: "   "))
        t.append(entry("codex", "Codex", Self.dispLeft(codex), Self.worstUsed(codex),
                       Self.dispReset(codex), codexRunning))
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
    // Clicking the status item while the popover is open auto-dismisses it
    // AND fires the action — without this guard the click reopens instead of
    // closing. 0.4s is below human double-tap speed for a deliberate reopen.
    private var popoverClosedAt = Date.distantPast
    let store = UsageStore()
    private var settingsWindow: NSWindow?
    private var islandPanel: NSPanel?
    private var islandField: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐱"
        statusItem.button?.toolTip = "Claude / Codex usage"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .semitransient // detaches when dragged into a window
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        store.onUpdate = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.attributedTitle = self.store.menuTitle
            self.statusItem.button?.toolTip = self.store.menuToolTip
            self.layoutIsland()
        }
        store.onAlert = { [weak self] in self?.flashMenuItem() }
        store.start()
        Notifier.requestPermission()

        applyPosition()
        NotificationCenter.default.addObserver(forName: .meowbarSettingsChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyPosition()
            self?.store.onUpdate?()
            self?.store.refresh()
        }
        NotificationCenter.default.addObserver(forName: .init("meowbar.openSettings"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }

        // .transient is unreliable for accessory apps — explicitly close on
        // any outside click while the popover is up.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        // Popover never takes key (battery-menu behavior) — typing goes to
        // whatever app you're in. This only fires while we're key anyway
        // (e.g. Settings open), in which case any key dismisses the popover.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.popover.isShown == true else { return event }
            self?.popover.performClose(nil)
            return nil
        }
    }

    // MARK: Settings window

    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
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

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if Date().timeIntervalSince(popoverClosedAt) < 0.4 { return }
        store.acknowledgeAlerts()
        store.refresh()
        if let bg = islandPanel?.contentView, islandPanel?.isVisible == true {
            popover.show(relativeTo: bg.bounds, of: bg, preferredEdge: .minY)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    // Dragging the popover off the bar detaches it into a floating window.
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        let host = NSHostingController(rootView: PopoverView(store: store))
        let w = NSWindow(contentViewController: host)
        w.title = "MeowBar"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.level = .floating
        return w
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
