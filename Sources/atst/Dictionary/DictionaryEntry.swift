import Foundation

/// Source of a dictionary lookup. The card labels this so the user knows
/// whether the data came from the network or the local system dictionary.
enum DictionarySource: String, Codable, Equatable {
    case youdao
    case apple
}

/// Normalized dictionary payload shared by the Youdao web dictionary and the
/// macOS system dictionary fallback. The UI never has to know which source
/// produced it.
struct DictionaryEntry: Codable, Equatable {
    struct Phonetic: Codable, Equatable {
        /// "UK" / "US".
        var accent: String
        var text: String
        var audioURL: String?
    }

    struct Sense: Codable, Equatable {
        /// Part of speech as returned by the source ("n.", "v.", "adj.").
        var partOfSpeech: String
        var meanings: [String]
    }

    struct Example: Codable, Equatable {
        var source: String
        var translation: String
    }

    struct Phrase: Codable, Equatable {
        var headword: String
        var translation: String
    }

    struct Related: Codable, Equatable {
        var partOfSpeech: String
        var words: [String]
    }

    var headword: String
    var phonetics: [Phonetic]
    var senses: [Sense]
    var examples: [Example]
    var phrases: [Phrase]
    var related: [Related]
    var tags: [String]
    /// Apple's DictionaryServices returns one formatted text block rather than
    /// structured senses; the card renders this when `senses` is empty.
    var rawText: String?
    var source: DictionarySource

    var hasContent: Bool {
        if !senses.isEmpty || !examples.isEmpty || !phrases.isEmpty || !related.isEmpty {
            return true
        }
        return !(rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
