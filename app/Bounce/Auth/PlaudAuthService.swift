import Foundation
@preconcurrency import PlaudDeviceBasicSDK

/// Which Plaud region your developer account lives in.
enum PlaudRegion: String, Codable, CaseIterable, Identifiable {
    case us
    case jp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .us: return "United States"
        case .jp: return "Japan"
        }
    }

    /// Host without a scheme — the SDK's `customDomain` wants it that way.
    var domain: String {
        switch self {
        case .us: return "platform-us.plaud.ai"
        case .jp: return "platform-jp.plaud.ai"
        }
    }

    var apiBaseURL: URL {
        URL(string: "https://\(domain)/developer/api")!
    }

    /// The SDK's own region enum.
    ///
    /// `setCustomDomain` sets the host but leaves the SDK's region field alone,
    /// so it logs things like `base URL = platform-us.plaud.ai, region = jp`.
    /// We set both so region-dependent behaviour inside the SDK agrees with the
    /// host we're actually talking to.
    var sdkRegion: PlaudDomainManager.Region {
        switch self {
        case .us: return .us
        case .jp: return .jp
        }
    }
}

/// Your Plaud partner credentials.
///
/// These are **account-level**: they can mint a user token for any `user_id`,
/// not just yours. That is why they are entered at runtime and kept in the
/// keychain rather than compiled into the app — see `KeychainStore` for the
/// attributes that matter, and docs/architecture.md for the threat model.
struct PlaudCredentials: Codable, Equatable {
    var clientId: String
    var secretKey: String
    var region: PlaudRegion

    var isComplete: Bool {
        !clientId.trimmingCharacters(in: .whitespaces).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A minted user access token and when it stops being usable.
struct UserToken: Codable, Equatable {
    let value: String
    let expiresAt: Date

    /// Treat a token as spent slightly early, so a long sync doesn't die
    /// mid-transfer on a token that expired thirty seconds ago.
    func isValid(at date: Date = Date(), margin: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSince(date) > margin
    }
}

/// Talks to Plaud's OAuth endpoints.
///
/// Bounce deliberately does **not** use the partner `refresh_token` flow. We
/// already hold `client_id` and `secret_key`, so minting a fresh partner token
/// is a single Basic-auth call — cheaper than storing and rotating yet another
/// credential for a token that only lives an hour anyway.
struct PlaudAuthService {

    /// Hard ceiling on a user token's lifetime: **24 hours**.
    ///
    /// Plaud's documentation states no maximum, but the API enforces one and
    /// rejects anything larger with HTTP 422:
    ///
    ///     {"type":"less_than_equal","loc":["body","expires_in"],
    ///      "msg":"Input should be less than or equal to 86400","ctx":{"le":86400}}
    ///
    /// Established by testing against the live endpoint, not from the docs. This
    /// is why Bounce holds the partner credentials and re-mints rather than
    /// storing a single long-lived token — 24 hours is the most anyone can get.
    static let maximumUserTokenLifetime = 86_400

    enum Failure: LocalizedError {
        case invalidCredentials
        case http(Int, String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "Plaud rejected those credentials. Check the Client ID and Secret Key, and that the region matches your developer account."
            case .http(let code, let body):
                let detail = body.isEmpty ? "" : " \(body.prefix(200))"
                return "Plaud returned HTTP \(code).\(detail)"
            case .malformedResponse:
                return "Plaud returned a response Bounce couldn't read."
            }
        }
    }

    private let session = URLSession(configuration: .ephemeral)

    /// Step 1: exchange client credentials for a partner token (1 hour).
    func partnerToken(using credentials: PlaudCredentials) async throws -> String {
        let url = credentials.region.apiBaseURL.appendingPathComponent("oauth/partner/access-token")
        AuthLog.log("partner token → POST \(url.path) [region \(credentials.region.rawValue)] "
            + "clientId=\(AuthLog.redacted(credentials.clientId)) "
            + "secret=\(AuthLog.redacted(credentials.secretKey))")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let pair = "\(credentials.clientId):\(credentials.secretKey)"
        let encoded = Data(pair.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let response: TokenResponse = try await send(request)
        AuthLog.log("partner token ✓ \(AuthLog.tokenSummary(response.accessToken)) "
            + "expires_in=\(response.expiresIn.map(String.init) ?? "unspecified")")
        return response.accessToken
    }

    /// Step 2: exchange the partner token for a per-user token.
    ///
    /// `expiresIn` is clamped to `maximumUserTokenLifetime` — the API rejects
    /// anything larger with a 422 rather than silently capping it. The
    /// response's `expires_in` is still treated as authoritative.
    func userToken(
        partnerToken: String,
        userId: String,
        region: PlaudRegion,
        expiresIn: Int
    ) async throws -> UserToken {
        let requested = min(expiresIn, Self.maximumUserTokenLifetime)

        var request = URLRequest(url: region.apiBaseURL
            .appendingPathComponent("open/partner/users/access-token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(partnerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["user_id": userId, "expires_in": requested]
        )

        AuthLog.log("user token → POST \(request.url?.path ?? "?") "
            + "user_id=\(userId) expires_in=\(requested)s")

        let response: TokenResponse = try await send(request)
        let lifetime = TimeInterval(response.expiresIn ?? requested)

        if let granted = response.expiresIn, granted < requested {
            AuthLog.log("⚠︎ server granted less than requested: \(granted)s vs \(requested)s")
        }
        AuthLog.log("user token ✓ \(AuthLog.tokenSummary(response.accessToken)) "
            + "valid \(Int(lifetime / 3600))h")

        return UserToken(value: response.accessToken, expiresAt: Date().addingTimeInterval(lifetime))
    }

    /// Both steps, for convenience.
    func mintUserToken(
        credentials: PlaudCredentials,
        userId: String,
        expiresIn: Int
    ) async throws -> UserToken {
        let partner = try await partnerToken(using: credentials)
        return try await userToken(
            partnerToken: partner,
            userId: userId,
            region: credentials.region,
            expiresIn: expiresIn
        )
    }

    // MARK: - Transport

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            AuthLog.log("✗ HTTP \(http.statusCode): \(AuthLog.redactingSecrets(body).prefix(400))")
            if http.statusCode == 401 || http.statusCode == 403 { throw Failure.invalidCredentials }
            throw Failure.http(http.statusCode, body)
        }

        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            // The most likely failure if Plaud's response shape differs from
            // what we expect, so log the raw body — it is the only way to tell
            // a schema mismatch from a genuine error. But this path fires on a
            // 2xx, whose body carries the freshly minted token, so redact the
            // token/secret values first: the module's own rule is "never print a
            // token," and the keys and structure are what the diagnosis needs.
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            AuthLog.log("✗ couldn't decode response: \(AuthLog.redactingSecrets(raw).prefix(400))")
            throw Failure.malformedResponse
        }
        return decoded
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }
}
