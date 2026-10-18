import Foundation
import UserNotifications

// MARK: - Models

struct UsageWindow {
    var usedPercent: Double = 0
    var resetsAt: Date? = nil
    var windowSeconds: TimeInterval? = nil
}

struct ProviderUsage {
    var name: String
    var session: UsageWindow? = nil
    var weekly: UsageWindow? = nil
    var error: String? = nil
    var fetchedAt: Date = Date()
}

enum UsageError: LocalizedError {
    case noCredentials(String), http(Int, String), refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let hint): return hint
        case .http(let code, let hint): return "HTTP \(code). \(hint)"
        case .refreshFailed(let hint): return hint
        }
    }
}

// MARK: - HTTP helper

private func httpRequest(_ url: String, method: String = "GET",
                         headers: [String: String] = [:], jsonBody: [String: Any]? = nil) async throws -> (Int, Data, [String: String]) {
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = method
    req.timeoutInterval = 15
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    if let jsonBody {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
    }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as? HTTPURLResponse
    let hdrs = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) {
        $0["\($1.key)".lowercased()] = "\($1.value)"
    }
    return (http?.statusCode ?? 0, data, hdrs)
}

private func jsonDict(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// MARK: - Keychain (Claude Code credentials)

private func runProcess(_ launch: String, _ args: [String], timeout: TimeInterval = 30) -> (Int32, String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    // Drain stdout on a background thread while bounded by a timeout: a >64KB
    // write would otherwise fill the pipe and deadlock waitUntilExit, and a
    // stuck child (e.g. an unanswered Keychain prompt) must not hang a fetch.
    var out = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.leave()
    }
    if group.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = group.wait(timeout: .now() + 5)
        return (-2, String(data: out, encoding: .utf8) ?? "")
    }
    return (p.terminationStatus, String(data: out, encoding: .utf8) ?? "")
}

private let claudeService = "Claude Code-credentials"

// Keychain accounts holding a "Claude Code-credentials" item (current user first).
// Duplicate items can exist, e.g. after a macOS username change.
private func claudeKeychainAccounts() -> [String] {
    var accts = [NSUserName()]
    let loginKeychain = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
    let (_, dump) = runProcess("/usr/bin/security", ["dump-keychain", loginKeychain])
    var acct: String? = nil, isClaude = false
    func flush() {
        if isClaude, let a = acct, !accts.contains(a) { accts.append(a) }
        acct = nil; isClaude = false
    }
    for line in dump.split(separator: "\n") {
        if line.hasPrefix("keychain:") || line.hasPrefix("class:") { flush() }
        if let m = line.range(of: "\"acct\"<blob>=\"[^\"]*\"", options: .regularExpression) {
            acct = String(line[m]).components(separatedBy: "\"")[3]
        }
        if line.contains("\"svce\"<blob>=\"\(claudeService)\"") { isClaude = true }
    }
    flush()
    return accts
}

// Returns credentials plus the keychain account they came from, so refreshes
// write back to the same item. Picks the freshest item when duplicates exist.
private func loadClaudeCredentials() throws -> (cred: [String: Any], account: String) {
    var best: (dict: [String: Any], acct: String, exp: Double)? = nil
    for acct in claudeKeychainAccounts() {
        let (status, out) = runProcess("/usr/bin/security",
            ["find-generic-password", "-s", claudeService, "-a", acct, "-w"])
        guard status == 0,
              let dict = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any] else { continue }
        let exp = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init) ?? 0
        if best == nil || exp > best!.exp { best = (dict, acct, exp) }
    }
    if let best { return (best.dict, best.acct) }
    // fallback: file-based credentials
    let path = NSHomeDirectory() + "/.claude/.credentials.json"
    if let data = FileManager.default.contents(atPath: path),
       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       dict["claudeAiOauth"] != nil {
        return (dict, NSUserName())
    }
    throw UsageError.noCredentials("No Claude credentials found — sign in with `claude` first")
}

private func saveClaudeCredentials(_ dict: [String: Any], account: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let json = String(data: data, encoding: .utf8) else { return }
    _ = runProcess("/usr/bin/security", ["add-generic-password", "-U", "-a", account, "-s", claudeService, "-w", json])
}

