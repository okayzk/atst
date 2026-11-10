import Foundation

/// Unofficial DeepL adapter using the iOS app's stateless "oneshot"
/// translation endpoint. No user API key required.
///
/// The older `www2.deepl.com/jsonrpc` / `LMT_handle_texts` trick (used by
/// selo and many older tools) is now answered with an "older version of
/// DeepL" notice instead of a translation. The interactive DeepL clients
/// moved to:
///
///   POST https://oneshot-free.www.deepl.com/v1/translate
///   Authorization: None
///   x-app-os-version / x-app-instance-id / x-app-session-id
///   User-Agent: DeepL/<iOS app version> CFNetwork/... Darwin/...
///
/// Body:
///   {
///     "text": ["line 1", "line 2", …],
///     "target_lang": "zh-Hans",
///     "usage_type": "translate",
///     "app_information": {
///       "os": "iOS", "os_version": "26.0",
///       "app_version": "26.56", "app_build": "5443737",
///       "instance_id": "<uuid>"
///     }
///   }
///
/// Response: `{"translations":[{"detected_source_language":"en","text":"…"}]}`
///
/// Stability tradeoff: same as Google / Microsoft — unofficial, may be
/// rate-limited (HTTP 429) or changed at any time. The advertised app
/// version must stay close to the current App Store release; DeepL treats
/// a stale client profile as a bot signal. `DeepLAppVersionProvider`
/// resolves it from the public iTunes lookup API and caches the result.
///
/// Anonymous traffic is capped at 1500 UTF-16 code units per request, so
/// long selections are split across several requests by line.
///
/// Risk: unofficial endpoint, no SLA. The advertised iOS client profile must
/// stay close to the current App Store release (a stale version is treated as
/// a bot signal), anonymous traffic is rate-limited (HTTP 429), and the
/// endpoint can change or start rejecting anonymous clients. Failures surface
/// as normal provider errors so the user can disable the row.
struct DeepLProvider: TranslationProvider {
    let id: TranslationProviderID = .deepl
    let displayName: String = "DeepL"
    let modelHint: String? = nil
    let targetLanguage: String

    private static let endpoint = URL(string: "https://oneshot-free.www.deepl.com/v1/translate")!
    private static let osVersion = "26.0"
    private static let appBuild = "5443737"
    private static let instanceID = UUID().uuidString.lowercased()
    private static let sessionID = UUID().uuidString.lowercased()
    /// Anonymous requests are rejected above this many UTF-16 code units.
    private static let maxTextLength = 1500

    /// Warm the App Store version lookup (it gates the request profile) and
    /// the oneshot host in the background. Cheap and idempotent.
    static func prewarm() {
        Task.detached(priority: .utility) {
            _ = await DeepLAppVersionProvider.shared.currentVersion()
            var request = URLRequest(url: URL(string: "https://oneshot-free.www.deepl.com/")!)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func translate(text: String) -> AsyncThrowingStream<TranslationProviderEmission, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let emission = try await performTranslate(text: text)
                    try Task.checkCancellation()
                    continuation.yield(emission)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performTranslate(text: String) async throws -> TranslationProviderEmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.emptyTranslation }

        let target = Self.targetCode(for: targetLanguage)
        // One array entry per non-blank line keeps the source's line /
        // paragraph structure — same rule as Google / Microsoft.
        let batch = LineBatch(text: text)
        let lines = batch.payload
        guard !lines.isEmpty else { throw AppError.emptyTranslation }

        let chunks = try Self.chunks(of: lines, limit: Self.maxTextLength)
        let appVersion = await DeepLAppVersionProvider.shared.currentVersion()

        var translatedLines: [String] = []
        translatedLines.reserveCapacity(lines.count)
        for chunk in chunks {
            let translated = try await request(lines: chunk, target: target, appVersion: appVersion)
            translatedLines.append(contentsOf: translated)
        }

        guard let result = batch.merge(translatedLines) else {
            throw AppError.providerRequestFailed(
                name: "DeepL",
                detail: "line count mismatch (sent \(lines.count), got \(translatedLines.count))"
            )
        }
        guard !result.isEmpty else { throw AppError.emptyTranslation }

        let untranslatable = looksUntranslatable(source: text, result: result)
        let output = TranslationOutput(
            result: result,
            items: [result],
            phonetic: nil,
            description: nil,
            untranslatable: untranslatable
        )
        return TranslationProviderEmission(output: output, raw: result, isFinal: true)
    }

