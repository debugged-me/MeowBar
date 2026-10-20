import SwiftUI
import AppKit
import Combine

// Derive from the semantic foreground instead of a fixed gray. It remains
// legible when the glass moves over light, dark, or tinted UI.
private func supportingText(_ scheme: ColorScheme) -> Color {
    Color.primary.opacity(scheme == .dark ? 0.76 : 0.70)
}

private func successColor(_ scheme: ColorScheme) -> Color {
    scheme == .dark
        ? Color(red: 0.31, green: 0.93, blue: 0.55)
        : Color(red: 0.00, green: 0.43, blue: 0.19)
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    // Expansion lives here so the 1/2/3 keys (posted from the keyDown
    // monitor in main.swift) can toggle providers from outside the blocks.
    @State private var expandedProviders: Set<String> = []

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

    private var providers: [ProviderUsage] {
        var list = [store.claude, store.codex]
        if store.devin.isVisible { list.append(store.devin) }
        return list
    }

    private var content: some View {
        // Flat list, battery-menu style: slim status header, providers
        // separated by hairline dividers, quiet footer.
        VStack(alignment: .leading, spacing: 9) {
            header
            Divider()
            ForEach(Array(providers.enumerated()), id: \.offset) { i, usage in
                if i > 0 { Divider() }
                ProviderBlock(usage: usage,
                              running: runningFlag(usage.name),
                              store: store,
                              expanded: expandedBinding(usage.name),
                              delay: 0.04 + Double(i) * 0.05)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 290)
        .foregroundStyle(.primary)
        .onReceive(NotificationCenter.default.publisher(for: .init("meowbar.toggleProvider"))) { note in
            guard let s = note.object as? String, let n = Int(s),
                  providers.indices.contains(n - 1) else { return }
            let name = providers[n - 1].name
            guard providers[n - 1].hasData else { return }
            withAnimation(.snappy(duration: 0.25)) {
                if expandedProviders.contains(name) {
                    expandedProviders.remove(name)
                } else {
                    expandedProviders.insert(name)
                }
            }
        }
    }

    private func runningFlag(_ name: String) -> Bool {
        switch name {
        case "Claude": return store.claudeRunning
        case "Codex": return store.codexRunning
        case "Devin": return store.devinRunning
        default: return false
        }
    }

    private func expandedBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { expandedProviders.contains(name) },
            set: { on in
                if on { expandedProviders.insert(name) } else { expandedProviders.remove(name) }
            })
    }

    // MARK: Header — the cat plus the one line you'd read first

    private var header: some View {
        HStack(spacing: 7) {
            CatView(mood: catMood, animating: store.popoverShown)
            Text(statusLine.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusLine.color)
                .textCase(.uppercase)
                .lineLimit(1)
            Spacer()
        }
    }

    // What the whole popover boils down to, worst news first.
    private var statusLine: (text: String, color: Color) {
        if let u = providers.first(where: { ($0.worstUsed ?? 0) >= 100 }) {
            // The one fact you opened this for: when you can work again.
            let reset = [u.session, u.weekly].compactMap { $0?.resetsAt }
                .filter { $0 > Date() }.min()
            return ("\(u.name) maxed" + (reset.map { " · back in \(Countdown.compact(to: $0))" } ?? ""), .red)
        }
        if let u = providers.first(where: { ($0.worstUsed ?? 0) >= 90 }) {
            let eta = u.displayTimeToEmpty
            return ("\(u.name) near the limit" + (eta.map { " · out in ~\(Countdown.rough($0))" } ?? ""), .orange)
        }
        if let u = providers.first(where: { $0.action != nil }) {
            return ("\(u.name) needs attention", .red)
        }
        if let until = store.celebrateUntil, until > Date() {
            return ("Limits refreshed", successColor(colorScheme))
        }
        let running = [("Claude", store.claudeRunning), ("Codex", store.codexRunning),
                       ("Devin", store.devinRunning)].filter(\.1)
        if running.count == 1 { return ("\(running[0].0) is working", successColor(colorScheme)) }
        if running.count > 1 { return ("\(running.count) agents working", successColor(colorScheme)) }
        return ("All quiet", supportingText(colorScheme))
    }

    private var catMood: CatView.Mood {
        if let until = store.celebrateUntil, until > Date() { return .celebrating }
        if providers.contains(where: { ($0.worstUsed ?? 0) >= 90 }) { return .startled }
        if store.claudeRunning || store.codexRunning || store.devinRunning { return .working }
        return .napping
    }

    // MARK: Footer — freshness left, actions behind one gear

    private var footer: some View {
        HStack(spacing: 6) {
            if let at = store.lastUpdated {
                Text("Updated \(Countdown.ago(at))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(supportingText(colorScheme))
                    .textCase(.uppercase)
            }
            Spacer()
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Refresh now (r)")
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("About MeowBar") {
                NotificationCenter.default.post(name: .init("meowbar.openAbout"), object: nil)
            }
            Button("Settings…") {
                NotificationCenter.default.post(name: .init("meowbar.openSettings"), object: nil)
            }
            .keyboardShortcut(",")
            if let update = store.update, let url = UpdateCheck.downloadURL(update) {
                Divider()
                Button("Download MeowBar \(update.version)…") { NSWorkspace.shared.open(url) }
            } else if UpdateCheck.feedURL != nil {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .init("meowbar.checkUpdates"), object: nil)
                }
            }
            Divider()
            Button("Quit MeowBar") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape").font(.caption)
                .overlay(alignment: .topTrailing) {
                    if store.update != nil {
                        Circle().fill(.red).frame(width: 5, height: 5).offset(x: 2.5, y: -2.5)
                    }
                }
                .padding(2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings and updates (q to quit)")
    }
}

