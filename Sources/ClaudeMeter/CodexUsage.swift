import Foundation

/// OpenAI Codex CLI rate-limit status, read from the local session logs.
///
/// Codex records the server's rate-limit response inside each `token_count`
/// event under `payload.rate_limits`. There is no usage API reachable with the
/// ChatGPT-mode token, so the newest logged snapshot is the best available
/// source — it only advances when Codex is actually used, hence `asOf`.
///
/// Verified on-disk schema: `payload.rate_limits` = {primary, secondary, plan_type, …}
/// where primary = 5h window (window_minutes 300), secondary = weekly (10080),
/// each with `used_percent` (0–100) and `resets_at` (epoch seconds).
struct CodexUsage {
    let primary: UsageWindow?     // rolling 5-hour window
    let secondary: UsageWindow?   // weekly window
    let asOf: Date                // timestamp of the snapshot (last Codex activity)
    let planType: String?
}

enum CodexUsageReader {
    /// UserDefaults key for the optional sessions-folder override. AppSettings
    /// writes this; the reader resolves it here so a configured path takes effect
    /// at launch (the periodic refresh reads it live) without extra wiring.
    static let sessionsPathDefaultsKey = "codexSessionsPath"

    /// Where to look for Codex session logs. Resolution order:
    ///   1. App setting `codexSessionsPath` (points directly at the sessions dir)
    ///   2. `CODEX_HOME` env var (the `.codex` root) → its `sessions` subdir
    ///   3. `~/.codex/sessions` (Codex CLI default)
    /// Note: a GUI app launched from Finder/login items won't inherit a shell's
    /// `CODEX_HOME`, so the setting (1) is the reliable override in that case.
    private static var sessionsRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: sessionsPathDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("sessions")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    /// Most recent rate-limit snapshot, or nil if Codex isn't present / has none.
    /// Runs file I/O — call off the main actor.
    static func latest() async -> CodexUsage? {
        guard let files = recentSessionFiles() else { return nil }
        // Files are newest-first; the first one carrying rate_limits holds the
        // latest snapshot (sessions are append-only), so stop once found.
        for url in files {
            var best: (date: Date, rl: [String: Any])?
            do {
                for try await line in url.lines {
                    guard let (date, rl) = rateLimits(line) else { continue }
                    if best == nil || date > best!.date { best = (date, rl) }
                }
            } catch { continue }
            if let best {
                return CodexUsage(
                    primary: window(best.rl["primary"]),
                    secondary: window(best.rl["secondary"]),
                    asOf: best.date,
                    planType: best.rl["plan_type"] as? String
                )
            }
        }
        return nil
    }

    private static func rateLimits(_ line: String) -> (date: Date, rl: [String: Any])? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let rl = payload["rate_limits"] as? [String: Any],
              let ts = root["timestamp"] as? String,
              let date = parseTimestamp(ts)
        else { return nil }
        return (date, rl)
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let used = (dict["used_percent"] as? Double) ?? (dict["used_percent"] as? Int).map(Double.init)
        guard let used, used >= 0 else { return nil }
        let resetEpoch = (dict["resets_at"] as? Double) ?? (dict["resets_at"] as? Int).map(Double.init)
        return UsageWindow(utilization: used, resetsAt: resetEpoch.map { Date(timeIntervalSince1970: $0) })
    }

    /// `.jsonl` session files, newest-mtime first (capped — only the latest matters).
    /// TODO: enumerates the whole sessions tree before capping; add a depth limit
    /// if a heavy long-term user's session history grows very large.
    private static func recentSessionFiles() -> [URL]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsRoot.path),
              let walker = fm.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, mtime))
        }
        guard !files.isEmpty else { return nil }
        return files.sorted { $0.mtime > $1.mtime }.prefix(20).map(\.url)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