    private func request(
        lines: [String],
        target: String,
        appVersion: String
    ) async throws -> [String] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("None", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent(appVersion: appVersion), forHTTPHeaderField: "User-Agent")
        request.setValue(Self.osVersion, forHTTPHeaderField: "x-app-os-version")
        request.setValue(Self.instanceID, forHTTPHeaderField: "x-app-instance-id")
        request.setValue(Self.sessionID, forHTTPHeaderField: "x-app-session-id")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let body = RequestBody(
            text: lines,
            targetLang: target,
            // Omit source_lang so DeepL auto-detects. atst already runs its
            // own reverse-translation language detection before choosing the
            // effective target.
            sourceLang: nil,
            usageType: "translate",
            appInformation: RequestBody.AppInformation(
                os: "iOS",
                osVersion: Self.osVersion,
                appVersion: appVersion,
                appBuild: Self.appBuild,
                instanceID: Self.instanceID
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        let started = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw AppError.providerUnavailable(name: "DeepL", detail: urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.providerRequestFailed(name: "DeepL", detail: "returned an unrecognised response")
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        AppLogger.log(
            "deepl translate status=\(http.statusCode) bytes=\(data.count) latencyMs=\(latency) lines=\(lines.count) target=\(target)"
        )

        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            switch http.statusCode {
            case 429:
                throw AppError.providerUnavailable(
                    name: "DeepL",
                    detail: "rate limited by DeepL — try again later"
                )
            case 403:
                throw AppError.providerRequestFailed(
                    name: "DeepL",
                    detail: "client rejected (outdated app version or blocked): \(preview)"
                )
            default:
                throw AppError.providerRequestFailed(
                    name: "DeepL",
                    detail: "HTTP \(http.statusCode): \(preview)"
                )
            }
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw AppError.providerRequestFailed(name: "DeepL", detail: "unexpected response: \(preview)")
        }

        let translations = decoded.translations?.compactMap(\.text) ?? []
        guard translations.count == lines.count else {
            throw AppError.providerRequestFailed(
                name: "DeepL",
                detail: "line count mismatch (sent \(lines.count), got \(translations.count))"
            )
        }
        return translations
    }

    /// Split non-blank lines into requests whose total UTF-16 length stays
    /// within the anonymous cap. A single line above the cap cannot be sent
    /// without truncating it, so surface a clear failure instead.
    private static func chunks(of lines: [String], limit: Int) throws -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []
        var currentLength = 0

        for line in lines {
            let length = line.utf16.count
            guard length <= limit else {
                throw AppError.providerRequestFailed(
                    name: "DeepL",
                    detail: "a single line exceeds DeepL's \(limit)-character free limit"
                )
            }
            if currentLength + length > limit, !current.isEmpty {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
                currentLength = 0
            }
            current.append(line)
            currentLength += length
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// atst emits `zh-CN` / `zh-TW` / `en` / `pt`; oneshot expects
    /// `zh-Hans` / `zh-Hant` / `en-US` / `pt-BR`. Other targets are
    /// lower-case BCP-47 codes.
    private static func targetCode(for language: String) -> String {
        let code = (LanguageCode.bcp47(from: language) ?? "en").lowercased()
        if code.hasPrefix("zh") {
            if code.contains("tw") || code.contains("hk") || code.contains("hant") {
                return "zh-Hant"
            }
            return "zh-Hans"
        }
        if code.hasPrefix("en") {
            return code == "en-gb" ? "en-GB" : "en-US"
        }
        if code.hasPrefix("pt") {
            return code == "pt-pt" ? "pt-PT" : "pt-BR"
        }
        switch code {
        case "de-ch": return "de-CH"
        case "fr-ca": return "fr-CA"
        case "es-419": return "es-419"
        default: return code
        }
    }

    private static func userAgent(appVersion: String) -> String {
        "DeepL/\(appVersion) CFNetwork/3826.600.41 Darwin/25.0.0"
    }

    /// Same heuristic as Google / Microsoft: unchanged output means a
    /// proper noun, already-target-language input, or a miss.
    private func looksUntranslatable(source: String, result: String) -> Bool {
        let normSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normResult = result.lowercased()
        return !normSource.isEmpty && normSource == normResult
    }
}

// MARK: - Request / response models

private struct RequestBody: Encodable {
    let text: [String]
    let targetLang: String
    let sourceLang: String?
    let usageType: String
    let appInformation: AppInformation

    enum CodingKeys: String, CodingKey {
        case text
        case targetLang = "target_lang"
        case sourceLang = "source_lang"
        case usageType = "usage_type"
        case appInformation = "app_information"
    }

    struct AppInformation: Encodable {
        let os: String
        let osVersion: String
        let appVersion: String
        let appBuild: String
        let instanceID: String

        enum CodingKeys: String, CodingKey {
            case os
            case osVersion = "os_version"
            case appVersion = "app_version"
            case appBuild = "app_build"
            case instanceID = "instance_id"
        }
    }
}

private struct ResponseBody: Decodable {
    let translations: [Translation]?

    struct Translation: Decodable {
        let detectedSourceLanguage: String?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case detectedSourceLanguage = "detected_source_language"
            case text
        }
    }
}

// MARK: - App Store version lookup

/// Resolves the DeepL iOS marketing version advertised in the oneshot
/// request. DeepL rate-limits clients whose `User-Agent` + `app_information`
/// version is stale, so the value is refreshed from the public iTunes lookup
/// API at most once per day. A failed lookup is retried after 15 minutes and
/// otherwise falls back to the last known / pinned version.
actor DeepLAppVersionProvider {
    static let shared = DeepLAppVersionProvider()

    private static let fallbackVersion = "26.56"
    private static let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=1552407475&country=us")!
    private static let cacheLifetime: TimeInterval = 24 * 60 * 60
    private static let retryDelay: TimeInterval = 15 * 60
    private static let lookupTimeout: TimeInterval = 3

    private var cachedVersion: String?
    private var fetchedAt: Date?
    private var lastAttemptAt: Date?
    private var lookupTask: Task<String?, Never>?

    func currentVersion() async -> String {
        let now = Date()

        if let cachedVersion,
           let fetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.cacheLifetime {
            return cachedVersion
        }

        if let lookupTask {
            return await resolve(lookupTask)
        }

        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < Self.retryDelay {
            return cachedVersion ?? Self.fallbackVersion
        }

        lastAttemptAt = now
        let task = Task { await Self.fetchLatestVersion() }
        lookupTask = task
        return await resolve(task)
    }

    private func resolve(_ task: Task<String?, Never>) async -> String {
        let version = await task.value
        lookupTask = nil
        guard let version else {
            return cachedVersion ?? Self.fallbackVersion
        }
        cachedVersion = version
        fetchedAt = Date()
        return version
    }

    private static func fetchLatestVersion() async -> String? {
        var request = URLRequest(url: lookupURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = lookupTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return parseVersion(from: data)
        } catch {
            return nil
        }
    }

    private static func parseVersion(from data: Data) -> String? {
        struct LookupResponse: Decodable {
            struct App: Decodable {
                let trackId: Int
                let bundleId: String
                let artistName: String
                let version: String
            }

            let resultCount: Int
            let results: [App]
        }

        guard let lookup = try? JSONDecoder().decode(LookupResponse.self, from: data),
              lookup.resultCount == 1,
              let app = lookup.results.first,
              app.trackId == 1_552_407_475,
              app.bundleId == "com.linguee.DeepLMobileTranslator",
              app.artistName == "DeepL SE",
              isValidVersion(app.version) else {
            return nil
        }
        return app.version
    }

    private static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(parts.count) && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
        }
    }
}
