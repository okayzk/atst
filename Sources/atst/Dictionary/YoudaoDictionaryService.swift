import CryptoKit
import Foundation

/// Youdao's keyless web dictionary.
///
/// Request shape (the same one the official web dictionary uses):
///   POST https://dict.youdao.com/jsonapi_s?doctype=json&jsonversion=4
///   Body (form): q=<word>, keyfrom=webdict, client=web, t=<0...9>, sign=<md5>
///
/// The `sign` is a web-client signature, not a user API key. It is built from
/// the query, a static key shipped in Youdao's front end, and an MD5 salt.
/// Its purpose is client authenticity / anti-abuse: it makes the request look
/// like the official web client. It does not authenticate a user, grant a
/// quota, or unlock extra data.
///
/// Risks:
/// - This is an unofficial endpoint. Youdao may change the path, the schema,
///   the signing algorithm or the static key at any time.
/// - Heavy use can be rate-limited or blocked. Lookups are user-triggered and
///   cached; do not poll this endpoint.
/// - The returned dictionary content is Youdao's data, not ours.
///
/// The app treats it as best-effort: on any failure the caller falls back to
/// the local macOS dictionary, then silently hides the dictionary card.
struct YoudaoDictionaryService {
    private static let endpoint = URL(
        string: "https://dict.youdao.com/jsonapi_s?doctype=json&jsonversion=4"
    )!

