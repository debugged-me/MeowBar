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
