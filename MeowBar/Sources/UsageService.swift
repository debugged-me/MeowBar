import Foundation
import CommonCrypto
import SQLite3
import UserNotifications

// MARK: - Errors (models live in Core/Models.swift)

enum UsageError: LocalizedError {
    case noCredentials(String), http(Int, String), refreshFailed(String)
    case actionable(String, ProviderAction?)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let hint): return hint
        case .http(let code, let hint): return "HTTP \(code). \(hint)"
        case .refreshFailed(let hint): return hint
        case .actionable(let hint, _): return hint
        }
    }

    var action: ProviderAction? {
        if case .actionable(_, let a) = self { return a }
        return nil
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

// GUI apps inherit a minimal PATH, so `which` alone misses CLIs installed via
// brew/npm/nvm/volta/asdf/mise/fnm. Search PATH plus the usual manager dirs
// (including versioned subdirs for nvm/fnm/mise).
private func cliPath(_ name: String) -> String? {
    let home = NSHomeDirectory()
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map(String.init)
    dirs += [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        home + "/.local/bin", home + "/.volta/bin", home + "/.npm-global/bin",
        home + "/Library/pnpm", home + "/.yarn/bin",
        home + "/.config/yarn/global/node_modules/.bin",
        home + "/.asdf/shims", home + "/.local/share/mise/shims", home + "/bin",
    ]
    let fm = FileManager.default
    for base in [home + "/.nvm/versions/node", home + "/.local/share/mise/installs/node",
                 home + "/Library/Application Support/fnm/node-versions",
                 home + "/.local/share/fnm/node-versions"] {
        for v in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
            dirs.append("\(base)/\(v)/bin")
        }
    }
    for d in dirs where fm.isExecutableFile(atPath: d + "/" + name) {
        return d + "/" + name
    }
    return nil
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

private func claudeExpiresAt(_ cred: [String: Any]) -> Double {
    guard let oauth = cred["claudeAiOauth"] as? [String: Any] else { return 0 }
    return (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init) ?? 0
}

// Claude Code renews its own OAuth token on startup, so when ours is expired
// (and self-refresh failed) we probe `claude auth status` — and if that didn't
// renew, boot the CLI headless for a few seconds with /exit piped in. Nothing
// is sent to the API. Backed off so a signed-out user doesn't respawn it
// every refresh cycle.
private var claudeReviveBlockedUntil = Date.distantPast

private func reviveClaudeToken() -> Bool {
    guard Date() >= claudeReviveBlockedUntil, let bin = cliPath("claude") else { return false }
    claudeReviveBlockedUntil = Date().addingTimeInterval(30 * 60)
    _ = runProcess(bin, ["auth", "status", "--json"], timeout: 15)
    if let (c, _) = try? loadClaudeCredentials(),
       claudeExpiresAt(c) > Date().timeIntervalSince1970 * 1000 { return true }
    _ = runProcess("/bin/sh", ["-c", "printf '/exit\\n' | \"\(bin)\""], timeout: 15)
    if let (c, _) = try? loadClaudeCredentials(),
       claudeExpiresAt(c) > Date().timeIntervalSince1970 * 1000 { return true }
    return false
}

private func claudeAccessToken() async throws -> String {
    var (cred, account) = try loadClaudeCredentials()
    var oauth = cred["claudeAiOauth"] as! [String: Any]
    let expiresAt = claudeExpiresAt(cred)
    if expiresAt < Date().timeIntervalSince1970 * 1000 {
        do {
            cred = try await refreshClaudeToken(cred, account: account)
        } catch {
            // Refresh token rejected too — let Claude Code renew itself.
            if reviveClaudeToken(), let (fresh, acct) = try? loadClaudeCredentials() {
                cred = fresh; account = acct
            } else { throw error }
        }
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

// MARK: - Devin credentials (IDE secret storage)
//
// The Devin desktop app is a VS Code fork: extension secrets live in
// ~/Library/Application Support/Devin/User/globalStorage/state.vscdb under
// "secret://{...}" keys, each value a JSON {"type":"Buffer","data":[v,1,0,...]}
// blob — "v10" prefix + AES-128-CBC ciphertext. The key is PBKDF2-SHA1 of the
// "Devin Safe Storage" Keychain password (Chromium os_crypt convention).

private let devinDBPath = NSHomeDirectory() +
    "/Library/Application Support/Devin/User/globalStorage/state.vscdb"
private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func pbkdf2SHA1(password: String, salt: String, iterations: UInt32, keyLen: Int) -> Data? {
    var out = [UInt8](repeating: 0, count: keyLen)
    let ok = password.withCString { pw in salt.withCString { s in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, strlen(pw), s, strlen(s),
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations,
                             &out, keyLen)
    }}
    return ok == kCCSuccess ? Data(out) : nil
}

private func aes128CBCDecrypt(key: Data, ciphertext: Data) -> Data? {
    var outLen = 0
    var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
    var iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128) // 16 spaces, per os_crypt
    let ok = key.withUnsafeBytes { k in ciphertext.withUnsafeBytes { c in
        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                k.baseAddress, k.count, &iv, c.baseAddress, c.count, &out, out.count, &outLen)
    }}
    return ok == kCCSuccess ? Data(out.prefix(outLen)) : nil
}

