import Foundation

struct OAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let subscriptionType: String?
}

/// Account type. `subscription` = OAuth token for `/api/oauth/usage` (Pro/Max/Team
/// session %). `api` = an Admin API key (`sk-ant-admin...`) for the Usage & Cost
/// Admin API (month-to-date spend + tokens).
enum AccountKind: String, Codable {
    case subscription
    case api
}

enum CredentialsError: LocalizedError {
    case notFound
    case malformed
    case empty
    case standardKeyUnsupported

    var errorDescription: String? {
        switch self {
        case .notFound:              return L.credentialsNotFound
        case .malformed:             return L.credentialsMalformed
        case .empty:                 return L.credentialsEmpty
        case .standardKeyUnsupported: return L.standardKeyUnsupported
        }
    }
}

/// One stored Claude account. The token fields mirror the CLI's `claudeAiOauth`
/// object; `id`/`label` are added by this app for multi-account selection.
struct StoredAccount: Codable, Identifiable {
    let id: String
    var label: String
    var accessToken: String
    var refreshToken: String?
    var expiresAtMs: Double?
    var subscriptionType: String?
    var scopes: [String]?
    var kind: AccountKind?   // nil decodes as .subscription (back-compat with v2 files)

    var asCredentials: OAuthCredentials {
        OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: subscriptionType
        )
    }
}

/// Non-secret account summary for the UI (never carries tokens).
struct AccountInfo: Identifiable, Equatable {
    let id: String
    let label: String
    let subscriptionType: String?
    let kind: AccountKind
}

private struct AccountsFile: Codable {
    var version: Int
    var selectedId: String?
    var accounts: [StoredAccount]
}

/// Account-aware credential store, persisted to `accounts.json` (0600). Migrates
/// the legacy single-credential `credentials.json` on first read; falls back to
/// the CLI's `~/.claude/.credentials.json` (read-only) when no account is stored.
enum CredentialStore {
    // MARK: - Public API (non-secret surface)

    static func accountInfos() -> [AccountInfo] {
        currentFile().accounts.map { AccountInfo(id: $0.id, label: $0.label, subscriptionType: $0.subscriptionType, kind: $0.kind ?? .subscription) }
    }

    static let cliAccountId = "__cli__"

    /// Bundle for fetching one account's usage. In-process only — never logged/persisted here.
    struct AccountCredential {
        let id: String
        let kind: AccountKind
        let creds: OAuthCredentials
    }

    /// Credentials for every account (for refreshing all of them). Falls back to a
    /// single synthetic CLI account when nothing is stored yet.
    static func allCredentials() -> [AccountCredential] {
        let f = currentFile()
        if !f.accounts.isEmpty {
            return f.accounts.map { AccountCredential(id: $0.id, kind: $0.kind ?? .subscription, creds: $0.asCredentials) }
        }
        #if !APPSTORE
        if let creds = try? CredentialsLoader.load() {   // CLI ~/.claude/.credentials.json fallback
            return [AccountCredential(id: cliAccountId, kind: .subscription, creds: creds)]
        }
        #endif
        return []
    }

    /// True when only the CLI credential file is available (no stored accounts).
    static func cliPresent() -> Bool {
        currentFile().accounts.isEmpty && cliData() != nil
    }

    static func selectedId() -> String? {
        let f = currentFile()
        return f.accounts.contains(where: { $0.id == f.selectedId }) ? f.selectedId : f.accounts.first?.id
    }

    static func hasStored() -> Bool {
        !currentFile().accounts.isEmpty || cliData() != nil
    }

    static func select(_ id: String) {
        var f = currentFile()
        guard f.accounts.contains(where: { $0.id == id }) else { return }
        f.selectedId = id
        try? persist(f)
    }

    /// Add an account from pasted input (raw access token, or the full
    /// `claudeAiOauth` JSON). Selects it. Returns the new account id.
    @discardableResult
    static func addAccount(_ input: String, label: String) throws -> String {
        let parsed = try parseInput(input)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = StoredAccount(
            id: UUID().uuidString,
            label: trimmedLabel.isEmpty ? defaultLabel(for: parsed.subscriptionType, kind: parsed.kind) : trimmedLabel,
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresAtMs: parsed.expiresAtMs,
            subscriptionType: parsed.subscriptionType,
            scopes: parsed.scopes,
            kind: parsed.kind
        )
        var f = currentFile()
        f.accounts.append(account)
        f.selectedId = account.id
        try persist(f)
        return account.id
    }

    static func removeAccount(_ id: String) {
        var f = currentFile()
        f.accounts.removeAll { $0.id == id }
        if f.selectedId == id { f.selectedId = f.accounts.first?.id }
        try? persist(f)
    }

