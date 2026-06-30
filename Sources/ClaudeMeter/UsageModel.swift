import Foundation
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var isDemo = false
    @Published var subscriptionType: String?
    @Published var hasStoredCredentials: Bool = CredentialStore.hasStored()
    @Published var needsLogin: Bool = false
    /// Codex rate-limit snapshot from local logs (nil if Codex isn't present).
    @Published var codex: CodexUsage?
    @Published var accounts: [AccountInfo] = CredentialStore.accountInfos()
    @Published var selectedAccountId: String? = CredentialStore.selectedId()

    // Per-account data (keyed by account id), so every account's limits show at once.
    @Published var accountUsages: [String: Usage] = [:]
    @Published var accountApiUsage: [String: ApiUsage] = [:]
    @Published var accountErrors: [String: String] = [:]

    /// Selected account's data, used for the menu bar label.
    var usage: Usage? { selectedAccountId.flatMap { accountUsages[$0] } }
    var apiUsage: ApiUsage? { selectedAccountId.flatMap { accountApiUsage[$0] } }

    /// Kind of the currently selected account (subscription vs API billing).
    var selectedAccountKind: AccountKind {
        accounts.first { $0.id == selectedAccountId }?.kind ?? .subscription
    }

    init() {
        reloadAccounts()
        #if APPSTORE
        if accounts.isEmpty { loadDemoData() }
        #endif
    }

    #if APPSTORE
    /// Populate two representative subscription accounts so App Store reviewers
    /// and new users can explore the full UI without a real token.
    func loadDemoData() {
        let week = Date().addingTimeInterval(3 * 86400)
        accounts = [
            AccountInfo(id: "demo-a", label: "Team",     subscriptionType: "team", kind: .subscription),
            AccountInfo(id: "demo-b", label: "Personal", subscriptionType: "pro",  kind: .subscription),
        ]
        accountUsages = [
            "demo-a": Usage(
                fiveHour: UsageWindow(utilization: 42, resetsAt: Date().addingTimeInterval(2 * 3600 + 12 * 60)),
                sevenDay: UsageWindow(utilization: 63, resetsAt: week),
                sevenDaySonnet: UsageWindow(utilization: 21, resetsAt: week),
                sevenDayOpus: nil,
                fetchedAt: Date()
            ),
            "demo-b": Usage(
                fiveHour: UsageWindow(utilization: 8, resetsAt: Date().addingTimeInterval(3 * 3600)),
                sevenDay: UsageWindow(utilization: 31, resetsAt: week),
                sevenDaySonnet: UsageWindow(utilization: 12, resetsAt: week),
                sevenDayOpus: nil,
                fetchedAt: Date()
            ),
        ]
        selectedAccountId = "demo-a"
        subscriptionType  = "team"
        needsLogin        = false
        errorMessage      = nil
        isDemo            = true
        accountErrors     = [:]
        accountApiUsage   = [:]
    }
    #endif

    // The usage endpoint rate-limits aggressive polling; >=180s is safe.
    private let refreshInterval: TimeInterval = 300
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()  // refresh() self-schedules the next tick based on the result
    }

    /// Schedule the next refresh. Normally `refreshInterval`; on HTTP 429 we honor
    /// the server's Retry-After (+60s buffer) so the app auto-recovers without
    /// compounding the rate limit.
    private func scheduleNext(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// On 429, wait the server-provided Retry-After (+60s); fall back to the normal
    /// interval if the server reports 0/unknown.
    private func rateLimitDelay(_ retryAfterSeconds: Int?) -> TimeInterval {
        let base = retryAfterSeconds.map(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? refreshInterval
        return base + 60
    }

    // MARK: - Usage refresh

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        refreshCodex()
        Task { @MainActor in
            var nextDelay = refreshInterval
            defer {
                isLoading = false
                scheduleNext(after: nextDelay)
            }

            let all = CredentialStore.allCredentials()
            guard !all.isEmpty else {
                #if APPSTORE
                loadDemoData()
                #else
                needsLogin = true
                errorMessage = CredentialsError.notFound.errorDescription
                accountUsages = [:]; accountApiUsage = [:]; accountErrors = [:]
                #endif
                return
            }
            isDemo = false
            needsLogin = false
            errorMessage = nil

            // Fetch every account; subscription → /api/oauth/usage, api → Admin spend.
            var usages: [String: Usage] = [:]
            var apis: [String: ApiUsage] = [:]
            var errs: [String: String] = [:]
            var rateLimitRetry: Int??  = .none   // outer nil = no rate limit; inner = retry-after
            for acct in all {
                if acct.kind == .api {
                    do { apis[acct.id] = try await AdminUsageClient.fetch(adminKey: acct.creds.accessToken) }
                    catch AdminUsageError.unauthorized { errs[acct.id] = AdminUsageError.unauthorized.errorDescription }
                    catch { errs[acct.id] = error.localizedDescription }
                } else {
                    switch await fetchSubscriptionUsage(accountId: acct.id, creds: acct.creds) {
                    case .usage(let u):                  usages[acct.id] = u
                    case .rateLimited(let retry, let m): rateLimitRetry = .some(retry); errs[acct.id] = m
                    case .failed(let m):                 errs[acct.id] = m
                    }
                }
            }

            accountUsages = usages
            accountApiUsage = apis
            accountErrors = errs
            subscriptionType = accounts.first { $0.id == selectedAccountId }?.subscriptionType
            if case .some(let retry) = rateLimitRetry { nextDelay = rateLimitDelay(retry) }
        }
    }

    private enum SubscriptionOutcome {
        case usage(Usage)
        case rateLimited(Int?, String)
        case failed(String)
    }

    /// Fetch one subscription account's usage, refreshing its OAuth token (proactive
    /// + one reactive retry) and writing the refreshed token back to THAT account.
    private func fetchSubscriptionUsage(accountId: String, creds: OAuthCredentials) async -> SubscriptionOutcome {
        var activeCreds = creds

        func store(_ tokens: TokenResponse) -> OAuthCredentials {
            let expiresAtMs = Date().timeIntervalSince1970 * 1000 + tokens.expiresInSeconds * 1000
            // The CLI credential file is read-only for us — don't persist back to it
            // (a synthetic "__cli__" id isn't a real stored account).
            if accountId != CredentialStore.cliAccountId {
                try? CredentialStore.updateSelected(
                    id: accountId,
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken,
                    expiresAtMs: expiresAtMs,
                    subscriptionType: creds.subscriptionType
                )
            }
            return OAuthCredentials(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                    expiresAt: Date(timeIntervalSince1970: expiresAtMs / 1000),
                                    subscriptionType: creds.subscriptionType)
        }

        // Proactive refresh when the token expires within 5 minutes.
        if let rt = creds.refreshToken, let exp = creds.expiresAt, exp.timeIntervalSinceNow <= 300 {
            do { activeCreds = store(try await OAuthClient.refresh(refreshToken: rt)) }
            catch OAuthError.invalidGrant { return .failed(OAuthError.invalidGrant.errorDescription ?? "") }
            catch { /* non-fatal: try the existing token */ }
        }

        do {
            return .usage(try await UsageClient.fetch(token: activeCreds.accessToken))
        } catch UsageError.unauthorized {
            // One reactive refresh + retry.
            guard let rt = activeCreds.refreshToken else { return .failed(UsageError.unauthorized.errorDescription ?? "") }
            do {
                let refreshed = store(try await OAuthClient.refresh(refreshToken: rt))
                do { return .usage(try await UsageClient.fetch(token: refreshed.accessToken)) }
                catch UsageError.unauthorized { return .failed(UsageError.unauthorized.errorDescription ?? "") }
                catch UsageError.rateLimited(let retry) { return .rateLimited(retry, UsageError.rateLimited(retryAfterSeconds: retry).errorDescription ?? "") }
                catch { return .failed(error.localizedDescription) }
            } catch OAuthError.invalidGrant { return .failed(OAuthError.invalidGrant.errorDescription ?? "") }
            catch { return .failed(error.localizedDescription) }
        } catch UsageError.rateLimited(let retry) {
            return .rateLimited(retry, UsageError.rateLimited(retryAfterSeconds: retry).errorDescription ?? "")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Credential management

    /// Add an account from pasted input (a raw access token, or the full
    /// `claudeAiOauth` JSON from the `claude` CLI's keychain entry). Selects it
    /// and triggers an immediate refresh.
    func addAccount(_ input: String, label: String) {
        do {
            try CredentialStore.addAccount(input, label: label)
            reloadAccounts()
            hasStoredCredentials = true
            needsLogin = false
            isDemo = false
            errorMessage = nil
            refresh()   // re-fetches all accounts, populating the new one
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Switch which account drives the menu bar label. All accounts' bars are
    /// already shown, so no refetch is needed.
    func selectAccount(_ id: String) {
        guard id != selectedAccountId else { return }
        CredentialStore.select(id)
        reloadAccounts()
        // If this account hasn't been fetched yet (e.g. just added), fetch now.
        if accountUsages[id] == nil && accountApiUsage[id] == nil && accountErrors[id] == nil {
            refresh()
        }
    }

    /// Remove one account; drop its cached data. Logs out if none remain.
    func removeAccount(_ id: String) {
        CredentialStore.removeAccount(id)
        reloadAccounts()
        hasStoredCredentials = CredentialStore.hasStored()
        accountUsages[id] = nil
        accountApiUsage[id] = nil
        accountErrors[id] = nil
        if accounts.isEmpty {
            #if APPSTORE
            loadDemoData()
            #else
            needsLogin = true
            timer?.invalidate()
            timer = nil
            #endif
        }
    }

    /// Log out of all accounts and require re-login.
    func clearCredentials() {
        do {
            try CredentialStore.clear()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        reloadAccounts()
        hasStoredCredentials = false
        needsLogin = true
        accountUsages = [:]
        accountApiUsage = [:]
        accountErrors = [:]
        // Stop idle polling while logged out; addAccount() restarts it via refresh().
        timer?.invalidate()
        timer = nil
    }

    private func reloadAccounts() {
        var infos = CredentialStore.accountInfos()
        // Surface the CLI credential as a synthetic account so its bars can show.
        if infos.isEmpty && CredentialStore.cliPresent() {
            infos = [AccountInfo(id: CredentialStore.cliAccountId, label: "Claude", subscriptionType: nil, kind: .subscription)]
        }
        accounts = infos
        selectedAccountId = CredentialStore.selectedId() ?? infos.first?.id
    }

    /// Menu bar label: covers all accounts in order, joined with " · ".
    /// Subscription accounts: "\(utilization)%"; API accounts: "$\(cost)" or "API".
    /// Accounts with no session data yet are skipped. Returns "–" when no account
    /// has renderable data.
    var menuBarText: String {
        var parts: [String] = []
        for account in accounts {
            if account.kind == .api {
                if let cost = accountApiUsage[account.id]?.monthCostUSD {
                    parts.append("$\(Int(cost.rounded()))")
                } else {
                    parts.append("API")
                }
            } else {
                guard let session = accountUsages[account.id]?.fiveHour else { continue }
                parts.append("\(Int(session.utilization.rounded()))%")
            }
        }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }

    /// Burn-rate status across ALL subscription accounts — the most severe wins
    /// (critical > warning > ok). Used to color the menu bar icon/label.
    /// Returns `.ok` when no subscription account has session data yet.
    func menuBarStatus(warnPct: Double, critPct: Double) -> UsageStatus {
        var result: UsageStatus = .ok
        for account in accounts where account.kind == .subscription {
            guard let session = accountUsages[account.id]?.fiveHour else { continue }
            let status = SessionForecast.compute(window: session, warnPct: warnPct, critPct: critPct).status
            switch status {
            case .critical:
                return .critical   // can't get worse; short-circuit
            case .warning where result == .ok:
                result = .warning
            default:
                break
            }
        }
        return result
    }

    /// Recompute the Codex rate-limit snapshot off the main actor (nonisolated reader).
    func refreshCodex() {
        Task { [weak self] in
            let codex = await CodexUsageReader.latest()
            self?.codex = codex
        }
    }
}
