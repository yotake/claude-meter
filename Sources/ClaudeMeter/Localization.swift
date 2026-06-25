import Foundation

/// Two-language localization (Japanese / English) chosen at runtime from the OS
/// language preference. Japanese when the preferred language is Japanese;
/// English otherwise (English is also the fallback for any other language).
///
/// The choice is read at access time (not cached) so it always reflects the
/// current `Locale.preferredLanguages`, which macOS derives from the OS / app
/// language setting (and the `-AppleLanguages` argument domain).
enum AppLanguage {
    case japanese
    case english

    /// UserDefaults key shared with `AppSettings.language`, so `L` and date
    /// formatting can resolve the chosen language without threading the settings
    /// object through every call site.
    static let overrideKey = "language"

    static var current: AppLanguage {
        switch UserDefaults.standard.string(forKey: overrideKey) {
        case LanguagePref.ja.rawValue: return .japanese
        case LanguagePref.en.rawValue: return .english
        default:   // .system / unset → follow the OS preferred language
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ja") ? .japanese : .english
        }
    }

    /// Locale used for date / weekday formatting so it matches the UI language.
    var locale: Locale {
        switch self {
        case .japanese: return Locale(identifier: "ja_JP")
        case .english:  return Locale(identifier: "en_US")
        }
    }
}

/// UI-language preference. `.system` follows the OS language; `.ja` / `.en`
/// force that language regardless of the OS setting. Persisted via its rawValue.
enum LanguagePref: String, CaseIterable {
    case system, ja, en

    var displayName: String {
        switch self {
        case .system: return L.langSystem
        case .ja:     return "日本語"
        case .en:     return "English"
        }
    }
}

/// Central, runtime-localized string table. Every user-facing string lives here;
/// call sites reference `L.…` so no Japanese (or English) literal is hardcoded
/// elsewhere in the app.
enum L {
    private static var ja: Bool { AppLanguage.current == .japanese }

    // MARK: - Header / sections
    static var currentSession: String { ja ? "現在のセッション" : "Current session" }
    static var weeklyLimits: String   { ja ? "週間リミット" : "Weekly limits" }
    static var allModels: String      { ja ? "全モデル" : "All models" }
    static var sonnetOnly: String     { ja ? "Sonnet のみ" : "Sonnet only" }
    static var opusOnly: String       { ja ? "Opus のみ" : "Opus only" }
    // Compact per-account limit labels
    static var limSession: String     { ja ? "セッション(5時間)" : "Session (5h)" }
    static var limWeekly: String      { ja ? "週間(全モデル)" : "Weekly (All models)" }
    static var limSonnet: String      { "Sonnet" }
    static var limOpus: String        { "Opus" }
    static var loading: String        { ja ? "読み込み中…" : "Loading…" }

    // MARK: - Usage rows
    static func resetsAt(_ weekday: String) -> String {
        ja ? "\(weekday) にリセット" : "Resets \(weekday)"
    }
    static func updatedAt(_ time: String) -> String {
        ja ? "最終更新: \(time)" : "Updated: \(time)"
    }
    static func percentUsed(_ percent: Int) -> String {
        ja ? "\(percent)% 使用" : "\(percent)% used"
    }

    // MARK: - Credentials section
    static var runInTerminal: String { ja ? "ターミナルで下記を実行してコピーし、貼り付け:" : "Run this in Terminal, copy the output, then paste it:" }
    static var copyCommand: String   { ja ? "コマンドをコピー" : "Copy command" }
    static var pasteToken: String    { ja ? "トークンを貼り付け" : "Paste token" }
    static var cancel: String        { ja ? "キャンセル" : "Cancel" }
    static var save: String          { ja ? "保存" : "Save" }
    static var authenticated: String { ja ? "認証済み(自動更新)" : "Authenticated (auto-refresh)" }
    static var updateToken: String   { ja ? "トークン更新" : "Update token" }
    static var logout: String        { ja ? "ログアウト" : "Log out" }
    static var quit: String          { ja ? "終了" : "Quit" }
    static var support: String       { ja ? "開発を支援" : "Support" }
    static var madeBy: String        { ja ? "無料 · 二児の父が個人開発 ❤️" : "Free · made by a dad of two ❤️" }

    // MARK: - Accounts
    static var add: String                { ja ? "追加" : "Add" }
    static var addAccount: String         { ja ? "アカウントを追加" : "Add account" }
    static var accountLabel: String       { ja ? "アカウント名(任意)" : "Account name (optional)" }
    static var accountDefaultLabel: String { ja ? "アカウント" : "Account" }
    static var remove: String             { ja ? "削除" : "Remove" }

    // MARK: - Settings
    static var settings: String           { ja ? "設定" : "Settings" }
    static var showSession: String        { ja ? "セッションを表示" : "Show session" }
    static var showWeeklyAll: String      { ja ? "週間(全モデル)を表示" : "Show weekly (all models)" }
    static var showSonnet: String         { ja ? "Sonnet を表示" : "Show Sonnet" }
    static var showOpus: String           { ja ? "Opus を表示" : "Show Opus" }
    static var showResetTime: String      { ja ? "リセット時刻を表示" : "Show reset time" }
    static var language: String           { ja ? "言語" : "Language" }
    static var langSystem: String         { ja ? "システム" : "System" }
    static var barColorThresholds: String { ja ? "バーの色しきい値" : "Bar color thresholds" }
    static var warnLabel: String          { ja ? "警告" : "Warn" }
    static var critLabel: String          { ja ? "危険" : "Critical" }

