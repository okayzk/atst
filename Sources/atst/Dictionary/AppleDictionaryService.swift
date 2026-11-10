import Foundation

/// Offline fallback backed by macOS's own dictionaries.
///
/// We look for the Simplified-Chinese ⇄ English dictionary that ships with
/// macOS (usually shown as 牛津英汉汉英词典 / "Oxford Chinese Dictionary").
/// The data stays on the device; no request leaves the machine.
///
/// Important constraints:
/// - DictionaryServices is a deprecated C API. Swift does not expose a module
///   for it, so we resolve the symbols with `dlopen`/`dlsym` instead of adding
///   a C target.
/// - `DCSCopyRecordsForSearchString` is a private record-level API. It gives us
///   the headword, which lets us reject pinyin collisions such as
///   `run → 闰`; the public `DCSCopyTextDefinition` cannot do that. This is
///   acceptable for the self-signed build, but it is not App Store-safe and
///   may break on any macOS update.
/// - Only single words are supported. Phrases fall through to Youdao: the
///   system dictionary returns the base-word entry for "take off" / "give up"
///   and nothing for "a piece of cake".
/// - The dictionary asset is not guaranteed to be installed. The caller must
///   treat a nil result as "fallback unavailable" and guide the user to
///   Dictionary.app → Settings.
final class AppleDictionaryService {
    static let shared = AppleDictionaryService()

    /// Short name used by the system dictionary bundle.
    private static let chineseEnglishShortName = "Simplified Chinese - English"
    /// Display-name fragment; localized system assets use the Chinese name.
    private static let chineseEnglishNameFragment = "牛津英汉汉英词典"

    private typealias CopyDictionariesFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetNameFn = @convention(c) (OpaquePointer?) -> Unmanaged<CFString>?
    private typealias GetShortNameFn = @convention(c) (OpaquePointer?) -> Unmanaged<CFString>?
    private typealias CopyRecordsFn = @convention(c) (OpaquePointer?, CFString, UInt64, Int64) -> Unmanaged<CFArray>?
    private typealias GetHeadwordFn = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFString>?
    private typealias CopyDataFn = @convention(c) (UnsafeMutableRawPointer?, Int) -> Unmanaged<CFString>?

    private struct Functions {
        let copyDictionaries: CopyDictionariesFn
        let getName: GetNameFn
        let getShortName: GetShortNameFn
        let copyRecords: CopyRecordsFn
        let getHeadword: GetHeadwordFn
        let copyData: CopyDataFn
    }

    private var functions: Functions?
    /// Keeps the CFArray (and therefore each DCSDictionaryRef) alive while
    /// the pointer is in use. A DCSDictionaryRef is borrowed from this array.
    private var cachedDictionaries: NSArray?

    private init() {
        functions = Self.loadFunctions()
    }

    /// Text format version 3 = plain text (see TTTDictionary in Easydict).
    private static let textVersion = 3

    // MARK: - Availability

    /// Display name of the installed Chinese-English dictionary, if any.
    func installedDictionaryName() -> String? {
        findDictionary()?.name
    }

    func isInstalled() -> Bool {
        findDictionary() != nil
    }

    // MARK: - Lookup

    /// Exact-match single-word lookup. Returns nil when the dictionary is
    /// missing or has no record whose headword matches the query.
    func lookup(_ word: String) -> DictionaryEntry? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.split(whereSeparator: \.isWhitespace).count == 1,
              let dictionary = findDictionary(),
              let functions else {
            return nil
        }

        let query = normalize(trimmed)
        let records = functions.copyRecords(dictionary.ref, trimmed as CFString, 0, 0)?
            .takeRetainedValue() as NSArray? ?? []
        var texts: [String] = []

        for case let record as NSObject in records {
            let pointer = Unmanaged.passUnretained(record).toOpaque()
            guard let headword = functions.getHeadword(pointer)?.takeUnretainedValue() as String?,
                  normalize(headword) == query else {
                continue
            }
            if let data = functions.copyData(pointer, Self.textVersion)?.takeRetainedValue() as String?,
               !data.isEmpty {
                texts.append(data)
            }
        }
        guard !texts.isEmpty else { return nil }

