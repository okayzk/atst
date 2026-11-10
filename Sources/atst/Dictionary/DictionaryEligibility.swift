import Foundation

/// Decides whether a source text should trigger a dictionary lookup.
///
/// Deliberately narrow: v1 is English → Simplified Chinese, single words and
/// short fixed phrases only. Sentences, code, URLs and numbers go through the
/// normal translation path; the dictionary detector should never steal them.
enum DictionaryEligibility {
    /// 1–4 words is enough for phrasal verbs and idioms such as "take off"
    /// and "a piece of cake"; anything longer is very unlikely to be a
    /// dictionary headword.
    ///
    /// Eligibility is based on the *configured* language pair, not the
    /// detected effective target: single-word language detection is noisy
    /// ("General" is confidently detected as Spanish), and reverse
    /// translation may therefore keep English as the target. If either the
    /// primary or secondary target is Simplified Chinese, an English-looking
    /// word still deserves an EN→ZH dictionary card.
    static func isEligible(
        text: String,
        targetLanguage: String,
        secondaryTargetLanguage: String,
        maxWords: Int
    ) -> Bool {
        let cleaned = trimmedQuotes(text)
        guard !cleaned.isEmpty, cleaned.count <= 40 else { return false }

        guard isSimplifiedChinese(targetLanguage)
                || isSimplifiedChinese(secondaryTargetLanguage) else {
            return false
        }

        let words = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        let limit = min(4, max(1, maxWords))
        guard (1...limit).contains(words.count) else { return false }

        let tokenPattern = #"^[A-Za-z][A-Za-z'’-]*$"#
        for word in words {
            guard word.range(of: tokenPattern, options: .regularExpression) != nil else {
                return false
            }
        }
        return true
    }

    static func isSimplifiedChinese(_ language: String) -> Bool {
        let code = LanguageCode.bcp47(from: language)?.lowercased() ?? ""
        return code == "zh" || code == "zh-cn" || code == "zh-hans"
    }

    /// Strip matching quotes around a selection; keep apostrophes inside words.
    private static func trimmedQuotes(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("“", "”"), ("‘", "’"), ("'", "'")
        ]
        for (open, close) in pairs {
            if value.count >= 2, value.first == open, value.last == close {
                value.removeFirst()
                value.removeLast()
                break
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