    // MARK: - Codex
    static var codexTitle: String   { ja ? "Codex レート制限" : "Codex rate limits" }
    static var codexSession: String { ja ? "セッション(5時間)" : "Session (5h)" }
    static var codexWeekly: String  { ja ? "週間" : "Weekly" }
    static var showCodex: String    { ja ? "Codex を表示" : "Show Codex" }
    static var showClaudeInMenuBar: String { ja ? "Claude をメニューバーに表示" : "Show Claude in menu bar" }
    static var showCodexInMenuBar: String { ja ? "Codex をメニューバーに表示" : "Show Codex in menu bar" }
    static var codexSessionsPath: String { ja ? "Codex セッションフォルダ" : "Codex sessions folder" }
    static var codexSessionsPathPlaceholder: String { ja ? "例: /path/to/.codex/sessions" : "e.g. /path/to/.codex/sessions" }
    static var codexSessionsPathHint: String {
        ja ? "空欄で自動 (CODEX_HOME → ~/.codex/sessions)。Enter で適用。"
           : "Empty = auto (CODEX_HOME → ~/.codex/sessions). Press Enter to apply."
    }

    // MARK: - API billing account
    static var apiUsageTitle: String { ja ? "API 使用量 (今月)" : "API usage (this month)" }
    static var apiSpend: String      { ja ? "支出" : "Spend" }
    static var apiTokensInOut: String { ja ? "入力/出力トークン" : "Input/output tokens" }
    static var apiCache: String      { ja ? "キャッシュ 読/書" : "Cache read/write" }
    static var apiUsageNote: String  { ja ? "Admin API より。残高ではなく支出（Priority Tier 除く）。"
                                          : "From the Admin API — spend (not balance), excludes Priority Tier." }
    static var adminKeyHint: String  { ja ? "または Claude API の Admin キー(sk-ant-admin...)を貼り付けると今月の支出を表示"
                                          : "Or paste a Claude API Admin key (sk-ant-admin...) to track this month's spend" }
    static func codexAsOf(_ time: String) -> String {
        ja ? "最終取得: \(time)（Codex 最終利用時点）" : "As of \(time) (last Codex activity)"
    }

    // MARK: - Forecast
    static func onPaceToLimit(_ time: String) -> String {
        ja ? "このペースで \(time) に上限到達" : "On pace to hit the limit at \(time)"
    }
    static func projectedByReset(_ percent: Int) -> String {
        ja ? "このペースだとリセット時 約\(percent)%" : "~\(percent)% by reset at this pace"
    }

    // MARK: - Errors: UsageError
    static var tokenInvalid: String {
        ja ? "トークンが無効です。`claude` を一度起動して再認証してください。"
           : "Token is invalid. Launch `claude` once to re-authenticate."
    }
    static func rateLimited(retryAfterSeconds retry: Int?) -> String {
        if let retry, retry > 0 {
            if ja {
                let when = retry < 60 ? "\(retry)秒後" : "約\(Int((Double(retry) / 60).rounded())) 分後"
                return "レート制限中です (HTTP 429)。\(when)に更新(↻)を押してください。"
            }
            let when = retry < 60 ? "in \(retry)s" : "in ~\(Int((Double(retry) / 60).rounded())) min"
            return "Rate limited (HTTP 429). Press refresh (↻) \(when)."
        }
        return ja ? "レート制限中です (HTTP 429)。しばらく待ってから更新(↻)を押してください。"
                  : "Rate limited (HTTP 429). Wait a moment, then press refresh (↻)."
    }
    static func apiError(_ code: Int) -> String {
        ja ? "API エラー (HTTP \(code))" : "API error (HTTP \(code))"
    }
    static var apiMalformed: String {
        ja ? "API レスポンスを解析できませんでした。" : "Could not parse the API response."
    }
    static var adminUnauthorized: String {
        ja ? "Admin API キーが無効か権限がありません(sk-ant-admin が必要)。"
           : "Admin API key is invalid or lacks permission (sk-ant-admin required)."
    }

    // MARK: - Errors: OAuthError
    static var authExpired: String {
        ja ? "認証の有効期限が切れました。再ログインしてください。"
           : "Authentication has expired. Please log in again."
    }
    static func tokenRequestFailed(_ status: Int, _ body: String) -> String {
        ja ? "トークン取得エラー (HTTP \(status)): \(body)"
           : "Token request failed (HTTP \(status)): \(body)"
    }
    static func networkError(_ detail: String) -> String {
        ja ? "ネットワークエラー: \(detail)" : "Network error: \(detail)"
    }
    static var tokenResponseMalformed: String {
        ja ? "トークンレスポンスを解析できませんでした。" : "Could not parse the token response."
    }

    // MARK: - Errors: CredentialsError
    static var credentialsNotFound: String {
        ja ? "Claude Code の認証情報が見つかりません。`claude` にログインしてください。"
           : "Claude Code credentials not found. Log in with `claude`."
    }
    static var credentialsMalformed: String {
        ja ? "認証情報の形式を解析できませんでした。" : "Could not parse the credentials format."
    }
    static var credentialsEmpty: String {
        ja ? "アクセストークンを入力してください。" : "Please enter an access token."
    }
    static var standardKeyUnsupported: String {
        ja ? "標準APIキー(sk-ant-api...)は非対応です。残高/支出の取得には Admin キー(sk-ant-admin...)が必要です。"
           : "Standard API keys (sk-ant-api...) aren't supported. Spend tracking needs an Admin key (sk-ant-admin...)."
    }
}