        let phonetics = parsePhonetics(from: texts[0])
        let body = texts
            .map { bodyText(from: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !body.isEmpty else { return nil }

        AppLogger.log("apple dict hit q=\(trimmed) records=\(texts.count) chars=\(body.count)")
        return DictionaryEntry(
            headword: trimmed,
            phonetics: phonetics,
            senses: [],
            examples: [],
            phrases: [],
            related: [],
            tags: [],
            rawText: body,
            source: .apple
        )
    }

    // MARK: - Dictionary discovery

    private func findDictionary() -> (name: String, shortName: String, ref: OpaquePointer)? {
        guard let functions,
              let dictionaries = functions.copyDictionaries()?.takeRetainedValue() as NSArray? else {
            return nil
        }
        cachedDictionaries = dictionaries
        for case let object as NSObject in dictionaries {
            let pointer = OpaquePointer(Unmanaged.passUnretained(object).toOpaque())
            let name = functions.getName(pointer)?.takeUnretainedValue() as String? ?? ""
            let shortName = functions.getShortName(pointer)?.takeUnretainedValue() as String? ?? ""
            if name.contains(Self.chineseEnglishNameFragment) || shortName == Self.chineseEnglishShortName {
                return (name, shortName, pointer)
            }
        }
        return nil
    }

    // MARK: - Text parsing
    //
    // The system dictionary returns one flat string per record:
    //   serendipity | BrE ˌsɛr(ə)nˈdɪpɪti, AmE ˌsɛrənˈdɪpədi | noun ... ① ...
    // The structured UI is provided by Youdao; this fallback only needs the
    // headword, phonetics and a readable body.

    private func parsePhonetics(from text: String) -> [DictionaryEntry.Phonetic] {
        let components = text.components(separatedBy: " | ")
        guard components.count >= 2 else { return [] }
        let pronunciation = components[1]
        let regex = try? NSRegularExpression(pattern: #"(BrE|AmE)\s+([^,]+)"#)
        let range = NSRange(pronunciation.startIndex..<pronunciation.endIndex, in: pronunciation)
        var phonetics: [DictionaryEntry.Phonetic] = []
        regex?.enumerateMatches(in: pronunciation, range: range) { match, _, _ in
            guard let match,
                  let accentRange = Range(match.range(at: 1), in: pronunciation),
                  let textRange = Range(match.range(at: 2), in: pronunciation) else { return }
            let accent = String(pronunciation[accentRange]) == "BrE" ? "UK" : "US"
            let value = String(pronunciation[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            phonetics.append(.init(accent: accent, text: value, audioURL: nil))
        }
        return phonetics
    }

    private func bodyText(from text: String) -> String {
        let components = text.components(separatedBy: " | ")
        let body = components.count >= 3
            ? components.dropFirst(2).joined(separator: " | ")
            : text
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Symbol loading

    private static func loadFunctions() -> Functions? {
        // DictionaryServices lives inside CoreServices and is not exposed as a
        // Swift module. Keep the handle open for the process lifetime.
        let path = "/System/Library/Frameworks/CoreServices.framework/"
            + "Frameworks/DictionaryServices.framework/DictionaryServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            AppLogger.log("apple dict: DictionaryServices unavailable")
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let copyDictionaries = symbol("DCSCopyAvailableDictionaries", CopyDictionariesFn.self),
              let getName = symbol("DCSDictionaryGetName", GetNameFn.self),
              let getShortName = symbol("DCSDictionaryGetShortName", GetShortNameFn.self),
              let copyRecords = symbol("DCSCopyRecordsForSearchString", CopyRecordsFn.self),
              let getHeadword = symbol("DCSRecordGetHeadword", GetHeadwordFn.self),
              let copyData = symbol("DCSRecordCopyData", CopyDataFn.self) else {
            AppLogger.log("apple dict: DictionaryServices symbols missing")
            return nil
        }
        return Functions(
            copyDictionaries: copyDictionaries,
            getName: getName,
            getShortName: getShortName,
            copyRecords: copyRecords,
            getHeadword: getHeadword,
            copyData: copyData
        )
    }
}
