import SwiftUI

// First launch: explain the one Keychain prompt before it appears, and offer
// the three things worth deciding up front. Each choice stays in Settings.
struct OnboardingView: View {
    struct Choices {
        var alwaysFresh: Bool
        var autoClock: Bool
        var launchAtLogin: Bool
    }

    var onDone: (Choices) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alwaysFresh = true
    @State private var autoClock = true
    @State private var launchAtLogin = true
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.14))
                    CatView(mood: .napping, size: 25, animating: false)
                        .offset(x: 6)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to MeowBar")
                        .font(.title2.weight(.bold))
                    Text("Your AI limits, one glance away.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.13),
                                                  Color.accentColor.opacity(0.035)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.7)
            }

            HStack(spacing: 8) {
                MenuBarMock()
                Text("Lives quietly in your menu bar")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            Label {
                Text("macOS will ask once to let MeowBar read **Claude Code-credentials** from your Keychain. Choose **Always Allow** — it's only used to ask Anthropic for your usage.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Recommended setup")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                option($alwaysFresh, icon: "bolt.horizontal.fill", "Always-fresh Claude numbers",
                       "Claude Code reports its limits to MeowBar through its status line. Your current status line keeps working.")
                option($autoClock, icon: "clock.arrow.circlepath", "Start Claude's 5h clock automatically",
                       "When the session is idle and you're at your Mac, MeowBar sends a one-word prompt so the window — and its reset — starts sooner.")
                option($launchAtLogin, icon: "power", "Launch at login", nil)
            }

            Text("Optional cat sounds — a meow on reset, a meow on task done, a sad mewl when a limit maxes — live in Settings → Alerts. Off until you want them.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Get started") {
                    onDone(Choices(alwaysFresh: alwaysFresh, autoClock: autoClock,
                                   launchAtLogin: launchAtLogin))
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.35)) { appeared = true }
            }
        }
    }

    private func option(_ isOn: Binding<Bool>, icon: String, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.10), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(11)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }
}

// A tiny picture of the thing you're installing: the menu-bar capsule with
// the cat and both meters, rendered with the real glyphs.
private struct MenuBarMock: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: CatGlyph.image(size: 18))
                .renderingMode(.template)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 12, height: 11)
                .foregroundStyle(.primary)
            entry("claude", "82%")
            entry("codex", "45%")
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        }
    }

    private func entry(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            if let img = Bundle.main.image(forResource: icon) {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
