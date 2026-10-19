import Foundation

// meowbar-statusline — installed as Claude Code's statusLine command.
// Claude Code pipes the session JSON on stdin on every render; we extract
// rate_limits → ~/Library/Application Support/MeowBar/claude-statusline.json,
// then chain to the user's original statusLine command (if any) so their
// terminal prompt is unchanged. Output is whatever the original printed.

let supportDir = NSHomeDirectory() + "/Library/Application Support/MeowBar"
let snapshotPath = supportDir + "/claude-statusline.json"
let originalPath = supportDir + "/original-statusline.json"

// A chained status line that exits without reading its stdin must not take
// this helper down with SIGPIPE (Claude Code would show a blank line).
signal(SIGPIPE, SIG_IGN)

let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// --- snapshot --------------------------------------------------------------
if let root = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
    var snap: [String: Any] = ["observed_at": Date().timeIntervalSince1970]
    if let v = root["version"] as? String { snap["claude_version"] = v }

    // Tolerant: window key names have drifted between releases
    // (five_hour/seven_day plus sonnet/opus/oauth_apps variants).
    var windows: [String: Any] = [:]
    if let rl = root["rate_limits"] as? [String: Any] {
        for (key, val) in rl {
            guard let w = val as? [String: Any] else { continue }
            var win: [String: Any] = [:]
            if let p = w["used_percentage"] as? Double { win["used_percentage"] = p }
            else if let p = w["used_percentage"] as? Int { win["used_percentage"] = p }
            else if let p = w["utilization"] as? Double { win["used_percentage"] = p }
            if let r = w["resets_at"] as? String { win["resets_at"] = r }
            else if let r = w["resets_at"] as? Double { win["resets_at"] = r }
            if !win.isEmpty { windows[key] = win }
        }
    }
    if !windows.isEmpty { snap["windows"] = windows }

    try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: snap) {
        // atomic replace so a reader never sees a torn file
        let tmp = snapshotPath + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tmp))
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: snapshotPath),
                                                   withItemAt: URL(fileURLWithPath: tmp))
        if FileManager.default.fileExists(atPath: tmp) { try? FileManager.default.removeItem(atPath: tmp) }
    }
}

// --- chain to the original status line -------------------------------------
func chain() -> String? {
    guard let data = FileManager.default.contents(atPath: originalPath),
          let orig = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cmd = orig["command"] as? String, !cmd.isEmpty else { return nil }
    let p = Process(), inp = Pipe(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.standardInput = inp
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    try? inp.fileHandleForWriting.write(contentsOf: stdinData)
    try? inp.fileHandleForWriting.close()
    let result = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: result, encoding: .utf8)
}

if let chained = chain() {
    FileHandle.standardOutput.write(Data(chained.utf8))
}
// No original → print nothing; Claude Code just shows an empty status line.