struct ProviderBlock: View {
    let usage: ProviderUsage
    var running: Bool = false
    var store: UsageStore? = nil
    var expanded: Binding<Bool> = .constant(false)
    var delay: Double = 0
    @State private var appeared = false
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

    private var providerIcon: NSImage? {
        Bundle.main.image(forResource: usage.name.lowercased())
    }

    // History only makes sense for providers with metered windows.
    private var canExpand: Bool { usage.hasData && store != nil }

    // Right-click → jump into the tool: CLIs land in Terminal, Devin opens its app.
    private var openAction: ProviderAction? {
        switch usage.name {
        case "Claude": return .runInTerminal("claude")
        case "Codex": return .runInTerminal("codex")
        case "Devin": return .openApp("Devin")
        default: return nil
        }
    }

    private var openTitle: String {
        usage.name == "Devin" ? "Open Devin" : "Open \(usage.name) in Terminal"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // header: icon + name (› opens history) + running/stale …… plan pill
            HStack(spacing: 6) {
                if let icon = providerIcon {
                    Image(nsImage: icon).renderingMode(.template)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.primary)
                }
                let name = Text(usage.name).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                if canExpand {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { expanded.wrappedValue.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            name
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(supportingText(colorScheme))
                                .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded.wrappedValue ? "Hide history" : "Show the last 7 days")
                } else {
                    name
                }
                if running {
                    HStack(spacing: 3) {
                        LiveDot(color: successColor(colorScheme), live: store?.popoverShown ?? false)
                        Text("running")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(successColor(colorScheme))
                    }
                } else if usage.isStale, Date().timeIntervalSince(usage.fetchedAt) >= 60 {
                    Label(Countdown.ago(usage.fetchedAt), systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(supportingText(colorScheme))
                        .help("Last numbers MeowBar got — it keeps retrying")
                }
                if let today = UsageHistory.dailyBurn(store?.history[usage.name] ?? [], days: 1).last,
                   today >= 0.5 {
                    Text("+\(Int(today.rounded())) today")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(supportingText(colorScheme))
                        .help("Points of the limit burned today")
                }
                Spacer()
                if usage.note != nil || usage.noteAccent != nil {
                    HStack(spacing: 3) {
                        if let note = usage.note {
                            Text(note).foregroundStyle(.primary)
                        }
                        if let accent = usage.noteAccent {
                            Text(accent).foregroundStyle(successColor(colorScheme))
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

            // Devin has no metered windows — give the row something to say:
            // when the last agent turn happened, read from its session log.
            if usage.name == "Devin", !usage.hasData, !running,
               let at = store?.devinLastActive {
                Text("Last active \(Countdown.ago(at))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(supportingText(colorScheme))
            }

            if expanded.wrappedValue && canExpand {
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
        .contextMenu {
            if let action = openAction {
                Button(openTitle) { UsageService.perform(action) }
                Divider()
            }
            Button("Copy usage") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(usage.shareLine(), forType: .string)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 5)
        .onAppear { if store?.popoverShown ?? true { replayEntrance() } else { appeared = true } }
        .onChange(of: store?.popoverShown ?? false) { _, shown in
            if shown { replayEntrance() } else { appeared = false }
        }
    }

    // Brief rise-and-fade when the popover opens; each block waits a touch
    // longer than the one before it (stagger via `delay`).
    private func replayEntrance() {
        appeared = false
        withAnimation(.easeOut(duration: 0.26).delay(delay)) { appeared = true }
    }
}

// The little pulsing dot next to "running". The repeating animation exists
// only while `live` — the popover's view outlives the popover, and an
// always-on pulse would burn CPU around the clock.
private struct LiveDot: View {
    let color: Color
    var live: Bool
    @State private var dim = false

    var body: some View {
        Circle().fill(color).frame(width: 4.5, height: 4.5)
            .opacity(live && dim ? 0.3 : 1)
            .onAppear { if live { pulse() } }
            .onChange(of: live) { _, live in
                if live { pulse() } else { dim = false }
            }
    }

    private func pulse() {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
    }
}

// Last 7 days as a strip of day bars (today solid) plus the busiest hours
// and how today compares to yesterday.
struct HistoryStrip: View {
    let samples: [UsageSample]
    var tint: Color
    @Environment(\.colorScheme) private var colorScheme

    private var unit: String { samples.contains { $0.weekly != nil } ? "weekly" : "session" }

    // "last 7 days · ↑3% today · busiest 3–6 PM" — one line, quietest first.
    private func metaLine(_ days: [Double]) -> String {
        var parts = ["last 7 days"]
        if days.count >= 2 {
            let delta = (days.last ?? 0) - days[days.count - 2]
            if abs(delta) >= 3 {
                parts.append("\(delta > 0 ? "↑" : "↓")\(Int(abs(delta).rounded()))% today")
            }
        }
        if let b = UsageHistory.busiestBlock(samples) {
            parts.append("busiest \(UsageHistory.blockLabel(startHour: b))")
        }
        return parts.joined(separator: " · ")
    }

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
            VStack(alignment: .leading, spacing: 6) {
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
                    Text(metaLine(days))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(supportingText(colorScheme))
                        .lineLimit(1)
                        .help("Points of the \(unit) limit burned per day")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Last 7 days: " + days.enumerated()
                    .map { "\(dayLabel($0.offset, of: days.count)) \(Int($0.element.rounded())) percent" }
                    .joined(separator: ", "))

                // Hour-by-hour burn over the last day — when the spend
                // happened, not just how much.
                let hours = UsageHistory.hourlyBurn(samples)
                if hours.contains(where: { $0 > 0 }) {
                    Sparkline(values: hours, tint: tint)
                        .frame(height: 16)
                        .help("Burn per hour over the last 24 hours")
                }
            }
        }
    }
}

// A thin line chart — used for the last-24h burn inside expanded history.
// Hover scrubs: a dot rides the line with a "3h ago · +8" readout.
private struct Sparkline: View {
    let values: [Double]
    var tint: Color
    @State private var hover: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let peak = max(values.max() ?? 0, 0.001)
            let stepX = w / max(1, CGFloat(values.count - 1))
            let pts = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX,
                        y: h - 1.5 - (h - 3) * CGFloat(v / peak))
            }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: h - 1))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: pts.last?.x ?? first.x, y: h - 1))
                    p.closeSubpath()
                }
                .fill(tint.opacity(0.18))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(tint.opacity(0.9), lineWidth: 1.2)
                if let i = hover, pts.indices.contains(i) {
                    Circle().fill(tint).frame(width: 5, height: 5)
                        .position(pts[i])
                    let ago = values.count - 1 - i
                    Text("\(ago == 0 ? "now" : "\(ago)h ago") · +\(Int(values[i].rounded()))")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(tint)
                        .position(x: min(max(pts[i].x, 32), w - 32), y: 4)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hover = min(values.count - 1,
                                max(0, Int((p.x / w) * CGFloat(values.count))))
                case .ended:
                    hover = nil
                }
            }
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .lastTextBaseline) {
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(supportingText(colorScheme))
                    Spacer()
                    trailing
                }
                // Custom capsule bar — ProgressView.tint is neutralized inside
                // the glass popover on macOS 26 and renders gray regardless.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.14))
                            .overlay {
                                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                            }
                        Capsule().fill(barGradient)
                            .frame(width: max(0, geo.size.width * min(w.usedPercent, 100) / 100))
                            .animation(.spring(duration: 0.5, bounce: 0.15), value: w.usedPercent)
                        // Even-pace marker: where usage would sit if burned
                        // evenly. Fill past it = ahead of pace.
                        if let f = w.elapsedFraction(), f > 0.02, f < 0.98 {
                            Capsule().fill(Color.primary.opacity(0.7))
                                .frame(width: 2.5, height: 9)
                                .offset(x: geo.size.width * f - 1.25)
                        }
                    }
                }
                .frame(height: 7)
                .help(paceHelp)
                HStack {
                    Text(bottomText).font(.caption2.weight(.medium)).foregroundStyle(supportingText(colorScheme)).lineLimit(1)
                        .help(resetHelp)
                    Spacer()
                    Text(w.paceVerdict()).font(.caption2.weight(.medium)).foregroundStyle(verdictColor)
                        .help("A guess from your pace so far in this window — it changes as you work")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider) \(title.replacingOccurrences(of: " · ", with: ", ")): "
                + "\(Int(max(0, 100 - w.usedPercent))) percent left. \(bottomText). \(w.paceVerdict())")
        } else {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(supportingText(colorScheme))
                Spacer()
                Text("—").font(.caption).foregroundStyle(supportingText(colorScheme))
            }
        }
    }

    // The glance-number: how much is LEFT, big and rounded. When the window
    // is maxed the only useful number is the reset — that becomes the chip.
    @ViewBuilder
    private var trailing: some View {
        if let w, w.usedPercent >= 100, let reset = w.resetsAt, reset > Date() {
            Label(Countdown.compact(to: reset), systemImage: "arrow.clockwise")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.red)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.red.opacity(colorScheme == .dark ? 0.22 : 0.13), in: .capsule)
                .help(resetHelp)
        } else if let w {
            (Text("\(Int(max(0, 100 - w.usedPercent)))%")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(barColor)
                + Text(" left")
                .font(.caption2.weight(.medium))
                .foregroundStyle(supportingText(colorScheme)))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.35), value: w.usedPercent)
        }
    }

    private var bottomText: String {
        guard let w else { return "" }
        if w.usedPercent == 0, w.resetsAt == nil { return resetText }
        if w.usedPercent >= 100 { return "" }       // the reset chip says it all
        if w.usedPercent >= 75 { return resetText } // bar color already says "high"
        return ["\(Int(w.usedPercent))% used", resetText]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var barColor: Color {
        guard let w else { return tint }
        return w.usedPercent >= 90 ? .red : w.usedPercent >= 75 ? .orange : tint
    }

    private var barGradient: LinearGradient {
        LinearGradient(colors: [barColor.opacity(0.75), barColor],
                       startPoint: .leading, endPoint: .trailing)
    }

    private var verdictColor: Color {
        switch w?.paceSeverity() ?? .none {
        case .none: return supportingText(colorScheme)
        case .good: return successColor(colorScheme)
        case .ok: return supportingText(colorScheme)
        case .warn: return .orange
        case .bad: return .red
        }
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
// trembles near a limit, celebrates a fresh reset. Animates only while on
// screen: the popover's view outlives the popover, and a running animation
// kept the app at 10–20% CPU around the clock. When `animating` drops, the
// effects are removed from the view tree, not just paused. Still under
// Reduce Motion.
struct CatView: View {
    enum Mood { case napping, working, startled, celebrating }
    let mood: Mood
    var size: CGFloat = 13
    var animating = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var blinking = false
    // A quick eyelid squash every few seconds — the cheapest life there is.
    private let blinker = Timer.publish(every: 3.8, on: .main, in: .common).autoconnect()

    private var live: Bool { animating && !reduceMotion }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            catWithBlink
            badge
        }
        .frame(width: size * 2.2, height: size * 1.5, alignment: .bottomLeading)
        .help(caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }

    @ViewBuilder
    private var cat: some View {
        let image = Image(nsImage: CatGlyph.image(size: 32))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size * 1.15, height: size * 1.05)
            .foregroundStyle(color)
        if !live {
            image
        } else {
            switch mood {
            case .napping:
                image.phaseAnimator([0.96, 1.05]) { v, p in
                    v.scaleEffect(p, anchor: .bottom)
                }
            case .working, .celebrating:
                image.phaseAnimator([0.0, -0.22, 0.0]) { v, p in
                    v.offset(y: p * size)
                }
            case .startled:
                image.phaseAnimator([0.0, -4.0, 5.0, -3.0, 0.0]) { v, p in
                    v.rotationEffect(.degrees(p))
                }
            }
        }
    }

    @ViewBuilder
    private var catWithBlink: some View {
        cat
            .scaleEffect(y: blinking ? 0.12 : 1, anchor: .center)
            .onReceive(blinker) { _ in blink() }
    }

    private func blink() {
        guard live else { return }
        withAnimation(.easeIn(duration: 0.07)) { blinking = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            withAnimation(.easeOut(duration: 0.12)) { blinking = false }
        }
    }

    private var caption: String {
        switch mood {
        case .napping: return "Napping — nothing running"
        case .working: return "Working — an agent is running"
        case .startled: return "Startled — a limit is close"
        case .celebrating: return "A limit just reset"
        }
    }

    private var color: Color {
        switch mood {
        case .napping: return supportingText(colorScheme)
        case .working, .celebrating: return successColor(colorScheme)
        case .startled: return .orange
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch mood {
        case .napping:
            if live {
                DriftingZ(size: size, color: supportingText(colorScheme))
            } else {
                Text("z")
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(supportingText(colorScheme))
                    .offset(x: size * 1.4, y: -size * 0.6)
            }
        case .startled:
            Text("!")
                .font(.system(size: size * 0.7, weight: .heavy, design: .rounded))
                .foregroundStyle(.orange)
                .offset(x: size * 1.5, y: -size * 0.55)
        case .celebrating:
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(successColor(colorScheme))
                .offset(x: size * 1.45, y: -size * 0.55)
        case .working:
            EmptyView()
        }
    }
}

// A "z" drifting up and fading, on repeat. Its own view so the repeating
// animation dies with it when the cat stops animating.
private struct DriftingZ: View {
    let size: CGFloat
    let color: Color
    @State private var drifting = false

    var body: some View {
        Text("z")
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .opacity(drifting ? 0 : 0.9)
            .offset(x: size * (drifting ? 1.7 : 1.4), y: -size * (drifting ? 1.1 : 0.6))
            .onAppear {
                withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) { drifting = true }
            }
    }
}
