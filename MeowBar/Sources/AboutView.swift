import AppKit
import SwiftUI

// The small About panel — gear menu and right-click menu both land here.
// Icon, version, one-line pitch, links. Nothing else.
struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
            VStack(spacing: 3) {
                Text("MeowBar").font(.title3.weight(.bold))
                Text("Version \(UpdateCheck.currentVersion)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("Your AI limits, at a glance.\nNo accounts · no telemetry · just the bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/debugged-me/MeowBar")!)
                }
                Button("Report a bug") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/debugged-me/MeowBar/issues")!)
                }
            }
            .controlSize(.small)
            CatView(mood: .napping, size: 16, animating: true)
                .opacity(0.6)
                .help("It meows when a limit resets. Settings → Alerts.")
        }
        .padding(18)
        .frame(width: 230)
    }
}
