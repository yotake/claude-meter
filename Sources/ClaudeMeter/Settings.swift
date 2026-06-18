import Foundation
import SwiftUI

/// Status used to drive the menu bar icon/label color and the session forecast
/// line. Derived from BOTH current utilization and a burn-rate projection.
enum UsageStatus {
    case ok, warning, critical

    var color: Color {
        switch self {
        case .ok:       return .primary
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    /// Menu bar SF Symbol. Critical swaps to a warning glyph so the state stays
    /// visible even where the menu bar renders icons as monochrome templates
    /// (color tint can be suppressed there; the text color still reflects it).
    var symbolName: String {
        switch self {
        case .ok, .warning: return "gauge.with.needle"
        case .critical:     return "exclamationmark.triangle.fill"
        }
    }
}

/// Burn-rate forecast for the rolling 5-hour session window.
///
/// Linear projection: assumes the current average pace continues. The real
/// window slides (old usage ages out), so this tends to OVER-estimate — a
/// deliberately conservative early warning rather than a precise predictor.
struct SessionForecast {
    let status: UsageStatus
    let projectedAtReset: Double   // projected utilization % at window reset
    let exhaustDate: Date?         // when 100% is reached at the current pace
    let willExhaustBeforeReset: Bool

    /// Claude's session window length (5 hours).
    static let windowLength: TimeInterval = 5 * 3600

    /// Don't project until at least this much of the window has elapsed. A small
    /// early sample (e.g. one burst 3 minutes after reset) projects to absurd
    /// numbers; below this we judge by current utilization only.
    static let minElapsedForProjection: TimeInterval = 30 * 60

    static func compute(window: UsageWindow, warnPct: Double, critPct: Double, now: Date = Date()) -> SessionForecast {
        let u = max(0, window.utilization)
        // Tolerate the user dragging crit below warn: treat them as a sorted pair.
        let warn = min(warnPct, critPct)
        let crit = max(warnPct, critPct)

        // Without a reset time, or too early in the window to project reliably,
        // judge by current utilization only.
        func currentOnly() -> SessionForecast {
            SessionForecast(
                status: status(current: u, projected: u, exhaustsBeforeReset: false, warnPct: warn, critPct: crit),
                projectedAtReset: u,
                exhaustDate: nil,
                willExhaustBeforeReset: false
            )
        }

        guard let reset = window.resetsAt else { return currentOnly() }
        let timeToReset = max(0, reset.timeIntervalSince(now))
        let elapsed = windowLength - timeToReset
        guard elapsed >= minElapsedForProjection, u > 0 else { return currentOnly() }

        // burnRate = u / elapsed  (% per second)
        let projected = u * windowLength / elapsed
        let secondsToExhaust = (100 - u) * elapsed / u
        let willExhaust = u < 100 && secondsToExhaust < timeToReset
        let exhaustDate = u < 100 ? now.addingTimeInterval(secondsToExhaust) : now

        return SessionForecast(
            status: status(current: u, projected: projected, exhaustsBeforeReset: willExhaust, warnPct: warn, critPct: crit),
            projectedAtReset: projected,
            exhaustDate: exhaustDate,
            willExhaustBeforeReset: willExhaust
        )
    }

    private static func status(current u: Double, projected: Double, exhaustsBeforeReset: Bool, warnPct: Double, critPct: Double) -> UsageStatus {
        if u >= critPct || exhaustsBeforeReset { return .critical }
        if u >= warnPct || projected >= warnPct { return .warning }
        return .ok
    }
}

/// User preferences, persisted in UserDefaults. Changes publish immediately so
/// the popover and menu bar update without a relaunch.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var showSession: Bool   { didSet { defaults.set(showSession, forKey: Keys.showSession) } }
    @Published var showWeeklyAll: Bool { didSet { defaults.set(showWeeklyAll, forKey: Keys.showWeeklyAll) } }
    @Published var showSonnet: Bool    { didSet { defaults.set(showSonnet, forKey: Keys.showSonnet) } }
    @Published var showOpus: Bool      { didSet { defaults.set(showOpus, forKey: Keys.showOpus) } }
    /// Show each limit's reset time as a visible line (vs hover-only) in the popover.
    @Published var showResetTime: Bool { didSet { defaults.set(showResetTime, forKey: Keys.showResetTime) } }
    @Published var showCodex: Bool     { didSet { defaults.set(showCodex, forKey: Keys.showCodex) } }
    @Published var showClaudeInMenuBar: Bool { didSet { defaults.set(showClaudeInMenuBar, forKey: Keys.showClaudeInMenuBar) } }
    @Published var showCodexInMenuBar: Bool { didSet { defaults.set(showCodexInMenuBar, forKey: Keys.showCodexInMenuBar) } }
    @Published var barWarnPct: Double  { didSet { defaults.set(barWarnPct, forKey: Keys.barWarnPct) } }
    @Published var barCritPct: Double  { didSet { defaults.set(barCritPct, forKey: Keys.barCritPct) } }
    /// Optional override for the Codex sessions folder; empty = auto. Resolved in
    /// `CodexUsageReader` (setting > CODEX_HOME > ~/.codex/sessions).
    @Published var codexSessionsPath: String { didSet { defaults.set(codexSessionsPath, forKey: Keys.codexSessionsPath) } }

    init() {
        // Use a local reference so the nested helpers don't capture `self`
        // before all stored properties are initialized.
        let store = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            store.object(forKey: key) == nil ? fallback : store.double(forKey: key)
        }
        showSession   = bool(Keys.showSession, true)
        showWeeklyAll = bool(Keys.showWeeklyAll, true)
        showSonnet    = bool(Keys.showSonnet, true)
        showOpus      = bool(Keys.showOpus, true)
        showResetTime = bool(Keys.showResetTime, true)
        showCodex     = bool(Keys.showCodex, true)
        showClaudeInMenuBar = bool(Keys.showClaudeInMenuBar, true)
        showCodexInMenuBar = bool(Keys.showCodexInMenuBar, true)
        barWarnPct    = double(Keys.barWarnPct, 60)
        barCritPct    = double(Keys.barCritPct, 85)
        codexSessionsPath = store.string(forKey: Keys.codexSessionsPath) ?? ""
    }

    private enum Keys {
        static let showSession   = "showSession"
        static let showWeeklyAll = "showWeeklyAll"
        static let showSonnet    = "showSonnet"
        static let showOpus      = "showOpus"
        static let showResetTime = "showResetTime"
        static let showCodex     = "showCodex"
        static let showClaudeInMenuBar = "showClaudeInMenuBar"
        static let showCodexInMenuBar = "showCodexInMenuBar"
        static let barWarnPct    = "barWarnPct"
        static let barCritPct    = "barCritPct"
        // Single source of truth lives on the reader that consumes it.
        static let codexSessionsPath = CodexUsageReader.sessionsPathDefaultsKey
    }
}
