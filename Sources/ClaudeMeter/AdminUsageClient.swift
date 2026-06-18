import Foundation

/// Per-model token totals for the current month (from the Usage Admin API).
struct ApiModelUsage: Identifiable {
    let model: String
    let inputTokens: Int       // uncached input
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    var id: String { model }
    var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

/// Month-to-date usage & cost for an API-billing (Console) account, from
/// Anthropic's Usage & Cost Admin API. This is authoritative billing data —
/// unlike the OAuth `/api/oauth/usage` endpoint (subscription % windows), it
/// returns real USD cost and exact token counts. Requires an Admin API key.
struct ApiUsage {
    let monthCostUSD: Double
    let models: [ApiModelUsage]   // sorted desc by total tokens
    let totalInput: Int
    let totalOutput: Int
    let totalCacheRead: Int
    let totalCacheCreation: Int
    let fetchedAt: Date
}

enum AdminUsageError: LocalizedError {
    case unauthorized
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unauthorized: return L.adminUnauthorized
        case .http(let code): return L.apiError(code)
        case .malformed: return L.apiMalformed
        }
    }
}

/// Calls the Usage & Cost Admin API with an Admin key (`sk-ant-admin...`).
/// NOTE: validated against the documented response schema; not exercised against
/// a live Admin key in this build (the user supplies the key at runtime).
enum AdminUsageClient {
    private static let base = "https://api.anthropic.com/v1/organizations"

    /// Fetch month-to-date cost + token usage. Runs network I/O — call off the
    /// main actor (it's nonisolated, so awaiting it from @MainActor hops off).
    static func fetch(adminKey: String, now: Date = Date()) async throws -> ApiUsage {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let start = iso.string(from: monthStart)
        let end = iso.string(from: now)

        let cost = try await fetchCost(adminKey: adminKey, start: start, end: end)
        let usage = try await fetchUsage(adminKey: adminKey, start: start, end: end)
        return ApiUsage(
            monthCostUSD: cost,
            models: usage.models,
            totalInput: usage.totalInput,
            totalOutput: usage.totalOutput,
            totalCacheRead: usage.totalCacheRead,
            totalCacheCreation: usage.totalCacheCreation,
            fetchedAt: now
        )
    }

    // MARK: - Cost

    private static func fetchCost(adminKey: String, start: String, end: String) async throws -> Double {
        var totalCents = 0.0
        var page: String?
        var guardPages = 0
        repeat {
            var items = [
                URLQueryItem(name: "starting_at", value: start),
                URLQueryItem(name: "ending_at", value: end),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { items.append(URLQueryItem(name: "page", value: page)) }
            let root = try await get(path: "/cost_report", query: items, adminKey: adminKey)
            for bucket in (root["data"] as? [[String: Any]]) ?? [] {
                for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                    if let amount = result["amount"] as? String, let cents = Double(amount) {
                        totalCents += cents
                    } else if let cents = result["amount"] as? Double {
                        totalCents += cents
                    }
                }
            }
            page = (root["has_more"] as? Bool) == true ? nextPageToken(root["next_page"]) : nil
            guardPages += 1
        } while page != nil && guardPages < 12
        return totalCents / 100.0   // amount is in cents
    }

    // MARK: - Usage

    private struct UsageAccumulator {
        var models: [ApiModelUsage]
        var totalInput: Int
        var totalOutput: Int
        var totalCacheRead: Int
        var totalCacheCreation: Int
    }

    private static func fetchUsage(adminKey: String, start: String, end: String) async throws -> UsageAccumulator {
        var perModel: [String: ApiModelUsage] = [:]
        var page: String?
        var guardPages = 0
        repeat {
            var items = [
                URLQueryItem(name: "starting_at", value: start),
                URLQueryItem(name: "ending_at", value: end),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
                URLQueryItem(name: "group_by[]", value: "model"),
            ]
            if let page { items.append(URLQueryItem(name: "page", value: page)) }
            let root = try await get(path: "/usage_report/messages", query: items, adminKey: adminKey)
            for bucket in (root["data"] as? [[String: Any]]) ?? [] {
                for r in (bucket["results"] as? [[String: Any]]) ?? [] {
                    let model = (r["model"] as? String) ?? "unknown"
                    let input = intValue(r["uncached_input_tokens"])
                    let output = intValue(r["output_tokens"])
                    let cacheRead = intValue(r["cache_read_input_tokens"])
                    var cacheCreate = 0
                    if let cc = r["cache_creation"] as? [String: Any] {
                        cacheCreate = intValue(cc["ephemeral_1h_input_tokens"]) + intValue(cc["ephemeral_5m_input_tokens"])
                    }
                    let existing = perModel[model]
                    perModel[model] = ApiModelUsage(
                        model: model,
                        inputTokens: (existing?.inputTokens ?? 0) + input,
                        outputTokens: (existing?.outputTokens ?? 0) + output,
                        cacheReadTokens: (existing?.cacheReadTokens ?? 0) + cacheRead,
                        cacheCreationTokens: (existing?.cacheCreationTokens ?? 0) + cacheCreate
                    )
                }
            }
            page = (root["has_more"] as? Bool) == true ? nextPageToken(root["next_page"]) : nil
            guardPages += 1
        } while page != nil && guardPages < 12

        let models = perModel.values.sorted { $0.total > $1.total }
        return UsageAccumulator(
            models: models,
            totalInput: models.reduce(0) { $0 + $1.inputTokens },
            totalOutput: models.reduce(0) { $0 + $1.outputTokens },
            totalCacheRead: models.reduce(0) { $0 + $1.cacheReadTokens },
            totalCacheCreation: models.reduce(0) { $0 + $1.cacheCreationTokens }
        )
    }

    // MARK: - HTTP

    private static func get(path: String, query: [URLQueryItem], adminKey: String) async throws -> [String: Any] {
        var comps = URLComponents(string: base + path)!
        comps.queryItems = query
        guard let url = comps.url else { throw AdminUsageError.malformed }
        var request = URLRequest(url: url)
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("claude-meter/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AdminUsageError.malformed }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw AdminUsageError.unauthorized
        default: throw AdminUsageError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdminUsageError.malformed
        }
        return root
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    /// `next_page` is a string cursor per the docs, but tolerate an integer too.
    private static func nextPageToken(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let i = any as? Int { return String(i) }
        return nil
    }
}
