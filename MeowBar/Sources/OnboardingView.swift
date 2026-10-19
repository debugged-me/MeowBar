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
    @State private var alwaysFresh = true
    @State private var autoClock = true
    @State private var launchAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CatView(mood: .napping, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to MeowBar").font(.title2.weight(.bold))
                    Text("Your Claude and Codex limits, always in the menu bar.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                MenuBarMock()
                Text("— it lives up here")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            Label {
                Text("macOS will ask once to let MeowBar read **Claude Code-credentials** from your Keychain. Choose **Always Allow** — it's only used to ask Anthropic for your usage.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 12) {
                option($alwaysFresh, "Always-fresh Claude numbers",
                       "Claude Code reports its limits to MeowBar through its status line. Your current status line keeps working.")
                option($autoClock, "Start Claude's 5h clock automatically",
                       "When the session is idle and you're at your Mac, MeowBar sends a one-word prompt so the window — and its reset — starts sooner.")
                option($launchAtLogin, "Launch at login", nil)
            }

            HStack {
                Spacer()
                Button("Get started") {
                    onDone(Choices(alwaysFresh: alwaysFresh, autoClock: autoClock,
                                   launchAtLogin: launchAtLogin))
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func option(_ isOn: Binding<Bool>, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
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
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