private func devinSecret(_ secretKey: String) throws -> String {
    var db: OpaquePointer?
    guard sqlite3_open_v2(devinDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw UsageError.noCredentials("Devin IDE storage not found — sign in to the Devin app first")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let key = "secret://{\"extensionId\":\"codeium.windsurf\",\"key\":\"\(secretKey)\"}"
    guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
        throw UsageError.noCredentials("Devin storage unreadable")
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_PTR)
    guard sqlite3_step(stmt) == SQLITE_ROW,
          let cStr = sqlite3_column_text(stmt, 0) else {
        throw UsageError.noCredentials("Devin session not found — sign in to the Devin app first")
    }
    let blobJSON = String(cString: cStr)
    guard let bytes = (jsonDict(Data(blobJSON.utf8))["data"] as? [Any])?
            .compactMap({ ($0 as? NSNumber)?.uint8Value }),
          bytes.count > 4, bytes[0] == UInt8(ascii: "v") else {
        throw UsageError.noCredentials("Devin session format unrecognized")
    }
    let (status, pw) = runProcess("/usr/bin/security",
        ["find-generic-password", "-s", "Devin Safe Storage", "-a", "Devin Key", "-w"])
    guard status == 0, !pw.isEmpty else {
        throw UsageError.noCredentials("Devin Safe Storage key unavailable — allow access if macOS asks")
    }
    guard let keyData = pbkdf2SHA1(password: pw.trimmingCharacters(in: .whitespacesAndNewlines),
                                   salt: "saltysalt", iterations: 1003, keyLen: 16),
          let plain = aes128CBCDecrypt(key: keyData, ciphertext: Data(bytes.dropFirst(3))),
          let str = String(data: plain, encoding: .utf8) else {
        throw UsageError.noCredentials("Could not decrypt Devin session")
    }
    return str
}

private struct DevinCredential {
    var accessToken: String
    var apiServerURL: String
}

// Codex persists explicit task_started/task_complete markers in each local
// rollout. Reading those markers is more accurate than CPU alone because an
// IDE task remains active while it waits on the model or a tool. Files are
// consumed incrementally, so the 2-second activity check only reads new bytes.
private final class CodexTurnTracker: @unchecked Sendable {
    private struct State {
        var offset: UInt64 = 0
        var active = false
    }

    private var states: [String: State] = [:]
    private let lock = NSLock()

    func isActive(rolloutPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let handle = FileHandle(forReadingAtPath: rolloutPath) else { return false }
        defer { try? handle.close() }

        let end = handle.seekToEndOfFile()
        var state = states[rolloutPath] ?? State()
        if end < state.offset { state = State() }
        // Small overlap protects against observing a line while it is being
        // appended. Reprocessing a marker is harmless because it is a state.
        let start = state.offset == 0 ? 0 : state.offset - min(state.offset, 4096)
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        for line in data.split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let marker = payload["type"] as? String else { continue }
            if marker == "task_started" { state.active = true }
            if marker == "task_complete" { state.active = false }
        }
        state.offset = end
        states[rolloutPath] = state
        return state.active
    }
}

private let codexTurnTracker = CodexTurnTracker()

private final class ClaudeTurnTracker: @unchecked Sendable {
    private struct State {
        var offset: UInt64 = 0
        var active = false
    }

    private var states: [String: State] = [:]
    private var candidates: [String] = []
    private var discoverAfter = Date.distantPast
    private let lock = NSLock()

    func hasActiveTurn() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now >= discoverAfter {
            candidates = discoverRecentTranscripts()
            discoverAfter = now.addingTimeInterval(10)
        }
        for path in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) < 15 * 60 else { continue }
            if update(path: path) { return true }
        }
        return false
    }

    private func discoverRecentTranscripts() -> [String] {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(String, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            found.append((url.path, modified))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
    }

    private func update(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let end = handle.seekToEndOfFile()
        var state = states[path] ?? State()
        if end < state.offset { state = State() }
        let start = state.offset == 0 ? 0 : state.offset - min(state.offset, 4096)
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        for line in data.split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            if type == "user" { state.active = true }
            if type == "assistant",
               let message = json["message"] as? [String: Any],
               let stop = message["stop_reason"] as? String {
                if stop == "end_turn" || stop == "stop_sequence" { state.active = false }
                else if stop == "tool_use" { state.active = true }
            }
        }
        state.offset = end
        states[path] = state
        return state.active
    }
}

