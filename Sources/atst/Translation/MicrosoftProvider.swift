import Foundation

/// Unofficial Microsoft Edge translator adapter.
///
/// The old Edge auth flow (`edge.microsoft.com/translate/auth` → JWT →
/// `api-edge.cognitive.microsofttranslator.com/translate`) was retired in
/// 2026-07: the auth endpoint now answers 404 for every request. The web
/// translator's unauthenticated successor is:
///
///   POST https://edge.microsoft.com/translate/translatetext
///        ?from=&to=<lang>&isEnterpriseClient=false
///   Body: ["line 1", "line 2"]
///   → [{"translations":[{"text":"…"}]}, …]
///
/// No API key or token required. Stability tradeoff is the same as Google /
/// DeepL — unofficial and potentially rate-limited; errors surface as a
/// normal provider failure.
///
/// Risk: unofficial endpoint, no SLA. This flow has already been replaced
/// once (the JWT auth endpoint died in 2026-07), and Edge can change the
/// successor endpoint or rate-limit anonymous traffic again. Failures surface
/// as normal provider errors so the user can disable the row.
struct MicrosoftProvider: TranslationProvider {
    let id: TranslationProviderID = .microsoft
    let displayName: String = "Microsoft"
    let modelHint: String? = nil
    let targetLanguage: String

    private let endpoint = URL(string: "https://edge.microsoft.com/translate/translatetext")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"

    /// Warm the Edge host. The endpoint rejects GET/HEAD, but the connection
    /// pool (DNS + TLS) is shared with the subsequent POST.
    static func prewarm() {
        var request = URLRequest(url: URL(string: "https://edge.microsoft.com/translate/translatetext")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.log("microsoft prewarmed status=\(status)")
        }.resume()
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
        let toCode = Self.targetCode(for: targetLanguage)

        // One array entry per non-blank line so the source's line /
        // paragraph structure survives — see `LineBatch`.
        let batch = LineBatch(text: text)
        let payloadLines = batch.payload
        guard !payloadLines.isEmpty else { throw AppError.emptyTranslation }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "from", value: ""),
            URLQueryItem(name: "to", value: toCode),
            URLQueryItem(name: "isEnterpriseClient", value: "false")
        ]
        guard let url = components.url else {
            throw AppError.providerRequestFailed(name: "Microsoft", detail: "failed to build URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // The successor endpoint takes a bare string array; the old
        // [{ "Text": … }] shape is rejected.
        request.httpBody = try JSONSerialization.data(withJSONObject: payloadLines, options: [])

        let started = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw AppError.providerUnavailable(name: "Microsoft", detail: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppError.providerRequestFailed(name: "Microsoft", detail: "returned an unrecognised response")
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        AppLogger.log("microsoft translate status=\(http.statusCode) bytes=\(data.count) latencyMs=\(latency) lines=\(payloadLines.count)")

        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw AppError.providerRequestFailed(name: "Microsoft", detail: "HTTP \(http.statusCode): \(preview)")
        }

        let translatedLines = try parseResponse(data: data)
        guard let translated = batch.merge(translatedLines) else {
            throw AppError.providerRequestFailed(name: "Microsoft", detail: "line count mismatch (sent \(payloadLines.count), got \(translatedLines.count))")
        }
        guard !translated.isEmpty else { throw AppError.emptyTranslation }

        let untranslatable = looksUntranslatable(source: text, result: translated)
        let output = TranslationOutput(
            result: translated,
            items: [translated],
            phonetic: nil,
            description: nil,
            untranslatable: untranslatable
        )
        return TranslationProviderEmission(output: output, raw: translated, isFinal: true)
    }

    /// Response is one element per request entry:
    ///   [{"translations":[{"text":"…","to":"…"}]}, …]
    private func parseResponse(data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let array = json as? [[String: Any]] else {
            throw AppError.providerRequestFailed(name: "Microsoft", detail: "unexpected response shape")
        }
        return try array.map { entry in
            guard let translations = entry["translations"] as? [[String: Any]],
                  let text = translations.first?["text"] as? String else {
                throw AppError.providerRequestFailed(name: "Microsoft", detail: "unexpected response shape")
            }
            return text
        }
    }

    private func looksUntranslatable(source: String, result: String) -> Bool {
        let normSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normResult = result.lowercased()
        return !normSource.isEmpty && normSource == normResult
    }

    /// Microsoft accepts generic codes except for Chinese, where it wants
    /// `zh-Hans` / `zh-Hant` script variants.
    private static func targetCode(for language: String) -> String {
        let code = (LanguageCode.bcp47(from: language) ?? "en").lowercased()
        if code.hasPrefix("zh") {
            return (code.contains("tw") || code.contains("hk") || code.contains("hant")) ? "zh-Hant" : "zh-Hans"
        }
        return code
    }
}
