import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        if #available(macOS 26.0, *) {
            // Liquid Glass, untinted — samples whatever's behind and blends in
            content.glassEffect(.regular, in: .rect)
        } else {
            content.background(.ultraThickMaterial)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let icon = Bundle.main.image(forResource: "icon") {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                }
                Text("MeowBar").font(.headline)
            }
            .padding(.horizontal, 2)

            ProviderBlock(usage: store.claude, running: store.claudeRunning, store: store)
            ProviderBlock(usage: store.codex, running: store.codexRunning, store: store)
            if store.devin.isVisible {
                ProviderBlock(usage: store.devin, running: store.devinRunning, store: store)
            }

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
            .padding(.horizontal, 2)
        }
        .padding(12)
        .frame(width: 300)
    }
}

struct ProviderBlock: View {
    let usage: ProviderUsage
    var running: Bool = false
    var store: UsageStore? = nil

    private var brandColor: Color {
        switch usage.name {
        case "Claude": return Color(red: 0.85, green: 0.47, blue: 0.34) // anthropic coral
        case "Codex": return Color(red: 0.06, green: 0.64, blue: 0.50)  // openai green
        default: return .primary
        }
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
                Text(usage.name).font(.subheadline).bold().foregroundStyle(brandColor)
                if running {
                    Text("running").font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                if usage.note != nil || usage.noteAccent != nil {
                    HStack(spacing: 3) {
                        if let note = usage.note { Text(note) }
                        if let accent = usage.noteAccent { Text(accent).foregroundStyle(.green) }
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(brandColor.opacity(0.14), in: .capsule)
                }
            }

            if let err = usage.error {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WindowRow: View {
    let title: String
    let w: UsageWindow?
    var tint: Color = .accentColor

    private static let timeFmt: Date.FormatStyle = .dateTime.hour().minute()
    private static let dayFmt: Date.FormatStyle = .dateTime.weekday(.abbreviated).hour().minute()

    var body: some View {
        if let w {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(w.usedPercent))%").font(.caption.weight(.semibold)).monospacedDigit()
                        + Text(" used · \(Int(max(0, 100 - w.usedPercent)))% left")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                // Custom capsule bar — ProgressView.tint is neutralized inside
                // the glass popover on macOS 26 and renders gray regardless.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(barColor)
                            .frame(width: max(0, geo.size.width * min(w.usedPercent, 100) / 100))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(resetText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(paceText).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("—").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var barColor: Color {
        guard let w else { return tint }
        return w.usedPercent >= 90 ? .red : w.usedPercent >= 75 ? .orange : tint
    }

    private var resetText: String {
        guard let reset = w?.resetsAt else { return "" }
        if reset <= Date() { return "resetting now" }
        let sameDay = Calendar.current.isDate(reset, inSameDayAs: Date())
        return "resets \(Notifier.countdown(to: reset)) · \(reset.formatted(sameDay ? Self.timeFmt : Self.dayFmt))"
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
