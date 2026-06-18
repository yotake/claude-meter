import Foundation

enum OAuthError: LocalizedError {
    case invalidGrant
    case tokenRequestFailed(Int, String)
    case transport(Error)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidGrant:
            return L.authExpired
        case .tokenRequestFailed(let status, let body):
            return L.tokenRequestFailed(status, body)
        case .transport(let err):
            return L.networkError(err.localizedDescription)
        case .malformedResponse:
            return L.tokenResponseMalformed
        }
    }
}

struct TokenResponse {
    let accessToken: String
    let refreshToken: String
    let expiresInSeconds: Double
}

enum OAuthClient {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    // MARK: - Public token operations

    /// Refresh an access token using a refresh token.
    static func refresh(refreshToken: String) async throws -> TokenResponse {
        let jsonBody: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     clientID,
        ]
        let formBody = "grant_type=refresh_token" +
            "&refresh_token=\(urlEncode(refreshToken))" +
            "&client_id=\(urlEncode(clientID))"
        return try await postToken(jsonBody: jsonBody, formBody: formBody)
    }

    // MARK: - Private helpers

    private static func urlEncode(_ s: String) -> String {
        // x-www-form-urlencoded values must escape +, &, =, / etc.
        // .urlQueryAllowed leaves those intact, so use RFC 3986 unreserved only.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Try JSON first; fall back to form-encoded if the response is not 2xx.
    private static func postToken(jsonBody: [String: String], formBody: String) async throws -> TokenResponse {
        // Attempt 1: JSON
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: jsonBody)
            var req = URLRequest(url: tokenEndpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData

            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return try decodeTokenResponse(data)
            }
            // A revoked/expired refresh token is terminal — don't waste a second request.
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (root["error"] as? String) == "invalid_grant" {
                throw OAuthError.invalidGrant
            }
            // Other non-2xx from JSON attempt: fall through to form-encoded retry
        } catch let err as OAuthError {
            throw err
        } catch {
            // Transport error — throw as transport, no retry
            throw OAuthError.transport(error)
        }

        // Attempt 2: form-encoded
        let formData = formBody.data(using: .utf8)!
        var req2 = URLRequest(url: tokenEndpoint)
        req2.httpMethod = "POST"
        req2.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req2.httpBody = formData

        let (data2, response2): (Data, URLResponse)
        do {
            (data2, response2) = try await URLSession.shared.data(for: req2)
        } catch {
            throw OAuthError.transport(error)
        }

        guard let http2 = response2 as? HTTPURLResponse else {
            throw OAuthError.malformedResponse
        }
        guard (200..<300).contains(http2.statusCode) else {
            let body = String(data: data2, encoding: .utf8) ?? ""
            // Parse the JSON error field (not a substring match) for a precise classification.
            if let root = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
               (root["error"] as? String) == "invalid_grant" {
                throw OAuthError.invalidGrant
            }
            throw OAuthError.tokenRequestFailed(http2.statusCode, body)
        }
        return try decodeTokenResponse(data2)
    }

    private static func decodeTokenResponse(_ data: Data) throws -> TokenResponse {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken  = root["access_token"]  as? String,
            let refreshToken = root["refresh_token"] as? String
        else {
            // Check for error field in body
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorCode = root["error"] as? String,
               errorCode == "invalid_grant" {
                throw OAuthError.invalidGrant
            }
            throw OAuthError.malformedResponse
        }
        let expiresIn: Double
        if let secs = root["expires_in"] as? Double {
            expiresIn = secs
        } else if let secs = root["expires_in"] as? Int {
            expiresIn = Double(secs)
        } else {
            expiresIn = 28800 // 8h default
        }
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresInSeconds: expiresIn
        )
    }
}