    /// Public web key used by Youdao's own dictionary front end. It is not a
    /// user credential. It is embedded in open-source clients (Easydict, Bob
    /// plugins) and can rotate when Youdao updates its front end. Keep this
    /// value in one place so a rotation is a one-line change.
    private static let webKey = "Mk6hqtUp33DGGtoS63tTJbMUYjRrG1Lu"

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    func lookup(_ query: String) async throws -> DictionaryEntry? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (time, sign) = Self.signature(for: trimmed)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://dict.youdao.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let fields: [(String, String)] = [
            ("q", trimmed),
            ("keyfrom", "webdict"),
            ("client", "web"),
            ("t", String(time)),
            ("sign", sign)
        ]
        request.httpBody = fields
            .map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            AppLogger.log("youdao dict unavailable: \(error.localizedDescription)")
            throw AppError.providerUnavailable(name: "Youdao Dictionary", detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.providerRequestFailed(name: "Youdao Dictionary", detail: "unrecognised response")
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        AppLogger.log("youdao dict status=\(http.statusCode) bytes=\(data.count) latencyMs=\(latency) q=\(trimmed)")
        guard (200..<300).contains(http.statusCode) else {
            throw AppError.providerRequestFailed(
                name: "Youdao Dictionary",
                detail: "HTTP \(http.statusCode)"
            )
        }

        let decoded = try JSONDecoder().decode(YoudaoResponse.self, from: data)
        return Self.makeEntry(from: decoded, query: trimmed)
    }

    // MARK: - Signing

    /// `sign = MD5("web" + q + t + key + MD5(q + "webdict"))`,
    /// `t = len(q + "webdict") % 10`, using JavaScript's UTF-16 length.
    private static func signature(for query: String) -> (Int, String) {
        let raw = query + "webdict"
        let time = raw.utf16.count % 10
        let salt = md5(raw)
        let sign = md5("web" + query + String(time) + webKey + salt)
        return (time, sign)
    }

    private static func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Mapping

    private static func makeEntry(from response: YoudaoResponse, query: String) -> DictionaryEntry? {
        guard let word = response.ec?.word else { return nil }

        var phonetics: [DictionaryEntry.Phonetic] = []
        if let uk = word.ukphone, !uk.isEmpty {
            phonetics.append(.init(
                accent: "UK",
                text: uk,
                audioURL: audioURL(speech: word.ukspeech, type: 1)
            ))
        }
        if let us = word.usphone, !us.isEmpty {
            phonetics.append(.init(
                accent: "US",
                text: us,
                audioURL: audioURL(speech: word.usspeech, type: 2)
            ))
        }

        let senses = (word.trs ?? []).compactMap { item -> DictionaryEntry.Sense? in
            guard let tran = item.tran else { return nil }
            let meanings = tran
                .components(separatedBy: "；")
                .flatMap { $0.components(separatedBy: ";") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !meanings.isEmpty else { return nil }
            return .init(partOfSpeech: item.pos ?? "", meanings: meanings)
        }

        let examples = (response.blngSentsPart?.sentencePair ?? []).compactMap { pair -> DictionaryEntry.Example? in
            guard let source = pair.sentence?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty else { return nil }
            let translation = pair.translation?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(source: stripTags(source), translation: translation)
        }

        let phrases = (response.phrs?.phrs ?? []).compactMap { item -> DictionaryEntry.Phrase? in
            guard let headword = item.headword, let translation = item.translation else { return nil }
            return .init(headword: headword, translation: translation)
        }

        let related = (response.relWord?.rels ?? []).compactMap { item -> DictionaryEntry.Related? in
            guard let rel = item.rel, let words = rel.words, !words.isEmpty else { return nil }
            let merged = words.compactMap { word -> String? in
                guard let text = word.word else { return nil }
                if let tran = word.tran, !tran.isEmpty {
                    return "\(text) \(tran)"
                }
                return text
            }
            guard !merged.isEmpty else { return nil }
            return .init(partOfSpeech: rel.pos ?? "", words: merged)
        }

        let entry = DictionaryEntry(
            headword: word.returnPhrase ?? query,
            phonetics: phonetics,
            senses: senses,
            examples: examples,
            phrases: phrases,
            related: related,
            tags: response.ec?.examType ?? [],
            rawText: nil,
            source: .youdao
        )
        return entry.hasContent ? entry : nil
    }

    private static func audioURL(speech: String?, type: Int) -> String? {
        guard let speech, !speech.isEmpty else { return nil }
        if speech.contains("type=") {
            return "https://dict.youdao.com/dictvoice?audio=\(speech)"
        }
        return "https://dict.youdao.com/dictvoice?audio=\(speech)&type=\(type)"
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

// MARK: - Wire format

private struct YoudaoResponse: Decodable {
    struct EC: Decodable {
        let word: Word?
        let examType: [String]?

        enum CodingKeys: String, CodingKey {
            case word
            case examType = "exam_type"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            examType = try container.decodeIfPresent([String].self, forKey: .examType)
            // The signed V4 endpoint returns an object; the plain jsonapi
            // returns a one-element array. Accept both so a backend switch
            // doesn't break the parser.
            if let object = try? container.decode(Word.self, forKey: .word) {
                word = object
            } else if let array = try? container.decode([Word].self, forKey: .word) {
                word = array.first
            } else {
                word = nil
            }
        }

        struct Word: Decodable {
            let returnPhrase: String?
            let ukphone: String?
            let usphone: String?
            let ukspeech: String?
            let usspeech: String?
            let trs: [Trs]?

            enum CodingKeys: String, CodingKey {
                case returnPhrase = "return-phrase"
                case ukphone, usphone, ukspeech, usspeech, trs
            }

            struct Trs: Decodable {
                let pos: String?
                let tran: String?
            }
        }
    }

    struct Blng: Decodable {
        let sentencePair: [Pair]?

        enum CodingKeys: String, CodingKey {
            case sentencePair = "sentence-pair"
        }

        struct Pair: Decodable {
            let sentence: String?
            let translation: String?

            enum CodingKeys: String, CodingKey {
                case sentence
                case translation = "sentence-translation"
            }
        }
    }

    struct Phrs: Decodable {
        let phrs: [Phrase]?

        struct Phrase: Decodable {
            let headword: String?
            let translation: String?
        }
    }

    struct RelWord: Decodable {
        let rels: [Entry]?

        struct Entry: Decodable {
            let rel: Rel?
        }

        struct Rel: Decodable {
            let pos: String?
            let words: [Word]?
        }

        struct Word: Decodable {
            let word: String?
            let tran: String?
        }
    }

    let ec: EC?
    let blngSentsPart: Blng?
    let phrs: Phrs?
    let relWord: RelWord?

    enum CodingKeys: String, CodingKey {
        case ec
        case blngSentsPart = "blng_sents_part"
        case phrs
        case relWord = "rel_word"
    }
}
