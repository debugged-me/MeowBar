import Cocoa
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
    private var timer: Timer?
    // Transient menu-bar alerts: armed on state edges (task finished, limit
    // reached), auto-clear after alertTTL or instantly on click.
    private var alertText: [String: String] = [:]
    private var alertUntil: [String: Date] = [:]
    private var prevRunning: [String: Bool] = [:]
    private var prevWorst: [String: Double] = [:]
    private let alertTTL: TimeInterval = 60
    private var demoActive = false

    func start() {
        if injectDemo() { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
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
            let (cRun, xRun, dRun) = UsageService.activeCLIs()
            await MainActor.run {
                self.claude = cl
                self.codex = co
                self.devin = dv
                self.claudeRunning = cRun
                self.codexRunning = xRun
                self.devinRunning = dRun
                self.lastUpdated = Date()
                let now = Date()
                for s in [(name: "Claude", pct: Self.dispLeft(cl), worst: Self.worstUsed(cl), running: cRun),
                          (name: "Codex", pct: Self.dispLeft(co), worst: Self.worstUsed(co), running: xRun),
                          (name: "Devin", pct: Self.dispLeft(dv), worst: Self.worstUsed(dv), running: dRun)] {
                    let wasRunning = self.prevRunning[s.name] ?? false
                    let prevW = self.prevWorst[s.name] ?? -1
                    self.prevRunning[s.name] = s.running
                    if let w = s.worst { self.prevWorst[s.name] = w }
                    if wasRunning && !s.running {
                        self.arm(s.name, "task done", now: now)
                    } else if let w = s.worst, w >= 90, prevW < 90 {
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
    }

    // Click = "seen it": clear all live alerts immediately.
    func acknowledgeAlerts() {
        alertText.removeAll()
        alertUntil.removeAll()
        onUpdate?()
    }

    // The icon IS the meter: it fills bottom-up with used% — ghosted icon as
    // track, full-color icon rising with usage (severity tints via text).
    private func iconImage(_ resource: String, fillFrac f: Double?) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        guard let f, f > 0.005 else {
            src.size = NSSize(width: 16, height: 16)
            return src
        }
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.25)
            let ctx = NSGraphicsContext.current
            ctx?.saveGraphicsState()
            ctx?.cgContext.clip(to: CGRect(x: 0, y: 0,
                                           width: rect.width,
                                           height: rect.height * min(max(f, 0), 1)))
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx?.restoreGraphicsState()
            return true
        }
        img.isTemplate = false
        return img
    }

    var menuTitle: NSAttributedString {
        // <logo> <state>: live alert word (armed on edges, expires after
        // alertTTL or on click) > "running" while the CLI is busy > % left.
        func entry(_ resource: String, _ name: String, _ pct: Double?, _ sev: Double?,
                   _ resetAt: Date?, _ running: Bool) -> NSAttributedString {
            let color: NSColor = sev == nil ? .secondaryLabelColor
                : sev! >= 90 ? .systemRed : sev! >= 75 ? .systemOrange : .labelColor
            let s = NSMutableAttributedString()
            if let img = iconImage(resource, fillFrac: pct.map { (100 - $0) / 100 }) {
                img.size = NSSize(width: 16, height: 16)
                let att = NSTextAttachment()
                att.image = img
                att.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
                s.append(NSAttributedString(attachment: att))
            }
            let label: String
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let alert = alertText[name], (alertUntil[name] ?? .distantPast) > Date() {
                label = " " + alert
                attrs[.foregroundColor] = alert == "task done" ? NSColor.systemGreen : NSColor.systemRed
                attrs[.font] = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            } else if running {
                label = " running"
                attrs[.foregroundColor] = NSColor.systemGreen
                attrs[.font] = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            } else {
                let mode = UserDefaults.standard.string(forKey: "meowbar.displayMode") ?? "percent"
                if mode == "countdown", let reset = resetAt {
                    label = " \(Self.compactCountdown(to: reset))"
                } else {
                    label = pct.map { String(format: " %.0f%%", $0) } ?? " –"
                }
                attrs[.font] = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            }
            s.append(NSAttributedString(string: label, attributes: attrs))
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
        // The popover activates the app while open, so keypresses arrive here —
        // any key dismisses it (nothing to type into anyway).
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
        store.acknowledgeAlerts()
        store.refresh()
        if let bg = islandPanel?.contentView, islandPanel?.isVisible == true {
            popover.show(relativeTo: bg.bounds, of: bg, preferredEdge: .minY)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // Key window → controls render true tint colors (inactive windows
        // draw them grayed) and keyDown events reach the local monitor.
        NSApp.activate(ignoringOtherApps: true)
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
        NSApp.deactivate()
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
