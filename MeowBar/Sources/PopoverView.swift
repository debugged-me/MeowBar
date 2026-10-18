import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let icon = Bundle.main.image(forResource: "icon") {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 26, height: 26)
                }
                Text("MeowBar").font(.headline)
            }
            ProviderBlock(usage: store.claude)
            Divider()
            ProviderBlock(usage: store.codex)
            Divider()
            ProviderBlock(usage: store.devin)
            Divider()
            HStack {
                Text("Updated " + (store.lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "never"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

struct ProviderBlock: View {
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(usage.name).font(.subheadline).bold()
            if let err = usage.error {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            // Skip "—" placeholders when the error already explains missing data
            let sessionLabel = usage.name == "Devin" ? "Daily · 24h" : "Session · 5h"
            if usage.session != nil || usage.error == nil {
                WindowRow(title: sessionLabel, w: usage.session)
            }
            if usage.weekly != nil || usage.error == nil {
                WindowRow(title: "Weekly · 7d", w: usage.weekly)
            }
        }
    }
}

struct WindowRow: View {
    let title: String
    let w: UsageWindow?

    private static let timeFmt: Date.FormatStyle = .dateTime.hour().minute()
    private static let dayFmt: Date.FormatStyle = .dateTime.weekday(.abbreviated).hour().minute()

    var body: some View {
        if let w {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(w.usedPercent))% used · \(Int(max(0, 100 - w.usedPercent)))% left")
                        .font(.caption).monospacedDigit()
                }
                ProgressView(value: min(w.usedPercent, 100) / 100)
                    .tint(barColor)
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
        guard let w else { return .accentColor }
        return w.usedPercent >= 90 ? .red : w.usedPercent >= 75 ? .orange : .accentColor
    }

    private var resetText: String {
        guard let reset = w?.resetsAt else { return "" }
        if reset <= Date() { return "resetting now" }
        let sameDay = Calendar.current.isDate(reset, inSameDayAs: Date())
        return "resets \(Notifier.countdown(to: reset)) · \(reset.formatted(sameDay ? Self.timeFmt : Self.dayFmt))"
    }

    // Warnings only: "maxed", or "expected out" when actually running low —
    // burning ahead of pace and (≥70% used or capping within the hour).
    // "on pace" / "window just reset" are intentionally hidden to save space.
    private var paceText: String {
        guard let w, let win = w.windowSeconds, let reset = w.resetsAt else { return "" }
        if w.usedPercent >= 100 { return "maxed" }
        let remaining = reset.timeIntervalSinceNow
        let elapsed = win - remaining
        guard elapsed > 120 else { return "" }
        let usedFrac = w.usedPercent / 100
        guard usedFrac > elapsed / win else { return "" }
        let secondsToFull = (1 - usedFrac) * elapsed / max(usedFrac, 0.001)
        guard secondsToFull < remaining,
              w.usedPercent >= 70 || secondsToFull <= 3600 else { return "" }
        return "expected out \(Notifier.countdown(to: Date().addingTimeInterval(secondsToFull)))"
    }
}
