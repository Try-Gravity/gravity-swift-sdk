import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Gravity SDK for fetching contextual ads from the Gravity engine.
///
/// ```swift
/// let gravity = Gravity(apiKey: "pub_...", production: true)
///
/// let result = await gravity.getAds(
///     messages: messages,
///     sessionId: "sess_123",
///     userId: "user_456",
///     placements: [.belowResponse()]
/// )
///
/// if let ad = result.ads.first {
///     // Render the ad in your UI
/// }
/// ```
///
/// `getAds` never throws. A failure returns no ads. If the SDK receives an HTTP
/// response, the result contains its status. The SDK limits the diagnostic text
/// for a non-success response.
public final class Gravity: Sendable {
    public let apiKey: String
    public let apiUrl: String
    public let feedbackUrl: String
    public let timeoutSeconds: TimeInterval
    public let production: Bool
    public let relevancy: Double
    public let excludedTopics: [String]?
    public let readCMPConsent: Bool
    public let honorATT: Bool

    private let session: URLSession

    /// - Parameters:
    ///   - apiKey: Your Gravity publisher API key. Falls back to the
    ///     `GRAVITY_API_KEY` environment variable.
    ///   - apiUrl: Gravity ad endpoint. Defaults to production.
    ///   - feedbackUrl: Gravity feedback endpoint. Defaults to production.
    ///   - timeoutSeconds: Request timeout. Default 3 s.
    ///   - production: `false` returns test ads (no billing). Default `false`.
    ///   - relevancy: Minimum relevancy threshold 0.0-1.0. Default `0.2`.
    ///   - excludedTopics: Topics to exclude from matching.
    ///   - readCMPConsent: When `true` (default), consent recorded by the
    ///     app's IAB-registered CMP (the standard `IABTCF_*` /
    ///     `IABUSPrivacy_String` UserDefaults keys) is forwarded with ad
    ///     requests so the server can honor it. Set `false` to never read
    ///     CMP storage; only an explicit `consent:` argument is sent then.
    ///   - honorATT: When `true` (default), the App Tracking Transparency
    ///     status is mapped to the consent signal: unless the user has
    ///     explicitly authorized tracking, requests carry `consent.gpc = true`
    ///     and the engine serves fully contextual ads with no cross-context
    ///     identifiers (denial, restriction, and never-asked all fail
    ///     closed, matching Apple's tracking policy). Set `false` only if
    ///     you forward the user's opt-out state yourself via `consent:`.
    public convenience init(
        apiKey: String? = nil,
        apiUrl: String = "https://server.trygravity.ai/api/v1/ad",
        feedbackUrl: String = "https://platform.trygravity.ai/ad-feedback",
        timeoutSeconds: TimeInterval = 3.0,
        production: Bool = false,
        relevancy: Double = 0.2,
        excludedTopics: [String]? = nil,
        readCMPConsent: Bool = true,
        honorATT: Bool = true
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds + 2

        self.init(
            apiKey: apiKey,
            apiUrl: apiUrl,
            feedbackUrl: feedbackUrl,
            timeoutSeconds: timeoutSeconds,
            production: production,
            relevancy: relevancy,
            excludedTopics: excludedTopics,
            readCMPConsent: readCMPConsent,
            honorATT: honorATT,
            session: URLSession(configuration: config)
        )
    }

    /// Tests use this initializer to supply a `URLSession`. The session keeps
    /// test request handling local.
    init(
        apiKey: String? = nil,
        apiUrl: String = "https://server.trygravity.ai/api/v1/ad",
        feedbackUrl: String = "https://platform.trygravity.ai/ad-feedback",
        timeoutSeconds: TimeInterval = 3.0,
        production: Bool = false,
        relevancy: Double = 0.2,
        excludedTopics: [String]? = nil,
        readCMPConsent: Bool = true,
        honorATT: Bool = true,
        session: URLSession
    ) {
        self.apiKey = apiKey
            ?? ProcessInfo.processInfo.environment["GRAVITY_API_KEY"]
            ?? ""
        self.apiUrl = apiUrl
        self.feedbackUrl = feedbackUrl
        self.timeoutSeconds = timeoutSeconds
        self.production = production
        self.relevancy = relevancy
        self.excludedTopics = excludedTopics
        self.readCMPConsent = readCMPConsent
        self.honorATT = honorATT
        self.session = session
    }

