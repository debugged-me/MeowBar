import Cocoa
import SwiftUI

final class UsageStore: ObservableObject {
    @Published var claude = ProviderUsage(name: "Claude")
    @Published var codex = ProviderUsage(name: "Codex")
    @Published var lastUpdated: Date?
    var onUpdate: (() -> Void)?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        Task {
            async let c = UsageService.fetchClaude()
            async let x = UsageService.fetchCodex()
            let (cl, co) = await (c, x)
            await MainActor.run {
                self.claude = cl
                self.codex = co
                self.lastUpdated = Date()
                Notifier.evaluate(cl)
                Notifier.evaluate(co)
                self.onUpdate?()
            }
        }
    }

    // "<claude-glyph> <pct>%   <codex-glyph> <pct>%" — each provider's worst
    // window (5h or 7d), severity-tinted. 🐱 alone until first data arrives.
    var menuTitle: NSAttributedString {
        // <claude logo> <pct>%   <codex blossom> <pct>% — session window each,
        // severity-tinted. Glyphs are template images so they track the menu bar.
        func entry(_ resource: String, _ pct: Double?) -> NSAttributedString {
            let color: NSColor = pct == nil ? .secondaryLabelColor
                : pct! >= 90 ? .systemRed : pct! >= 75 ? .systemOrange : .labelColor
            let s = NSMutableAttributedString()
            if let url = Bundle.main.url(forResource: resource, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 13, height: 13)
                let att = NSTextAttachment()
                att.image = img
                att.bounds = CGRect(x: 0, y: -2.5, width: 13, height: 13)
                s.append(NSAttributedString(attachment: att))
            }
            s.append(NSAttributedString(string: pct.map { String(format: " %.0f%%", $0) } ?? " –",
                                        attributes: [.foregroundColor: color]))
            return s
        }
        let t = NSMutableAttributedString()
        t.append(entry("claude", claude.session?.usedPercent))
        t.append(NSAttributedString(string: "   "))
        t.append(entry("codex", codex.session?.usedPercent))
        return t
    }

    var menuToolTip: String {
        func line(_ u: ProviderUsage) -> String {
            let s = u.session?.usedPercent, w = u.weekly?.usedPercent
            let nums = [
                s.map { String(format: "5h %.0f%%", $0) },
                w.map { String(format: "7d %.0f%%", $0) },
            ].compactMap { $0 }.joined(separator: " · ")
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
