import SwiftUI

// Derive from the semantic foreground instead of a fixed gray. It remains
// legible when the glass moves over light, dark, or tinted UI.
private func supportingText(_ scheme: ColorScheme) -> Color {
    Color.primary.opacity(scheme == .dark ? 0.76 : 0.70)
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme

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
            footer
        }
        .padding(12)
        .frame(width: 290)
        .foregroundStyle(.primary)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            CatView(mood: catMood, animating: store.popoverShown)
            if let at = store.lastUpdated {
                Text("updated \(Countdown.ago(at))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(supportingText(colorScheme))
            }
            Spacer()
            if let update = store.update, let url = UpdateCheck.downloadURL(update) {
                Button("Update") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
                    .help("MeowBar \(update.version) is available" + (update.notes.map { " — \($0)" } ?? ""))
            }
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

    private var catMood: CatView.Mood {
        if [store.claude, store.codex, store.devin].contains(where: { ($0.worstUsed ?? 0) >= 90 }) {
            return .startled
        }
        if store.claudeRunning || store.codexRunning || store.devinRunning { return .working }
        return .napping
    }
}

struct ProviderBlock: View {
    let usage: ProviderUsage
    var running: Bool = false
    var store: UsageStore? = nil
    @State private var expanded = false
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

    // History only makes sense for providers with metered windows.
    private var canExpand: Bool { usage.hasData && store != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // header: icon + name (› opens history) + running/stale …… plan pill
            HStack(spacing: 6) {
                if let icon = providerIcon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                }
                let name = Text(usage.name).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                if canExpand {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            name
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(supportingText(colorScheme))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide history" : "Show the last 7 days")
                } else {
                    name
                }
                if running {
                    Text("running")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(successColor)
                } else if usage.isStale, Date().timeIntervalSince(usage.fetchedAt) >= 60 {
                    Label(Countdown.ago(usage.fetchedAt), systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(supportingText(colorScheme))
                        .help("Last numbers MeowBar got — it keeps retrying")
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

            if expanded && canExpand {
                HistoryStrip(samples: store?.history[usage.name] ?? [], tint: brandColor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let err = usage.error {
                // Red only when there's something to fix; transient states
                // (rate limits, retries) read as information.
                Text(err)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(usage.action != nil ? Color.red : supportingText(colorScheme))
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
                WindowRow(provider: usage.name, title: sessionLabel, w: usage.session, tint: brandColor,
                          clockStarting: usage.name == "Claude" && store?.clockStarting == true)
                WindowRow(provider: usage.name, title: "Weekly · 7d", w: usage.weekly, tint: brandColor)
            }
        }
    }
}

// Last 7 days as a strip of day bars (today solid) plus the busiest hours.
struct HistoryStrip: View {
    let samples: [UsageSample]
    var tint: Color
    @Environment(\.colorScheme) private var colorScheme

    private var unit: String { samples.contains { $0.weekly != nil } ? "weekly" : "session" }

    private func dayLabel(_ i: Int, of count: Int) -> String {
        let ago = count - 1 - i
        if ago == 0 { return "Today" }
        if ago == 1 { return "Yesterday" }
        let day = Calendar.current.date(byAdding: .day, value: -ago, to: Date()) ?? Date()
        return day.formatted(.dateTime.weekday(.wide))
    }

    var body: some View {
        let days = UsageHistory.dailyBurn(samples)
        let peak = days.max() ?? 0
        if peak <= 0 {
            Text("Collecting history — check back tomorrow")
                .font(.caption2.weight(.medium))
                .foregroundStyle(supportingText(colorScheme))
        } else {
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, v in
                        Capsule()
                            .fill(tint.opacity(i == days.count - 1 ? 1 : 0.5))
                            .frame(width: 7, height: max(2, 22 * v / peak))
                            .help("\(dayLabel(i, of: days.count)) · \(Int(v.rounded()))% of the \(unit) limit")
                    }
                }
                .frame(height: 22, alignment: .bottom)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("last 7 days")
                    if let b = UsageHistory.busiestBlock(samples) {
                        Text("busiest \(UsageHistory.blockLabel(startHour: b))")
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(supportingText(colorScheme))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last 7 days: " + days.enumerated()
                .map { "\(dayLabel($0.offset, of: days.count)) \(Int($0.element.rounded())) percent" }
                .joined(separator: ", "))
        }
    }
}

struct WindowRow: View {
    var provider: String = ""
    let title: String
    let w: UsageWindow?
    var tint: Color = .accentColor
    var clockStarting = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let w {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(supportingText(colorScheme))
                    Spacer()
                    (Text("\(Int(w.usedPercent))%").font(.caption.weight(.semibold))
                        + Text(" used · \(Int(max(0, 100 - w.usedPercent)))% left")
                        .font(.caption).foregroundStyle(supportingText(colorScheme)))
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
                        // Even-pace marker: where usage would sit if burned
                        // evenly. Fill past it = ahead of pace.
                        if let f = w.elapsedFraction(), f > 0.02, f < 0.98 {
                            Capsule().fill(Color.primary.opacity(0.6))
                                .frame(width: 2, height: 10)
                                .offset(x: geo.size.width * f - 1)
                        }
                    }
                }
                .frame(height: 6)
                .help(paceHelp)
                HStack {
                    Text(resetText).font(.caption2.weight(.medium)).foregroundStyle(supportingText(colorScheme)).lineLimit(1)
                        .help(resetHelp)
                    Spacer()
                    Text(w.paceVerdict()).font(.caption2.weight(.medium)).foregroundStyle(supportingText(colorScheme))
                        .help("A guess from your pace so far in this window — it changes as you work")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider) \(title.replacingOccurrences(of: " · ", with: ", ")): "
                + "\(Int(w.usedPercent)) percent used. \(resetText). \(w.paceVerdict())")
        } else {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(supportingText(colorScheme))
                Spacer()
                Text("—").font(.caption).foregroundStyle(supportingText(colorScheme))
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
            if clockStarting { return "starting the clock…" }
            return (w?.usedPercent ?? 0) == 0 ? "starts on first message" : ""
        }
        if reset <= Date() { return "resetting now" }
        return "resets \(Countdown.long(to: reset))"
    }

    // Exact reset time on hover: "Resets at 1:12 PM" / "Resets Tue at 1:12 PM".
    private var resetHelp: String {
        guard let reset = w?.resetsAt, reset > Date() else { return "" }
        let time = reset.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(reset) { return "Resets at \(time)" }
        return "Resets \(reset.formatted(.dateTime.weekday(.abbreviated))) at \(time)"
    }

    private var paceHelp: String {
        guard let w, let f = w.elapsedFraction() else { return "" }
        return "At an even pace you'd be at \(Int(f * 100))% by now — you're at \(Int(w.usedPercent))%"
    }
}

