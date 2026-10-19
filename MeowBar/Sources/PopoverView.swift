import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            // Keep the surface untinted so Liquid Glass can sample the desktop.
            // Semantic foreground colours below retain contrast as it changes.
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content.background(.ultraThickMaterial)
        }
    }

    private var content: some View {
        // Flat list, battery-menu style: no header, providers separated by
        // hairline dividers only.
        VStack(alignment: .leading, spacing: 9) {
            ProviderBlock(usage: store.claude, running: store.claudeRunning, store: store)
            Divider()
            ProviderBlock(usage: store.codex, running: store.codexRunning, store: store)
            if store.devin.isVisible {
                Divider()
                ProviderBlock(usage: store.devin, running: store.devinRunning, store: store)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .init("meowbar.openSettings"), object: nil)
                } label: {
                    Image(systemName: "gearshape").font(.caption)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("Settings")
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 290)
        .foregroundStyle(.primary)
    }
}

struct ProviderBlock: View {
    let usage: ProviderUsage
    var running: Bool = false
    var store: UsageStore? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var brandColor: Color {
        switch usage.name {
        case "Claude":
            return colorScheme == .dark
                ? Color(red: 1.00, green: 0.60, blue: 0.45)
                : Color(red: 0.70, green: 0.29, blue: 0.18)
        case "Codex":
            return colorScheme == .dark
                ? Color(red: 0.27, green: 0.91, blue: 0.69)
                : Color(red: 0.00, green: 0.45, blue: 0.34)
        default: return .primary
        }
    }

    private var successColor: Color {
        colorScheme == .dark
            ? Color(red: 0.31, green: 0.93, blue: 0.55)
            : Color(red: 0.00, green: 0.43, blue: 0.19)
    }

    private var providerIcon: NSImage? {
        Bundle.main.image(forResource: usage.name.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // header: icon + name + running badge …… plan pill
            HStack(spacing: 6) {
                if let icon = providerIcon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                }
                Text(usage.name).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                if running {
                    Text("running")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(successColor)
                }
                Spacer()
                if usage.note != nil || usage.noteAccent != nil {
                    HStack(spacing: 3) {
                        if let note = usage.note {
                            Text(note).foregroundStyle(.primary)
                        }
                        if let accent = usage.noteAccent {
                            Text(accent).foregroundStyle(successColor)
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.thinMaterial, in: .capsule)
                    .overlay {
                        Capsule().strokeBorder(brandColor.opacity(0.46), lineWidth: 0.75)
                    }
                }
            }

            if let err = usage.error {
                Text(err)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = usage.action {
                    Button(action.title) {
                        UsageService.perform(action)
                        store?.refresh()
                    }
                    .controlSize(.small)
                }
            }

            let unlimited = usage.noteAccent == "unlimited" && !usage.hasData
            if !unlimited && (usage.hasData || usage.error == nil) {
                let sessionLabel = usage.name == "Devin" ? "Daily · 24h" : "Session · 5h"
                WindowRow(title: sessionLabel, w: usage.session, tint: brandColor)
                WindowRow(title: "Weekly · 7d", w: usage.weekly, tint: brandColor)
            }
        }
    }
}

struct WindowRow: View {
    let title: String
    let w: UsageWindow?
    var tint: Color = .accentColor
    @Environment(\.colorScheme) private var colorScheme

    private var supportingText: Color {
        // Derive from the semantic foreground instead of a fixed gray. It
        // remains legible when the glass moves over light, dark, or tinted UI.
        Color.primary.opacity(colorScheme == .dark ? 0.76 : 0.70)
    }

    var body: some View {
        if let w {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(supportingText)
                    Spacer()
                    (Text("\(Int(w.usedPercent))%").font(.caption.weight(.semibold))
                        + Text(" used · \(Int(max(0, 100 - w.usedPercent)))% left")
                        .font(.caption).foregroundStyle(supportingText))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.35), value: w.usedPercent)
                }
                // Custom capsule bar — ProgressView.tint is neutralized inside
                // the glass popover on macOS 26 and renders gray regardless.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(barColor)
                            .frame(width: max(0, geo.size.width * min(w.usedPercent, 100) / 100))
                            .animation(.spring(duration: 0.5, bounce: 0.15), value: w.usedPercent)
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(resetText).font(.caption2.weight(.medium)).foregroundStyle(supportingText).lineLimit(1)
                    Spacer()
                    Text(paceText).font(.caption2.weight(.medium)).foregroundStyle(supportingText)
                }
            }
        } else {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(supportingText)
                Spacer()
                Text("—").font(.caption).foregroundStyle(supportingText)
            }
        }
    }

    private var barColor: Color {
        guard let w else { return tint }
        return w.usedPercent >= 90 ? .red : w.usedPercent >= 75 ? .orange : tint
    }

    private var resetText: String {
        // Claude's 5h window only opens on the first message — while idle the
        // API reports 0% with resets_at: null, so there's no clock to count.
        guard let reset = w?.resetsAt else {
            return (w?.usedPercent ?? 0) == 0 ? "starts on first message" : ""
        }
        if reset <= Date() { return "resetting now" }
        return "resets \(Notifier.countdown(to: reset))"
    }

    // Projected usage at reset (linear burn since the window opened) → a
    // one-word verdict. Hidden for the first 10 min of a window — too noisy.
    private var paceText: String {
        guard let w, let win = w.windowSeconds, let reset = w.resetsAt else { return "" }
        if w.usedPercent >= 100 { return "maxed" }
        let remaining = reset.timeIntervalSinceNow
        let elapsed = win - remaining
        guard elapsed > 600 else { return "" }
        let usedFrac = w.usedPercent / 100
        let projected = usedFrac * win / elapsed
        if projected >= 1 {
            let secondsToFull = (1 - usedFrac) * elapsed / max(usedFrac, 0.001)
            guard secondsToFull < remaining else { return "cutting it close" }
            return "hit limit \(Notifier.countdown(to: Date().addingTimeInterval(secondsToFull)))"
        }
        if projected < 0.55 { return "plenty left" }
        if projected < 0.85 { return "comfortable" }
        return "cutting it close"
    }
}
