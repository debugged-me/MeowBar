import SwiftUI
import ServiceManagement

// Every change posts this so AppDelegate can reconfigure live.
extension Notification.Name {
    static let meowbarSettingsChanged = Notification.Name("meowbar.settingsChanged")
}

struct SettingsView: View {
    @AppStorage("meowbar.position") var position = "right"     // right | middle
    @AppStorage("meowbar.displayMode") var displayMode = "percent" // percent | countdown
    @AppStorage("meowbar.alwaysFresh") var alwaysFresh = false
    @AppStorage("meowbar.alert75") var alert75 = true
    @AppStorage("meowbar.alert90") var alert90 = true
    @AppStorage("meowbar.alert95") var alert95 = true
    @AppStorage("meowbar.alertReset") var alertReset = true
    @AppStorage("meowbar.launchAtLogin") var launchAtLogin = false
    @AppStorage("meowbar.autoClock") var autoClock = true
    @AppStorage("meowbar.hotkey") var hotkey = HotKey.defaultID
    @State private var bridgeError: String? = nil
    @State private var bridgeInstalled = false

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Position", selection: $position) {
                    Text("Right — with the other icons").tag("right")
                    Text("Middle — like the notch").tag("middle")
                }
                Picker("Show", selection: $displayMode) {
                    Text("% left").tag("percent")
                    Text("Time until reset").tag("countdown")
                }
            }

            Section("Alerts") {
                Toggle("Nudge at 75% used", isOn: $alert75)
                Toggle("Nudge at 90% used", isOn: $alert90)
                Toggle("Nudge at 95% used", isOn: $alert95)
                Toggle("When a limit resets", isOn: $alertReset)
            }

            Section("Claude") {
                Toggle(isOn: $alwaysFresh) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always fresh")
                        Text("Claude Code reports its limits to MeowBar through its status line — no polling, no rate-limit delays. Numbers update after each message.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if alwaysFresh {
                    Text(bridgeInstalled
                         ? "Tracking on — numbers arrive after your next Claude Code message."
                         : (bridgeError ?? "Installing…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $autoClock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start the 5h clock automatically")
                        Text("When the session is idle and you're at your Mac, MeowBar sends a one-word prompt (Haiku) so the window — and its reset — starts sooner.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Picker("Open MeowBar with", selection: $hotkey) {
                    Text("Off").tag("off")
                    ForEach(HotKey.choices, id: \.id) { Text($0.combo.label).tag($0.id) }
                }
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            bridgeInstalled = StatuslineBridge.isInstalled
            alwaysFresh = bridgeInstalled // reflect real state, even if enabled elsewhere
            syncLoginItem()
        }
        .onChange(of: position) { changed() }
        .onChange(of: displayMode) { changed() }
        .onChange(of: alert75) { changed() }
        .onChange(of: alert90) { changed() }
        .onChange(of: alert95) { changed() }
        .onChange(of: alertReset) { changed() }
        .onChange(of: autoClock) { changed() }
        .onChange(of: hotkey) { changed() }
        .onChange(of: launchAtLogin) { applyLoginItem() }
        .onChange(of: alwaysFresh) { _, on in
            do {
                if on { try StatuslineBridge.install() } else { try StatuslineBridge.uninstall() }
                bridgeInstalled = StatuslineBridge.isInstalled
                bridgeError = nil
            } catch {
                bridgeError = error.localizedDescription
                alwaysFresh = false
            }
            changed()
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .meowbarSettingsChanged, object: nil)
    }

    private func syncLoginItem() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
        changed()
    }
}
