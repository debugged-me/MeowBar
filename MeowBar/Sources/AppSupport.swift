import Foundation
import CoreGraphics

// Small JSON files in ~/Library/Application Support/MeowBar: last-good usage
// (a relaunch never opens on a blank or an error) and the usage history.
enum AppFiles {
    static let dir = StatuslineBridge.supportDir
    static let usageCache = dir + "/usage-cache.json"
    static let history = dir + "/history.json"
    static let taskLog = dir + "/tasklog.json"

    static func load<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to path: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(value) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// `MeowBar --json` — the running app's last-good numbers for scripts and shell
// prompts. Reads the cache file only; never touches credentials or the network.
enum UsageJSON {
    static func printCached() -> Bool {
        guard let cache = AppFiles.load([ProviderUsage].self, from: AppFiles.usageCache) else {
            FileHandle.standardError.write(Data("No usage cached yet — launch MeowBar first.\n".utf8))
            return false
        }
        let iso = ISO8601DateFormatter()
        func window(_ w: UsageWindow?) -> Any {
            guard let w else { return NSNull() }
            return [
                "used_percent": w.usedPercent,
                "left_percent": max(0, 100 - w.usedPercent),
                "resets_at": w.resetsAt.map { iso.string(from: $0) } ?? NSNull(),
                "window_seconds": w.windowSeconds ?? NSNull(),
            ] as [String: Any]
        }
        let providers = cache.map { $0.normalized() }.map { u -> [String: Any] in
            ["name": u.name,
             "plan": u.note ?? NSNull(),
             "fetched_at": iso.string(from: u.fetchedAt),
             "session": window(u.session),
             "weekly": window(u.weekly),
             "extras": (u.extras ?? []).map { ["label": $0.label, "window": window($0.window)] }]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["providers": providers],
                                                     options: [.prettyPrinted, .sortedKeys]) else { return false }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return true
    }
}

// Light update check: a version.json (written by build.sh next to
// MeowBar.dmg) fetched once a day. The feed is the MeowBarUpdateURL key in
// Info.plist — empty means checks are off.
struct UpdateInfo: Codable, Equatable {
    var version: String
    var url: String       // usually relative to the feed: "MeowBar.dmg"
    var notes: String?
}

enum UpdateCheck {
    static var feedURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "MeowBarUpdateURL") as? String,
              !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func downloadURL(_ info: UpdateInfo) -> URL? {
        URL(string: info.url, relativeTo: feedURL)?.absoluteURL
    }

    static func check() async -> UpdateInfo? {
        guard let feed = feedURL else { return nil }
        var req = URLRequest(url: feed)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(UpdateInfo.self, from: data),
              AppVersion.isNewer(info.version, than: currentVersion) else { return nil }
        return info
    }
}

// "Are you at the Mac?" — no permission needed for either signal.
enum UserPresence {
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