// The mascot: naps when nothing's running, bounces while an agent works,
// wiggles when a limit is close — a few cycles each time the popover opens,
// then still. Never animates off screen: the popover's view outlives the
// popover, and a running animation kept the app at 10–20% CPU around the
// clock; when `animating` drops, the effects leave the view tree. Still under
// Reduce Motion. (macOS 14: still.)
struct CatView: View {
    enum Mood { case napping, working, startled }
    let mood: Mood
    var size: CGFloat = 13
    var animating = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var live: Bool { animating && !reduceMotion }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            cat
            badge
        }
        .frame(width: size * 2.2, height: size * 1.5, alignment: .bottomLeading)
        .help(caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }

    @ViewBuilder
    private var cat: some View {
        let image = Image(systemName: "cat.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
        // A few cycles each time the popover opens, then rest — looping
        // effects cost ~10% CPU for as long as the popover stays open.
        if live, #available(macOS 15.0, *) {
            switch mood {
            case .napping: image.symbolEffect(.breathe, options: .repeat(.periodic(2, delay: 0.4)))
            case .working: image.symbolEffect(.bounce.up, options: .repeat(.periodic(4, delay: 0.3)))
            case .startled: image.symbolEffect(.wiggle, options: .repeat(.periodic(3, delay: 0.8)))
            }
        } else {
            image
        }
    }

    private var caption: String {
        switch mood {
        case .napping: return "Napping — nothing running"
        case .working: return "Working — an agent is running"
        case .startled: return "Startled — a limit is close"
        }
    }

    private var color: Color {
        switch mood {
        case .napping: return supportingText(colorScheme)
        case .working: return colorScheme == .dark
            ? Color(red: 0.31, green: 0.93, blue: 0.55) : Color(red: 0.00, green: 0.43, blue: 0.19)
        case .startled: return .orange
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch mood {
        case .napping:
            // System symbol effect, not a SwiftUI repeatForever animation: the
            // latter kept ticking after its view was removed (~6% CPU, closed).
            let z = Image(systemName: "zzz")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(supportingText(colorScheme))
                .offset(x: size * 1.3, y: -size * 0.7)
            if live, #available(macOS 15.0, *) {
                z.symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeat(.periodic(2, delay: 0.4)))
            } else {
                z
            }
        case .startled:
            Text("!")
                .font(.system(size: size * 0.7, weight: .heavy, design: .rounded))
                .foregroundStyle(.orange)
                .offset(x: size * 1.5, y: -size * 0.55)
        case .working:
            EmptyView()
        }
    }
}
