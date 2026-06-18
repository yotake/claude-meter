import Foundation

struct UsageWindow {
    let utilization: Double  // 0–100
    let resetsAt: Date?
}

struct Usage {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let fetchedAt: Date
}

enum UsageError: LocalizedError {
    case unauthorized
    case rateLimited(retryAfterSeconds: Int?)
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L.tokenInvalid
        case .rateLimited(let retry):
            return L.rateLimited(retryAfterSeconds: retry)
        case .http(let code):
            return L.apiError(code)
        case .malformed:
            return L.apiMalformed
        }
    }
}

enum UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(token: String) async throws -> Usage {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-meter/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.malformed }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UsageError.unauthorized
        case 429:
            // Server tells us exactly how long to wait via Retry-After (seconds),
            // or via anthropic-ratelimit-unified-reset (epoch seconds).
            var retry = http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) }
            if retry == nil, let resetEpoch = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-reset").flatMap({ Double($0) }) {
                retry = max(0, Int(resetEpoch - Date().timeIntervalSince1970))
            }
            throw UsageError.rateLimited(retryAfterSeconds: retry)
        default: throw UsageError.http(http.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformed
        }
        return Usage(
            fiveHour: window(root["five_hour"]),
            sevenDay: window(root["seven_day"]),
            sevenDaySonnet: window(root["seven_day_sonnet"]),
            sevenDayOpus: window(root["seven_day_opus"]),
            fetchedAt: Date()
        )
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let utilization = dict["utilization"] as? Double
        else { return nil }
        return UsageWindow(
            utilization: utilization,
            resetsAt: (dict["resets_at"] as? String).flatMap(parseISO8601)
        )
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