private func refreshClaudeToken(_ cred: [String: Any], account: String) async throws -> [String: Any] {
    guard let oauth = cred["claudeAiOauth"] as? [String: Any],
          let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else {
        throw UsageError.refreshFailed("Claude token expired — run `claude` once to sign in again")
    }
    let (status, data, _) = try await httpRequest(
        "https://api.anthropic.com/v1/oauth/token", method: "POST",
        headers: ["User-Agent": "claude-cli/2.0.30 (external, cli)"],
        jsonBody: [
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
    let resp = jsonDict(data)
    guard status == 200, let access = resp["access_token"] as? String else {
        throw UsageError.refreshFailed("Claude token expired and refresh failed — run `claude` once to sign in again")
    }
    var updated = cred
    var newOAuth = oauth
    newOAuth["accessToken"] = access
    if let r = resp["refresh_token"] as? String { newOAuth["refreshToken"] = r }
    let expiresIn = (resp["expires_in"] as? Double) ?? (resp["expires_in"] as? Int).map(Double.init) ?? 28800
    newOAuth["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
    updated["claudeAiOauth"] = newOAuth
    saveClaudeCredentials(updated, account: account)
    return updated
}

private func claudeAccessToken() async throws -> String {
    var (cred, account) = try loadClaudeCredentials()
    var oauth = cred["claudeAiOauth"] as! [String: Any]
    let expiresAt = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init) ?? 0
    if expiresAt < Date().timeIntervalSince1970 * 1000 {
        cred = try await refreshClaudeToken(cred, account: account)
        oauth = cred["claudeAiOauth"] as! [String: Any]
    }
    guard let token = oauth["accessToken"] as? String else {
        throw UsageError.noCredentials("No Claude access token — run `claude` once")
    }
    return token
}

// MARK: - Codex credentials (~/.codex/auth.json)

private let codexAuthPath = NSHomeDirectory() + "/.codex/auth.json"

private func loadCodexAuth() throws -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: codexAuthPath),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = dict["tokens"] as? [String: Any],
          tokens["access_token"] is String else {
        throw UsageError.noCredentials("No Codex credentials — sign in with `codex` first")
    }
    return dict
}

private func saveCodexAuth(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
    try? FileManager.default.copyItem(atPath: codexAuthPath, toPath: codexAuthPath + ".meowbar-bak")
    try? data.write(to: URL(fileURLWithPath: codexAuthPath))
}

private func refreshCodexToken(_ auth: [String: Any]) async throws -> [String: Any] {
    guard let tokens = auth["tokens"] as? [String: Any],
          let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
        throw UsageError.refreshFailed("Codex token expired — run `codex` once to sign in again")
    }
    var clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    if let tok = tokens["access_token"] as? String, let aud = jwtAudience(tok) { clientId = aud }
    let (status, data, _) = try await httpRequest(
        "https://auth.openai.com/oauth/token", method: "POST",
        headers: ["User-Agent": "codex-cli"],
        jsonBody: ["client_id": clientId, "grant_type": "refresh_token", "refresh_token": refresh])
    let resp = jsonDict(data)
    guard status == 200, let access = resp["access_token"] as? String else {
        throw UsageError.refreshFailed("Codex token expired and refresh failed — run `codex` once")
    }
    var updated = auth
    var newTokens = tokens
    newTokens["access_token"] = access
    if let t = resp["id_token"] as? String { newTokens["id_token"] = t }
    if let r = resp["refresh_token"] as? String { newTokens["refresh_token"] = r }
    updated["tokens"] = newTokens
    updated["last_refresh"] = ISO8601DateFormatter().string(from: Date())
    saveCodexAuth(updated)
    return updated
}

private func jwtAudience(_ jwt: String) -> String? {
    let parts = jwt.split(separator: ".")
    guard parts.count > 1 else { return nil }
    var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let payload = try? JSONSerialization.jsonObject(with: Data(base64Encoded: b64) ?? Data()) as? [String: Any] else { return nil }
    return (payload["aud"] as? [String])?.first ?? payload["aud"] as? String
}

// MARK: - Usage fetches

enum UsageService {

    // /api/oauth/usage is aggressively rate-limited (429 + Retry-After).
    // Keep last-good data and back off instead of blanking the UI.
    private static var claudeCache: ProviderUsage? = nil
    private static var claudeBlockedUntil: Date = .distantPast