    // MARK: - Fetch ads

    /// Fetch contextual ads from the Gravity engine.
    ///
    /// This method never throws. A failure returns no ads. ``AdResult/status``
    /// is `0` if the SDK does not receive a valid HTTP response.
    ///
    /// Unlike the server-side JS/Python SDKs, this client does not take a
    /// framework request object — it collects device signals (UA, OS, screen,
    /// timezone, locale) directly from the host device. Pass `userIP` if your
    /// app knows the end-user IP (e.g. from your backend).
    ///
    /// - Parameters:
    ///   - messages: Conversation history for contextual matching.
    ///   - sessionId: Session identifier for frequency capping and experiments.
    ///   - userId: Stable per-user identifier. Pass `"anonymous"` if unknown.
    ///   - placements: Ad slots to fill (1-10).
    ///   - userIP: End-user IP for geo targeting. Optional.
    ///   - hashedIdentity: Pre-hashed email/phone from ``hashPII(email:phone:)``.
    ///   - extraUserFields: Additional user context (gender, age, etc.).
    ///   - extraDeviceFields: Additional device fields to merge (e.g. `["ifa": idfa]`).
    ///   - production: Override the instance-level production flag.
    ///   - relevancy: Override the instance-level relevancy threshold.
    public func getAds(
        messages: [Message],
        sessionId: String,
        userId: String = "anonymous",
        placements: [Placement],
        userIP: String? = nil,
        hashedIdentity: HashedIdentity? = nil,
        extraUserFields: [String: String]? = nil,
        extraDeviceFields: [String: Any]? = nil,
        production: Bool? = nil,
        relevancy: Double? = nil,
        consent: ConsentSignal? = nil
    ) async -> AdResult {
        let start = Date()

        guard let endpoint = URL(string: apiUrl),
              let scheme = endpoint.scheme,
              !scheme.isEmpty,
              let host = endpoint.host,
              !host.isEmpty else {
            return AdResult(
                ads: [],
                status: 0,
                elapsedMs: elapsedMilliseconds(since: start),
                error: "Invalid ad endpoint URL"
            )
        }

        do {
            let body = buildRequestBody(
                messages: messages,
                sessionId: sessionId,
                userId: userId,
                placements: placements,
                userIP: userIP,
                hashedIdentity: hashedIdentity,
                extraUserFields: extraUserFields,
                extraDeviceFields: extraDeviceFields,
                production: production,
                relevancy: relevancy,
                consent: consent
            )
            // Foundation can raise an Objective-C exception if the body contains
            // an unsupported value. Check the body first to keep getAds()
            // nonthrowing.
            guard JSONSerialization.isValidJSONObject(body) else {
                return AdResult(
                    ads: [],
                    status: 0,
                    elapsedMs: elapsedMilliseconds(since: start),
                    error: "Request body could not be serialized"
                )
            }
            let requestData = try JSONSerialization.data(withJSONObject: body)

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = requestData

            let (responseData, response) = try await session.data(for: request)
            let elapsed = elapsedMilliseconds(since: start)

            guard let httpResponse = response as? HTTPURLResponse else {
                return AdResult(
                    ads: [],
                    status: 0,
                    elapsedMs: elapsed,
                    error: "Received non-HTTP response"
                )
            }

            let status = httpResponse.statusCode
            guard (200..<300).contains(status) else {
                return AdResult(
                    ads: [],
                    status: status,
                    elapsedMs: elapsed,
                    error: httpFailureDiagnostic(statusCode: status, body: responseData)
                )
            }

            if status == 204 {
                return AdResult(ads: [], status: status, elapsedMs: elapsed, error: nil)
            }

            do {
                let ads = try JSONDecoder().decode([AdResponse].self, from: responseData)
                return AdResult(ads: ads, status: status, elapsedMs: elapsed, error: nil)
            } catch {
                return AdResult(
                    ads: [],
                    status: status,
                    elapsedMs: elapsed,
                    error: "HTTP \(status) response could not be decoded: \(error.localizedDescription)"
                )
            }
        } catch {
            return AdResult(
                ads: [],
                status: 0,
                elapsedMs: elapsedMilliseconds(since: start),
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Impression tracking

    /// Fire the impression pixel. Call once when the ad becomes visible
    /// (at least 50% in viewport).
    ///
    /// Fire-and-forget — errors are silently ignored.
    public func trackImpression(_ ad: AdResponse) {
        guard let urlString = ad.impUrl, let url = URL(string: urlString) else { return }
        Task { _ = try? await session.data(from: url) }
    }

    // MARK: - Click handling

    /// Open the ad's tracked click URL. Routes through Gravity tracking,
    /// then 302-redirects to the landing page.
    @MainActor
    public func handleClick(_ ad: AdResponse) {
        guard let urlString = ad.clickUrl, let url = URL(string: urlString) else { return }
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: - Ad feedback

    /// Submit user feedback (thumbs up / thumbs down) on an ad.
    ///
    /// Fire-and-forget — errors are silently ignored.
    public func sendFeedback(
        sessionId: String,
        ad: AdResponse,
        sentiment: Sentiment,
        reasons: [String]? = nil,
        comment: String? = nil,
        userId: String? = nil
    ) {
        Task {
            do {
                var body: [String: Any] = [
                    "sessionId": sessionId,
                    "impUrl": ad.impUrl ?? "",
                    "sentiment": sentiment.rawValue,
                ]
                if let reasons { body["reasons"] = reasons }
                if let comment { body["comment"] = comment }
                if let userId { body["userId"] = userId }
                if let p = ad.placement { body["placement"] = p }
                if let pid = ad.placementId { body["placementId"] = pid }

                let data = try JSONSerialization.data(withJSONObject: body)
                var request = URLRequest(url: URL(string: feedbackUrl)!)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = data

                _ = try await session.data(for: request)
            } catch {
                // fire-and-forget
            }
        }
    }

    public enum Sentiment: String, Sendable {
        case thumbsUp = "thumbs_up"
        case thumbsDown = "thumbs_down"
    }

    // MARK: - Private

    private static let maxHTTPFailureDiagnosticLength = 512

    /// This function uses one calculation so all failure paths report elapsed time in the same way.
    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(-start.timeIntervalSinceNow * 1000)
    }

    /// This function limits server text to prevent a large response from producing a large diagnostic.
    private func httpFailureDiagnostic(statusCode: Int, body: Data) -> String {
        let prefix = "HTTP \(statusCode)"
        let separator = ": "
        let availableTextLength = Self.maxHTTPFailureDiagnosticLength
            - prefix.count
            - separator.count
        guard availableTextLength > 1,
              let normalized = normalizedUTF8Text(
                  from: body,
                  maxRetainedLength: availableTextLength - 1
              ),
              !normalized.text.isEmpty else {
            return prefix
        }

        let suffix = normalized.wasTruncated ? "…" : ""
        return "\(prefix)\(separator)\(normalized.text)\(suffix)"
    }

    /// This function checks the complete body so the SDK rejects text with invalid trailing UTF-8.
    /// It stores only a limited prefix to keep the diagnostic small.
    private func normalizedUTF8Text(
        from body: Data,
        maxRetainedLength: Int
    ) -> (text: String, wasTruncated: Bool)? {
        var decoder = UTF8()
        var iterator = body.makeIterator()
        var text = String()
        text.reserveCapacity(maxRetainedLength)
        var retainedScalarCount = 0
        var pendingWhitespace = false
        var wasTruncated = false

        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar):
                if scalar.properties.isWhitespace {
                    pendingWhitespace = true
                    continue
                }

                let needsSeparator = pendingWhitespace && !text.isEmpty
                let requiredScalarCount = (needsSeparator ? 1 : 0) + 1
                if !wasTruncated && retainedScalarCount + requiredScalarCount <= maxRetainedLength {
                    if needsSeparator {
                        text.unicodeScalars.append(" ")
                        retainedScalarCount += 1
                    }
                    text.unicodeScalars.append(scalar)
                    retainedScalarCount += 1
                } else {
                    wasTruncated = true
                }
                pendingWhitespace = false
            case .emptyInput:
                return (text: text, wasTruncated: wasTruncated)
            case .error:
                return nil
            }
        }
    }

