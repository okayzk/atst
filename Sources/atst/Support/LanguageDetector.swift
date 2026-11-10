import Foundation
import NaturalLanguage

/// On-device language identification via NaturalLanguage. Used for the
/// tooltip's source-language label, the reverse-translation decision and
/// picking a speech voice — none of which should wait on a network call.
enum LanguageDetector {
    struct Detection {
        /// BCP-47 tag: "en", "zh-Hans", "ja".
        let code: String
        /// 0…1. Short single words score low ("bank" ≈ 0.3), so callers
        /// that act on the result rather than display it should gate on it.
        let confidence: Double
    }

    /// Languages the recognizer may answer with — the same set as
    /// `TargetLanguagePreset`. Unconstrained, single Latin-alphabet words
    /// land on random languages ("Chromium" → Polish, "SwiftUI" →
    /// Indonesian); within this set they resolve to English.
    private static let constraints: [NLLanguage] = [
        .english, .simplifiedChinese, .traditionalChinese, .japanese, .korean,
        .french, .german, .spanish, .italian, .portuguese, .russian
    ]

    /// Dominant language of `text`, or nil when the recognizer can't decide.
    static func detect(_ text: String) -> Detection? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return Detection(code: language.rawValue, confidence: confidence)
    }

    /// Primary language subtag: "zh-Hant" → "zh". The recognizer's
    /// Simplified / Traditional split is unreliable on short text, so
    /// comparisons and labels work at the language level.
    static func primary(_ code: String) -> String {
        code.split(separator: "-").first.map(String.init) ?? code
    }

    /// Languages in the Latin-script set the recognizer can answer with.
    static func isLatin(_ code: String) -> Bool {
        ["en", "fr", "de", "es", "it", "pt"].contains(primary(code))
    }

    /// 1–4 Latin words, ≤40 characters. These are the inputs where a
    /// statistical language identifier is least reliable: "General" is a
    /// valid English word but the recognizer confidently calls it Spanish.
    static func isShortLatinPhrase(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard (1...4).contains(words.count) else { return false }
        let pattern = #"^[A-Za-z][A-Za-z'’-]*$"#
        return words.allSatisfy {
            $0.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Human-readable language name in the current UI language
    /// ("English" / "英语", "Chinese" / "中文"), falling back to the tag.
    static func displayName(for code: String) -> String {
        let locale = Locale(identifier: L.isChinese ? "zh_CN" : "en_US")
        let base = primary(code)
        return locale.localizedString(forIdentifier: base) ?? base
    }
}
