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

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
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

    var menuTitle: NSAttributedString {
        // <logo> <state>: live alert word (armed on edges, expires after
        // alertTTL or on click) > "running" while the CLI is busy > % left.
        func entry(_ resource: String, _ name: String, _ pct: Double?, _ sev: Double?, _ running: Bool) -> NSAttributedString {
            var color: NSColor = sev == nil ? .secondaryLabelColor
                : sev! >= 90 ? .systemRed : sev! >= 75 ? .systemOrange : .labelColor
            let s = NSMutableAttributedString()
            if let url = Bundle.main.url(forResource: resource, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 16, height: 16)
                let att = NSTextAttachment()
                att.image = img
                att.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
                s.append(NSAttributedString(attachment: att))
            }
            let label: String
            if let alert = alertText[name], (alertUntil[name] ?? .distantPast) > Date() {
                label = " " + alert
                color = alert == "task done" ? .systemGreen : .systemRed
            } else if running {
                label = " running"
                color = .systemGreen
            } else {
                label = pct.map { String(format: " %.0f%%", $0) } ?? " –"
            }
            s.append(NSAttributedString(string: label, attributes: [.foregroundColor: color]))
            return s
        }
        let t = NSMutableAttributedString()
        t.append(entry("claude", "Claude", Self.dispLeft(claude), Self.worstUsed(claude), claudeRunning))
        t.append(NSAttributedString(string: "   "))
        t.append(entry("codex", "Codex", Self.dispLeft(codex), Self.worstUsed(codex), codexRunning))
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐱"
        statusItem.button?.toolTip = "Claude / Codex usage"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .transient
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        store.onUpdate = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.attributedTitle = self.store.menuTitle
            self.statusItem.button?.toolTip = self.store.menuToolTip
        }
        store.start()
        Notifier.requestPermission()

        // .transient is unreliable for accessory apps — explicitly close on
        // any click delivered to another app while the popover is up.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.acknowledgeAlerts()
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