    func buildRequestBody(
        messages: [Message],
        sessionId: String,
        userId: String,
        placements: [Placement],
        userIP: String?,
        hashedIdentity: HashedIdentity?,
        extraUserFields: [String: String]?,
        extraDeviceFields: [String: Any]?,
        production: Bool?,
        relevancy: Double?,
        consent: ConsentSignal? = nil
    ) -> [String: Any] {
        // Last 2 valid conversational messages
        let validMessages = messages
            .compactMap { $0.toDict() }
            .suffix(2)
            .map { $0 as Any }

        var user: [String: Any] = ["id": userId]
        if let ip = userIP { user["ip"] = ip }
        if let hashed = hashedIdentity {
            if let eh = hashed.emailHash { user["email_hash"] = eh }
            if let ph = hashed.hashedPhone { user["hashed_phone"] = ph }
        }
        if let extra = extraUserFields {
            for (k, v) in extra { user[k] = v }
        }

        var device = DeviceContext.collect().toDict()
        if let ip = userIP { device["ip"] = ip }
        if let extra = extraDeviceFields {
            for (k, v) in extra { device[k] = v }
        }

        var body: [String: Any] = [
            "messages": Array(validMessages),
            "sessionId": sessionId,
            "placements": placements.map { $0.toDict() },
            "user": user,
            "device": device,
            "relevancy": relevancy ?? self.relevancy,
            "testAd": !(production ?? self.production),
        ]
        // Capability profile only — never the legacy `supportsSpec: true`,
        // which the engine reads as "full web renderer" (web1) and would
        // attach full-CSS specs this interpreter can't paint. The engine's
        // profile gate matches psp1 clients with psp1-conformant specs.
        // Advertised only on platforms where the interpreter (SpecAdView)
        // actually compiles — tvOS/watchOS builds have no PSP-1 renderer,
        // so they must not ask for spec payloads they always discard.
        #if canImport(SwiftUI) && canImport(UIKit) && !os(tvOS) && !os(watchOS)
        body["specCapabilities"] = "psp1"
        #endif
        if let topics = excludedTopics {
            body["excludedTopics"] = topics
        }
        // Consent: an explicit signal wins; otherwise (unless the publisher
        // opted out with `readCMPConsent: false`) auto-read the standard IAB
        // CMP keys the app's consent banner writes to UserDefaults.
        // Neither present → field omitted, request unchanged.
        // App Tracking Transparency: unless the user explicitly authorized
        // tracking, assert the opt-out (never unsets one already present).
        let signal = ConsentSignal.merging(
            consent ?? (readCMPConsent ? ConsentSignal.fromCMP() : nil),
            attOptsOut: honorATT ? ConsentSignal.attOptsOut() : nil
        )
        if let signal {
            let dict = signal.toDict()
            if !dict.isEmpty { body["consent"] = dict }
        }
        return body
    }
}