    /// Persist a refreshed token set onto a SPECIFIC account (`id` captured before
    /// the network refresh began), so a concurrent account switch/removal can't
    /// redirect the write. If `id` is nil and no account is stored yet
    /// (CLI-fallback case), materialize one. If the target account was removed
    /// mid-refresh, do nothing rather than clobber another account's tokens.
    static func updateSelected(id: String?, accessToken: String, refreshToken: String, expiresAtMs: Double, subscriptionType: String?) throws {
        var f = currentFile()
        if let id, let idx = f.accounts.firstIndex(where: { $0.id == id }) {
            f.accounts[idx].accessToken = accessToken
            f.accounts[idx].refreshToken = refreshToken
            f.accounts[idx].expiresAtMs = expiresAtMs
            if let sub = subscriptionType { f.accounts[idx].subscriptionType = sub }
        } else if f.accounts.isEmpty {
            let account = StoredAccount(
                id: UUID().uuidString,
                label: defaultLabel(for: subscriptionType),
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAtMs: expiresAtMs,
                subscriptionType: subscriptionType,
                scopes: defaultScopes,
                kind: .subscription
            )
            f.accounts.append(account)
            f.selectedId = account.id
        } else {
            return // target account removed during refresh — don't clobber another
        }
        try persist(f)
    }

    /// Remove all stored accounts (full log out). The CLI file is left untouched.
    static func clear() throws {
        let accounts = try accountsURL()
        if FileManager.default.fileExists(atPath: accounts.path) {
            try FileManager.default.removeItem(at: accounts)
        }
        let legacy = try legacyURL()
        if FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.removeItem(at: legacy)
        }
    }

    // MARK: - Internal (used by CredentialsLoader, same file)

    fileprivate static func selectedAccount() -> StoredAccount? {
        let f = currentFile()
        return f.accounts.first(where: { $0.id == f.selectedId }) ?? f.accounts.first
    }

    fileprivate static func cliData() -> Data? {
        #if APPSTORE
        return nil
        #else
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
        #endif
    }

    // MARK: - File handling

    private static let defaultScopes = ["org:create_api_key", "user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"]

    private static func defaultLabel(for subscriptionType: String?, kind: AccountKind = .subscription) -> String {
        if kind == .api { return subscriptionType?.capitalized ?? "API" }
        return subscriptionType.map { $0.capitalized } ?? L.accountDefaultLabel
    }

    private static func accountsURL() throws -> URL {
        try appSupportDir().appendingPathComponent("accounts.json")
    }
    private static func legacyURL() throws -> URL {
        try appSupportDir().appendingPathComponent("credentials.json")
    }
    private static func appSupportDir() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ClaudeMeter")
    }

    /// Read accounts.json; if absent, migrate the legacy single-credential file
    /// (one account) and persist; otherwise return an empty set.
    private static func currentFile() -> AccountsFile {
        if let url = try? accountsURL(),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(AccountsFile.self, from: data) {
            return file
        }
        if let migrated = legacyAccount() {
            let file = AccountsFile(version: 2, selectedId: migrated.id, accounts: [migrated])
            try? persist(file)
            return file
        }
        return AccountsFile(version: 2, selectedId: nil, accounts: [])
    }

    private static func legacyAccount() -> StoredAccount? {
        guard let url = try? legacyURL(),
              let data = try? Data(contentsOf: url),
              let parsed = try? parseInput(String(data: data, encoding: .utf8) ?? "")
        else { return nil }
        return StoredAccount(
            id: UUID().uuidString,
            label: defaultLabel(for: parsed.subscriptionType, kind: parsed.kind),
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresAtMs: parsed.expiresAtMs,
            subscriptionType: parsed.subscriptionType,
            scopes: parsed.scopes,
            kind: parsed.kind
        )
    }

    private static func persist(_ file: AccountsFile) throws {
        let url = try accountsURL()
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(file)

        // chmod the temp file to 0600 BEFORE it appears at the final path, so the
        // tokens are never briefly readable at the umask default (e.g. 0644).
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".accounts.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url) // rename preserves the 0600 temp perms
        }
    }

    private typealias Parsed = (accessToken: String, refreshToken: String?, expiresAtMs: Double?, subscriptionType: String?, scopes: [String]?, kind: AccountKind)

    /// Accept an Admin API key (`sk-ant-admin...` → API account), the full
    /// `claudeAiOauth` JSON, or a bare OAuth access token (→ subscription account).
    private static func parseInput(_ input: String) throws -> Parsed {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialsError.empty }
        if trimmed.hasPrefix("sk-ant-admin") {
            return (trimmed, nil, nil, nil, nil, .api)
        }
        // A standard API key can't drive any of our read paths (it's not an OAuth
        // token for /api/oauth/usage, nor an Admin key for the Usage/Cost API).
        if trimmed.hasPrefix("sk-ant-api") {
            throw CredentialsError.standardKeyUnsupported
        }
        if let data = trimmed.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return (token,
                    oauth["refreshToken"] as? String,
                    oauth["expiresAt"] as? Double,
                    oauth["subscriptionType"] as? String,
                    oauth["scopes"] as? [String],
                    .subscription)
        }
        return (trimmed, nil, nil, nil, nil, .subscription)
    }
}

enum CredentialsLoader {
    /// Selected account → CLI `~/.claude/.credentials.json` → throw .notFound.
    static func load() throws -> OAuthCredentials {
        if let account = CredentialStore.selectedAccount() {
            return account.asCredentials
        }
        if let creds = (CredentialStore.cliData()).flatMap({ try? parseCLI($0) }) {
            return creds
        }
        throw CredentialsError.notFound
    }

    private static func parseCLI(_ data: Data) throws -> OAuthCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw CredentialsError.malformed }
        return OAuthCredentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