private let claudeTurnTracker = ClaudeTurnTracker()

private func codexIDEHasActiveTask() -> Bool {
    let codexHome = NSHomeDirectory() + "/.codex"
    let fm = FileManager.default
    let candidates = ((try? fm.contentsOfDirectory(atPath: codexHome)) ?? [])
        .filter { $0.range(of: #"^state_[0-9]+\.sqlite$"#, options: .regularExpression) != nil }
        .map { codexHome + "/" + $0 }
        .sorted {
            let a = (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
            let b = (try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
            return a > b
        }
    guard let dbPath = candidates.first else { return false }

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 4"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let cPath = sqlite3_column_text(stmt, 0) else { continue }
        let path = String(cString: cPath)
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 15 * 60 else { continue }
        if codexTurnTracker.isActive(rolloutPath: path) { return true }
    }
    return false
}

private func loadDevinCredential() throws -> DevinCredential {
    let sessions = try devinSecret("windsurf_auth.sessions")
    let server = (try? devinSecret("windsurf_auth.apiServerUrl")) ?? "https://server.codeium.com"
    guard let arr = try? JSONSerialization.jsonObject(with: Data(sessions.utf8)) as? [[String: Any]],
          let token = arr.first?["accessToken"] as? String, !token.isEmpty else {
        throw UsageError.noCredentials("No Devin session — sign in to the Devin app first")
    }
    return DevinCredential(accessToken: token, apiServerURL: server)
}

// MARK: - Usage fetches

enum UsageService {

    // True when the claude/codex/devin CLI process exists and is burning CPU
    // (an idle REPL sits ~0%); heuristic for "a task is actually running".
    // Names are matched case-sensitively so the "Devin" IDE app (capital D)
    // doesn't count — only the lowercase `devin` CLI harness does.
    static func activeCLIs() -> (claude: Bool, codex: Bool, devin: Bool) {
        // ucomm is the executable name on macOS; comm is a truncated path and
        // can hide `codex`/`claude` when they live inside an editor extension.
        let (_, out) = runProcess("/bin/ps", ["-A", "-o", "pid=", "-o", "%cpu=", "-o", "ucomm="])
        let codexTurnActive = codexIDEHasActiveTask()
        let claudeTurnActive = claudeTurnTracker.hasActiveTurn()
        var c = false, x = false, d = false
        var claudeExists = false, codexExists = false
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]) else { continue }
            let executable = String(parts[2]).trimmingCharacters(in: .whitespaces)
            // Ignore only the short-lived processes MeowBar itself launches
            // (codex app-server for usage data, the session-clock prompt).
            // An IDE-owned app-server can represent real work.
            if meowbarSpawned.contains(pid) { continue }
            if executable == "claude" { claudeExists = true }
            if executable == "codex" { codexExists = true }
            guard cpu > 1.5 else { continue }
            switch executable {
            case "claude": c = true
            case "codex": x = true
            case "devin": d = true
            default: break
            }
        }
        c = c || (claudeExists && claudeTurnActive)
        x = x || (codexExists && codexTurnActive)
        return (c, x, d)
    }

    // /api/oauth/usage is aggressively rate-limited (429 + Retry-After).
    // Keep last-good data and back off instead of blanking the UI.
    private static var claudeCache: ProviderUsage? = nil
    private static var claudeBlockedUntil: Date = .distantPast
    // Retry-After is short but the limit outlasts it — polling every 30s
    // keeps the endpoint angry. Back off 1 → 2 → 4 … 15 min on repeat 429s.
    private static var claude429Streak = 0

    // Plan label ("Max", "Pro", "Team") from the same keychain blob — free,
    // no extra call. subscriptionType comes first; rateLimitTier strings like
    // "default_claude_max_20x" are normalized to the plan word.
    private static var claudePlan: String? = nil
    private static func displayPlanName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("enterprise") { return "Enterprise" }
        if lower.contains("team") { return "Team" }
        if lower.contains("business") { return "Business" }
        if lower.contains("max") { return "Max" }
        if lower.contains("plus") { return "Plus" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("free") { return "Free" }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func claudePlanName() -> String? {
        if claudePlan == nil {
            if let (cred, _) = try? loadClaudeCredentials(),
               let oauth = cred["claudeAiOauth"] as? [String: Any] {
                let raw = (oauth["subscriptionType"] as? String)
                    ?? (oauth["rateLimitTier"] as? String)
                claudePlan = displayPlanName(raw)
            }
        }
        return claudePlan
    }

    // `claude auth status --json` result: catches signed-out and metered
    // (non-subscription) billing before the Keychain dance. nil method =
    // unknown (CLI absent) — don't gate anything on it. A signed-out state is
    // re-probed at most every 5 min so the error clears on its own after the
    // user signs back in.
    private static var claudeAuthMethod: String??
    private static var claudeLoggedIn = true
    private static var claudeProbeBlockedUntil = Date.distantPast

    private static func claudePrecheck() throws {
        if claudeAuthMethod == nil || (!claudeLoggedIn && Date() >= claudeProbeBlockedUntil) {
            var method: String? = nil
            if let bin = cliPath("claude") {
                let (rc, out) = runProcess(bin, ["auth", "status", "--json"], timeout: 15)
                if rc == 0, let st = jsonDict(Data(out.utf8)) as [String: Any]? {
                    claudeLoggedIn = st["loggedIn"] as? Bool ?? true
                    method = st["authMethod"] as? String
                }
            }
            claudeAuthMethod = method
            if !claudeLoggedIn { claudeProbeBlockedUntil = Date().addingTimeInterval(300) }
        }
        if !claudeLoggedIn {
            throw UsageError.actionable(
                "Claude Code isn't signed in", .runInTerminal("claude auth login"))
        }
        let metered = ["apiKey", "api", "console", "bedrock", "vertex"]
        if let m = claudeAuthMethod ?? nil, metered.contains(m) {
            throw UsageError.actionable(
                "Claude Code is signed in with \(m) billing, which has no plan limits to show", nil)
        }
    }

    static func fetchClaude() async -> ProviderUsage {
        if var cached = claudeCache, Date() < claudeBlockedUntil {
            cached.note = cached.note ?? claudePlanName()
            cached.isStale = true
            return cached
        }
        var u = ProviderUsage(name: "Claude")
        // The plan comes from local credentials and remains useful even when
        // the usage endpoint is temporarily rate-limited or unavailable.
        u.note = claudePlanName()
        // Bridge installed → Claude Code pushes fresh numbers on every render;
        // no API polling at all (this is what kills the 429s). Snapshot wins.
        if StatuslineBridge.isInstalled {
            if let bridged = claudeFromSnapshot() { return bridged }
            if StatuslineBridge.isBroken {
                u.error = "Status line tracking points at a missing helper — toggle it off/on in Settings"
                return u
            }
            // bridge on, nothing pushed yet → fall through to OAuth meanwhile
        }
        do {
            try claudePrecheck()
            var token = try await claudeAccessToken()
            var tried = 0
            while true {
                let (status, data, hdrs) = try await httpRequest(
                    "https://api.anthropic.com/api/oauth/usage",
                    headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"])
                let json = jsonDict(data)
                if status == 429 {
                    let backoff = min(900, 60 * pow(2, Double(claude429Streak)))
                    let wait = max(Double(hdrs["retry-after"] ?? "") ?? 0, backoff)
                    claude429Streak += 1
                    claudeBlockedUntil = Date().addingTimeInterval(wait)
                    if var cached = claudeCache { cached.isStale = true; return cached }
                    throw UsageError.actionable(
                        "Anthropic is rate-limiting usage checks — retrying \(Notifier.countdown(to: claudeBlockedUntil))", nil)
                }
                if status == 200 { claude429Streak = 0 }
                if (status == 401 || status == 403) && tried == 0 && reviveClaudeToken() {
                    // Claude Code renewed itself — reload and retry once.
                    tried += 1
                    token = try await claudeAccessToken()
                    continue
                }
                guard status == 200 else {
                    if status == 401 || status == 403 {
                        throw UsageError.http(status, "Claude session rejected — open `claude` once to sign in again")
                    }
                    throw UsageError.http(status, "Claude usage unavailable")
                }
                u.session = claudeWindow(json, keys: ["five_hour", "fiveHour", "session", "session_5h"], seconds: 18000)
                u.weekly = claudeWindow(json, keys: ["seven_day", "sevenDay", "weekly", "week"], seconds: 604800)
                claudeCache = u
                break
            }
        } catch {
            u.error = error.localizedDescription
            u.action = (error as? UsageError)?.action
            if u.action == nil, let ue = error as? UsageError {
                switch ue {
                case .refreshFailed, .noCredentials: u.action = .renewClaude
                case .http(let code, _) where code == 401 || code == 403: u.action = .renewClaude
                default: break
                }
            }
        }
        return u
    }

    static func fetchCodex() async -> ProviderUsage {
        // Preferred path: `codex app-server` — the CLI's own JSON-RPC surface
        // (read-only; nothing written to ~/.codex). Falls back to the
        // wham/usage HTTP endpoint when the binary is missing or won't talk.
        do {
            return try await codexViaAppServer()
        } catch {
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
            } catch let inner as UsageError {
                if cliPath("codex") == nil, inner.localizedDescription.contains("No Codex credentials") {
                    u.error = "Codex isn't installed on this Mac"
                    u.action = .runInTerminal("npm install -g @openai/codex")
                } else {
                    u.error = inner.localizedDescription
                    u.action = inner.action ?? codexAction(for: inner)
                }
            } catch { u.error = error.localizedDescription }
            return u
        }
    }

    // app-server returns richer data than the HTTP endpoint: auth method
    // (chatgpt vs api-key), planType, per-limit maps, credit info.
    private static func codexViaAppServer() async throws -> ProviderUsage {
        guard let bin = cliPath("codex") else {
            throw UsageError.noCredentials("Codex isn't installed on this Mac")
        }
        let rpc = try await Task.detached(priority: .utility) { () throws -> [Int: [String: Any]] in
            try CodexRPC.run(binary: bin)
        }.value
        var u = ProviderUsage(name: "Codex")
        if let errMsg = (rpc[2]?["error"] as? [String: Any])?["message"] as? String
            ?? (rpc[3]?["error"] as? [String: Any])?["message"] as? String {
            let lower = errMsg.lowercased()
            if lower.contains("not signed in") || lower.contains("not logged in")
                || lower.contains("authentication required") || lower.contains("unauthorized") {
                u.error = "Codex is installed but not signed in"
                u.action = .runInTerminal("codex login")
                u.fetchedAt = Date()
                return u
            }
            throw UsageError.actionable(errMsg, nil)
        }
        guard let acctRes = rpc[2]?["result"] as? [String: Any],
              let rlRes = rpc[3]?["result"] as? [String: Any] else {
            throw UsageError.actionable("Codex didn't answer — retrying", nil)
        }
        let account = acctRes["account"] as? [String: Any]
        if let account,
           (account["type"] as? String) == "apiKey" {
            u.error = "Codex is signed in with an API key, which has no plan limits — sign in with ChatGPT to see them"
            u.action = .runInTerminal("codex login")
            return u
        }
        if acctRes["account"] == nil || (acctRes["account"] as? [String: Any]) == nil {
            // Signed out: account/read answers with no account object.
            if let requires = acctRes["requiresOpenaiAuth"] as? Bool, requires {
                u.error = "Codex is installed but not signed in"
                u.action = .runInTerminal("codex login")
                return u
            }
        }
        let rl = rlRes["rateLimits"] as? [String: Any] ?? [:]
        u.session = appServerWindow(rl["primary"])
        u.weekly = appServerWindow(rl["secondary"])
        let credits = rl["credits"] as? [String: Any] ?? [:]
        let plan = displayPlanName((rl["planType"] as? String) ?? (account?["planType"] as? String))
        if credits["unlimited"] as? Bool == true {
            u.note = plan ?? "Plan"
            u.noteAccent = "unlimited"
        } else {
            u.note = plan
        }
        if !u.hasData { u.error = "Codex hasn't reported any limits yet — they appear after you first use Codex" }
        return u
    }

    private static func codexAction(for e: UsageError) -> ProviderAction? {
        switch e {
        case .noCredentials, .refreshFailed: return .runInTerminal("codex login")
        case .http, .actionable: return nil
        }
    }

    private static func appServerWindow(_ any: Any?) -> UsageWindow? {
        guard let w = any as? [String: Any] else { return nil }
        var win = UsageWindow()
        win.usedPercent = (w["usedPercent"] as? Double) ?? (w["usedPercent"] as? Int).map(Double.init) ?? 0
        if let mins = (w["windowDurationMins"] as? Double) ?? (w["windowDurationMins"] as? Int).map(Double.init) {
            win.windowSeconds = mins * 60
        }
        if let ts = (w["resetsAt"] as? Double) ?? (w["resetsAt"] as? Int).map(Double.init) {
            win.resetsAt = Date(timeIntervalSince1970: ts)
        }
        return win
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

    // Devin quota: daily + weekly "remaining %" from GetUserStatus (Connect-RPC
    // JSON). The IDE's stored session token authenticates via metadata.api_key.
    // Caches the decrypted credential + last-good usage so transient failures
    // don't flicker the UI, and so decryption isn't repeated every poll.
    private static var devinCredCache: DevinCredential? = nil
    private static var devinCache: ProviderUsage? = nil
    // Credential failures (missing storage, denied Keychain prompt) must not
    // retrigger a `security` dialog every 30s — back off for 30 min.
    private static var devinCredBlockedUntil: Date = .distantPast

    static func fetchDevin() async -> ProviderUsage {
        do {
            let cred: DevinCredential
            if let cached = devinCredCache {
                cred = cached
            } else {
                if Date() < devinCredBlockedUntil {
                    return devinCache ?? ProviderUsage(name: "Devin")
                }
                cred = try loadDevinCredential()
                devinCredCache = cred
            }
            let (status, data, _) = try await httpRequest(
                cred.apiServerURL + "/exa.seat_management_pb.SeatManagementService/GetUserStatus",
                method: "POST",
                headers: ["Connect-Protocol-Version": "1"],
                jsonBody: ["metadata": [
                    "api_key": cred.accessToken,
                    "ide_name": "windsurf", "ide_version": "3.10.67",
                    "extension_name": "windsurf", "extension_version": "3.10.67",
                    "locale": "en", "os_name": "macos", "os_arch": "arm64",
                ]])
            let err = jsonDict(data)
            if status == 401 || status == 403 || (err["code"] as? String == "unauthenticated") {
                devinCredCache = nil // token rotated/expired — re-read next poll
                throw UsageError.http(status, "Devin session rejected — sign in to the Devin app again")
            }
            guard status == 200, let plan = (err["userStatus"] as? [String: Any])?["planStatus"] as? [String: Any] else {
                throw UsageError.http(status, "Devin usage unavailable")
            }
            var u = ProviderUsage(name: "Devin")
            let planInfo = plan["planInfo"] as? [String: Any] ?? [:]
            let planName = planInfo["planName"] as? String
            // -1 = unmetered plan (Devin Pro reports quota pinned at 100 always).
            let monthly = (planInfo["monthlyPromptCredits"] as? Int)
                ?? (planInfo["monthlyPromptCredits"] as? String).flatMap(Int.init)
            if monthly == -1 {
                u.note = planName ?? "Plan"
                u.noteAccent = "unlimited"
            } else {
                func quota(_ remKey: String, _ resetKey: String, _ secs: TimeInterval) -> UsageWindow? {
                    guard let rem = plan[remKey] as? Double ?? (plan[remKey] as? Int).map(Double.init)
                            ?? (plan[remKey] as? String).flatMap(Double.init) else { return nil }
                    var w = UsageWindow(usedPercent: max(0, 100 - rem), windowSeconds: secs)
                    if let ts = plan[resetKey] as? Double ?? (plan[resetKey] as? String).flatMap(Double.init) {
                        w.resetsAt = Date(timeIntervalSince1970: ts)
                    }
                    return w
                }
                u.session = quota("dailyQuotaRemainingPercent", "dailyQuotaResetAtUnix", 86400)
                u.weekly = quota("weeklyQuotaRemainingPercent", "weeklyQuotaResetAtUnix", 604800)
                if !u.hasData { u.error = "Devin: this plan reports no quota data" }
            }
            if u.isVisible { devinCache = u }
            return devinCache ?? u
        } catch {
            if case UsageError.noCredentials = error {
                devinCredBlockedUntil = Date().addingTimeInterval(30 * 60)
            }
            if let cached = devinCache { return cached }
            var u = ProviderUsage(name: "Devin")
            u.error = error.localizedDescription
            u.action = (error as? UsageError)?.action
            if u.action == nil, case .http(let code, _) = error as? UsageError,
               code == 401 || code == 403 {
                u.action = .openApp("Devin")
            }
            return u
        }
    }

    // Popover action buttons. renewClaude bypasses the revive backoff (it's
    // user-triggered); runInTerminal opens Terminal with the command visible.
    static func perform(_ action: ProviderAction) {
        switch action {
        case .renewClaude:
            claudeReviveBlockedUntil = .distantPast
            _ = reviveClaudeToken()
        case .runInTerminal(let cmd):
            let safe = cmd.replacingOccurrences(of: "\"", with: "\\\"")
            let src = """
                tell application "Terminal" to activate
                tell application "Terminal" to do script "\(safe)"
                """
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
        case .openApp(let name):
            _ = runProcess("/usr/bin/open", ["-a", name])
        }
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

    // Statusline snapshot → ProviderUsage. nil = nothing usable pushed yet
    // (Claude Code hasn't rendered since install, or no rate_limits yet).
    private static func claudeFromSnapshot() -> ProviderUsage? {
        guard let snap = StatuslineBridge.snapshot(),
              let windows = snap["windows"] as? [String: Any] else { return nil }
        var u = ProviderUsage(name: "Claude")
        u.session = snapshotWindow(windows["five_hour"], seconds: 18000)
        u.weekly = snapshotWindow(windows["seven_day"], seconds: 604800)
        guard u.hasData else { return nil }
        if let ts = snap["observed_at"] as? Double {
            u.fetchedAt = Date(timeIntervalSince1970: ts)
        }
        // Stale checks → fall back to the API:
        //  • a reset boundary already crossed (data predates a rollover)
        //  • snapshot older than 6h — if the statusline isn't rendering (e.g.
        //    Claude only ever used via an IDE), the bridge must not pin stale
        //    numbers forever
        let now = Date()
        if let ts = snap["observed_at"] as? Double,
           now.timeIntervalSince1970 - ts > 6 * 3600 { return nil }
        for w in [u.session, u.weekly].compactMap({ $0 }) {
            if let r = w.resetsAt, r < now { return nil }
        }
        u.note = claudePlanName()
        return u
    }

    private static func snapshotWindow(_ any: Any?, seconds: TimeInterval) -> UsageWindow? {
        guard let w = any as? [String: Any] else { return nil }
        var win = UsageWindow(windowSeconds: seconds)
        win.usedPercent = (w["used_percentage"] as? Double)
            ?? (w["used_percentage"] as? Int).map(Double.init) ?? 0
        if let s = w["resets_at"] as? String { win.resetsAt = parseISO8601(s) }
        else if let ts = w["resets_at"] as? Double {
            win.resetsAt = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
        }
        return win
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

    // `others` lets a limit warning point at a tool that still has headroom.
    static func evaluate(_ u: ProviderUsage, others: [ProviderUsage] = []) {
        let d = UserDefaults.standard
        // First launch: defaults register as true
        let on = { d.object(forKey: $0) == nil ? true : d.bool(forKey: $0) }
        for (label, w) in [("session", u.session), ("weekly", u.weekly)] {
            guard let w else { continue }
            let key = "\(u.name) \(label)"
            if let reset = w.resetsAt {
                if on("meowbar.alertReset"), let prev = lastReset[key],
                   reset > prev.addingTimeInterval(60) {
                    notify("\(u.name) \(label) limit reset", body: "Fresh window started.")
                }
                lastReset[key] = reset
            }
            var level = 0
            if on("meowbar.alert95"), w.usedPercent >= 95 { level = 95 }
            else if on("meowbar.alert90"), w.usedPercent >= 90 { level = 90 }
            else if on("meowbar.alert75"), w.usedPercent >= 75 { level = 75 }
            let prev = lastLevel[key] ?? 0
            if level > prev {
                var body = w.resetsAt.map { "Resets \(Self.countdown(to: $0))." } ?? ""
                if level >= 90, let alt = others
                    .compactMap({ o in o.displayLeft.map { (o.name, $0) } })
                    .filter({ $0.1 >= 30 }).max(by: { $0.1 < $1.1 }) {
                    body += (body.isEmpty ? "" : " ") + "\(alt.0) has \(Int(alt.1))% left."
                }
                notify("\(u.name) \(label): \(Int(w.usedPercent))% used", body: body)
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

    static func countdown(to date: Date) -> String { Countdown.long(to: date) }
}

// MARK: - Claude statusline bridge
//
// Optionally installs `meowbar-statusline` as Claude Code's statusLine
// command. Claude Code then PUSHES fresh rate_limits on every render — no
// polling, no 429s, always current. The helper chains to the user's original
// statusline so their prompt is unchanged. Everything reversible: the prior
// settings.json is backed up and the original statusLine command is stored
// for chaining + restore.

enum StatuslineBridge {
    static let supportDir = NSHomeDirectory() + "/Library/Application Support/MeowBar"
    static let helperPath = supportDir + "/meowbar-statusline"
    static let snapshotPath = supportDir + "/claude-statusline.json"
    static let originalPath = supportDir + "/original-statusline.json"
    static let backupPath = supportDir + "/settings-backup.json"
    static let claudeSettingsPath = NSHomeDirectory() + "/.claude/settings.json"

    static var isInstalled: Bool {
        guard let data = FileManager.default.contents(atPath: claudeSettingsPath),
              let s = jsonDict(data) as [String: Any]?,
              let sl = s["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return cmd == helperPath
    }

    // Status a coworker can act on: installed vs broken (settings points at a
    // missing helper — e.g. app moved/deleted while enabled).
    static var isBroken: Bool {
        guard let data = FileManager.default.contents(atPath: claudeSettingsPath),
              let s = jsonDict(data) as [String: Any]?,
              let sl = s["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String,
              cmd == helperPath else { return false }
        return !FileManager.default.isExecutableFile(atPath: helperPath)
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)

        // 1. helper binary: copy out of the app bundle to a stable path
        guard let bundled = Bundle.main.path(forAuxiliaryExecutable: "meowbar-statusline")
                ?? Bundle.main.path(forResource: "meowbar-statusline", ofType: nil) else {
            throw UsageError.actionable("Bridge helper missing from the app bundle — rebuild MeowBar", nil)
        }
        try? fm.removeItem(atPath: helperPath)
        try fm.copyItem(atPath: bundled, toPath: helperPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)

        // 2. settings.json
        guard let data = fm.contents(atPath: claudeSettingsPath),
              var settings = jsonDict(data) as [String: Any]? else {
            throw UsageError.actionable("Can't read Claude Code's settings.json", nil)
        }
        // timestamped backup — restored on uninstall if needed
        try? fm.copyItem(atPath: claudeSettingsPath, toPath: backupPath)

        // 3. preserve any existing statusLine as the chain target. Already
        //    ours (re-install, e.g. from onboarding) → keep the stored
        //    original untouched, or the user's own status line is lost.
        let current = (settings["statusLine"] as? [String: Any])?["command"] as? String
        if current == helperPath {
            // nothing to record
        } else if let cmd = current, !cmd.isEmpty {
            let orig: [String: Any] = ["command": cmd]
            if let d = try? JSONSerialization.data(withJSONObject: orig) {
                try? d.write(to: URL(fileURLWithPath: originalPath))
            }
        } else {
            try? fm.removeItem(atPath: originalPath)
        }

        // 4. install ours
        settings["statusLine"] = ["type": "command", "command": helperPath]
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try out.write(to: URL(fileURLWithPath: claudeSettingsPath), options: .atomic)
    }

    static func uninstall() throws {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: claudeSettingsPath),
              var settings = jsonDict(data) as [String: Any]? else { return }
        // Only touch statusLine if it's ours — never clobber someone else's.
        if let sl = settings["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String, cmd == helperPath {
            if let od = fm.contents(atPath: originalPath),
               let orig = jsonDict(od) as [String: Any]?,
               let cmd = orig["command"] as? String {
                settings["statusLine"] = ["type": "command", "command": cmd]
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
                try? out.write(to: URL(fileURLWithPath: claudeSettingsPath), options: .atomic)
            }
        }
        try? fm.removeItem(atPath: originalPath)
    }

    // Latest pushed snapshot, if the bridge produced one.
    static func snapshot() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: snapshotPath) else { return nil }
        return jsonDict(data)
    }
}

// MARK: - codex app-server (JSON-RPC over stdio)

private final class ProcessIDRegistry: @unchecked Sendable {
    private var ids = Set<Int32>()
    private let lock = NSLock()

    func insert(_ id: Int32) {
        lock.lock(); defer { lock.unlock() }
        ids.insert(id)
    }

    func remove(_ id: Int32) {
        lock.lock(); defer { lock.unlock() }
        ids.remove(id)
    }

    func contains(_ id: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}

private let meowbarSpawned = ProcessIDRegistry()

// MARK: - Session clock

extension UsageService {
    // Opens Claude's 5h window now with a one-word prompt on the cheapest
    // model. Runs in an empty folder with user settings skipped (no hooks,
    // plugins or MCP servers fire), no tools, and nothing saved to disk.
    // Blocking — call off the main thread. True when Claude answered.
    static func startClaudeClock() -> Bool {
        guard let bin = cliPath("claude") else { return false }
        let dir = StatuslineBridge.supportDir + "/clock"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-p", "hi", "--model", "haiku", "--tools", "",
                       "--no-session-persistence", "--setting-sources", "project",
                       "--strict-mcp-config", "--disable-slash-commands",
                       "--output-format", "text"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        // GUI apps get a minimal PATH; an npm-installed `claude` needs node.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ((bin as NSString).deletingLastPathComponent) + ":/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        meowbarSpawned.insert(p.processIdentifier)
        defer { meowbarSpawned.remove(p.processIdentifier) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { p.terminate() }
        let reply = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !reply.isEmpty
    }
}

private enum CodexRPC {
    // One-shot session: initialize → initialized → account/read +
    // account/rateLimits/read, then terminate. Read-only; never touches
    // ~/.codex. Server notifications (remoteControl/status etc.) are ignored.
    static func run(binary: String) throws -> [Int: [String: Any]] {
        let p = Process(), inPipe = Pipe(), outPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["app-server"]
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            throw UsageError.noCredentials("Couldn't start Codex: \(error.localizedDescription)")
        }
        meowbarSpawned.insert(p.processIdentifier)
        // Watchdog: a stuck server must never block a refresh cycle.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { p.terminate() }
        defer {
            meowbarSpawned.remove(p.processIdentifier)
            p.terminate()
        }

        let stdin = inPipe.fileHandleForWriting
        func send(_ msg: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: msg) else { return }
            stdin.write(d)
            stdin.write("\n".data(using: .utf8)!)
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "meowbar", "version": "1.0"]]])

        var responses: [Int: [String: Any]] = [:]
        var buf = Data(), requested = false
        let reader = outPipe.fileHandleForReading
        while !responses.keys.contains(3) {
            let chunk = reader.availableData // blocks until data or EOF (watchdog)
            if chunk.isEmpty { break }
            buf += chunk
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = Data(buf[..<nl]); buf = Data(buf[buf.index(after: nl)...])
                guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let id = j["id"] as? Int { responses[id] = j }
                if !requested, responses[1] != nil {
                    requested = true
                    send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
                    send(["jsonrpc": "2.0", "id": 2, "method": "account/read", "params": [String: Any]()])
                    send(["jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read", "params": [String: Any]()])
                }
            }
        }
        guard responses[2] != nil, responses[3] != nil else {
            throw UsageError.http(0, "Codex didn't answer")
        }
        return responses
    }
}