    static func fetchClaude() async -> ProviderUsage {
        if let cached = claudeCache, Date() < claudeBlockedUntil { return cached }
        var u = ProviderUsage(name: "Claude")
        do {
            let token = try await claudeAccessToken()
            let (status, data, hdrs) = try await httpRequest(
                "https://api.anthropic.com/api/oauth/usage",
                headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"])
            let json = jsonDict(data)
            if status == 429 {
                let wait = Double(hdrs["retry-after"] ?? "") ?? 120
                claudeBlockedUntil = Date().addingTimeInterval(wait)
                if let cached = claudeCache { return cached }
                throw UsageError.http(429, "rate-limited — retrying \(Notifier.countdown(to: claudeBlockedUntil))")
            }
            guard status == 200 else {
                if status == 401 || status == 403 {
                    throw UsageError.http(status, "Claude token rejected — run `claude` once to sign in again")
                }
                throw UsageError.http(status, "Claude usage unavailable")
            }
            u.session = claudeWindow(json, keys: ["five_hour", "fiveHour", "session", "session_5h"], seconds: 18000)
            u.weekly = claudeWindow(json, keys: ["seven_day", "sevenDay", "weekly", "week"], seconds: 604800)
            claudeCache = u
        } catch { u.error = error.localizedDescription }
        return u
    }

    static func fetchCodex() async -> ProviderUsage {
        var u = ProviderUsage(name: "Codex")
        do {
            var auth = try loadCodexAuth()
            var tokens = auth["tokens"] as! [String: Any]
            var (status, data, _) = try await codexUsageRequest(tokens)
            if status == 401 || status == 403 {
                auth = try await refreshCodexToken(auth)
                tokens = auth["tokens"] as! [String: Any]
                (status, data, _) = try await codexUsageRequest(tokens)
            }
            guard status == 200 else { throw UsageError.http(status, "Codex usage unavailable") }
            let rl = jsonDict(data)["rate_limit"] as? [String: Any] ?? [:]
            u.session = codexWindow(rl["primary_window"])
            u.weekly = codexWindow(rl["secondary_window"])
        } catch { u.error = error.localizedDescription }
        return u
    }

    private static func codexUsageRequest(_ tokens: [String: Any]) async throws -> (Int, Data, [String: String]) {
        try await httpRequest(
            "https://chatgpt.com/backend-api/wham/usage",
            headers: [
                "Authorization": "Bearer \(tokens["access_token"] as? String ?? "")",
                "ChatGPT-Account-Id": tokens["account_id"] as? String ?? "",
                "User-Agent": "codex-cli",
            ])
    }

    // Anthropic returns fractional seconds ("...22:59:59.843964+00:00"), which
    // the plain .withInternetDateTime options reject — try with, then without.
    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func claudeWindow(_ json: [String: Any], keys: [String], seconds: TimeInterval) -> UsageWindow? {
        for k in keys {
            if let w = json[k] as? [String: Any] {
                var win = UsageWindow(windowSeconds: seconds)
                if let p = w["utilization"] as? Double { win.usedPercent = p }
                else if let p = w["utilization"] as? Int { win.usedPercent = Double(p) }
                else if let p = w["used_percent"] as? Double { win.usedPercent = p }
                for rk in ["resets_at", "reset_at"] {
                    if let s = w[rk] as? String {
                        win.resetsAt = Self.parseISO8601(s)
                    } else if let ts = w[rk] as? Double {
                        win.resetsAt = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
                    }
                }
                return win
            }
        }
        return nil
    }

    private static func codexWindow(_ any: Any?) -> UsageWindow? {
        guard let w = any as? [String: Any] else { return nil }
        var win = UsageWindow()
        win.usedPercent = (w["used_percent"] as? Double) ?? (w["used_percent"] as? Int).map(Double.init) ?? 0
        win.windowSeconds = (w["limit_window_seconds"] as? Double) ?? (w["limit_window_seconds"] as? Int).map(Double.init)
        if let ts = w["reset_at"] as? Double { win.resetsAt = Date(timeIntervalSince1970: ts) }
        return win
    }
}

// MARK: - Notifications

enum Notifier {
    private static var lastLevel: [String: Int] = [:]
    private static var lastReset: [String: Date] = [:]

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func evaluate(_ u: ProviderUsage) {
        for (label, w) in [("session", u.session), ("weekly", u.weekly)] {
            guard let w else { continue }
            let key = "\(u.name) \(label)"
            if let reset = w.resetsAt {
                if let prev = lastReset[key], reset > prev.addingTimeInterval(60) {
                    notify("\(u.name) \(label) limit reset", body: "Fresh window started.")
                }
                lastReset[key] = reset
            }
            let level = w.usedPercent >= 95 ? 95 : w.usedPercent >= 90 ? 90 : w.usedPercent >= 75 ? 75 : 0
            let prev = lastLevel[key] ?? 0
            if level > prev {
                notify("\(u.name) \(label): \(Int(w.usedPercent))% used",
                       body: w.resetsAt.map { "Resets \(Self.countdown(to: $0))." } ?? "")
            }
            lastLevel[key] = w.usedPercent < 70 ? 0 : max(prev, level)
        }
    }

    private static func notify(_ title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static func countdown(to date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }
}
