import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Equatable {
    case auto
    case light
    case dark
}

/// Persisted enablement / ordering for a single API provider (Google,
/// Microsoft, …). `id` matches the `TranslationProviderID` rawValue so we
/// can resolve it back to a concrete `TranslationProvider` at runtime.
struct APIProviderEntry: Codable, Equatable, Identifiable {
    var id: String
    var enabled: Bool

    init(id: String, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }

    init(kind: TranslationProviderID, enabled: Bool) {
        self.id = kind.rawValue
        self.enabled = enabled
    }

    var kind: TranslationProviderID? { TranslationProviderID(rawValue: id) }
}

struct AppConfiguration: Codable, Equatable {
    // MARK: - Translation mode (NEW in P7)
    /// AI segment (top-level toggle). When off, the tooltip skips the AI
    /// section entirely — both segments may be on at the same time.
    var aiEnabled: Bool
    /// API segment (top-level toggle). When on, every enabled provider in
    /// `apiProviders` runs in parallel and renders as a row above the AI
    /// section.
    var apiEnabled: Bool
    /// Ordered list of built-in API providers + their enable state. UI
    /// surfaces this as a draggable list in the API subpage.
    var apiProviders: [APIProviderEntry]
    /// When on, an API provider that fails mid-translation triggers a
    /// fallback: every other enabled API provider not already on screen is
    /// added to the same translation. The failed row stays visible as an
    /// unreachable result. Off by default.
    var apiFallbackEnabled: Bool
    /// Providers called on every new translation. This is a subset of the
    /// services that are available (top-level toggles + per-provider
    /// enablement); any other enabled service can still be swapped into a
    /// single result from its header. If nothing here matches an available
    /// service, all available services are used so a translation never
    /// silently produces zero rows.
    var defaultProviderIDs: [String]
    /// Show a dictionary card for eligible single words / fixed phrases.
    /// Youdao's keyless web dictionary is the primary source; the macOS
    /// system dictionary is the offline fallback. On by default so the
    /// feature works without setup — the settings page documents the
    /// network/privacy trade-off.
    var dictionaryEnabled: Bool
    /// When on, a successful dictionary lookup replaces the normal API/AI
    /// rows for eligible words/phrases: translation providers are not called.
    /// If the dictionary misses, translation runs as usual. On by default.
    var dictionarySkipsTranslation: Bool
    /// Maximum number of whitespace-separated words that still count as a
    /// dictionary lookup (1...4). Longer input is translated normally only.
    var dictionaryMaxWords: Int

    // MARK: - AI provider config
    var baseURL: String
    var apiKey: String
    var textModel: String
    var screenshotModel: String
    var targetLanguage: String
    /// Used instead of `targetLanguage` when the source is already in the
    /// target language (Chinese ⇄ English for most users). Empty disables
    /// the swap.
    var secondaryTargetLanguage: String
    var systemPrompt: String
    var smartExplanationPrompt: String
    var timeoutSeconds: Double
    var phoneticEnabled: Bool
    var smartExplanationEnabled: Bool
    var smartExplanationExpandedByDefault: Bool
    /// When on, the AI result renders above the API rows instead of below
    /// them. Multi-service results read better with the strongest answer
    /// first; off by default keeps the existing row order.
    var aiResultFirst: Bool

    // MARK: - Screenshot
    /// When on (default), screenshot translation runs macOS Vision OCR
    /// first to extract text, then feeds the text through the regular
    /// multi-provider pipeline (API rows + AI segment). When off, the
    /// screenshot bytes are sent directly to the configured AI vision
    /// model. We auto-fall-back to AI vision when OCR finds no text.
    var screenshotUseVisionOCR: Bool
    /// BCP-47 codes Vision should try when recognising. Order matters —
    /// Vision prefers earlier entries on ambiguity. Defaults to
    /// Simplified Chinese + English + Japanese.
    var ocrLanguages: [String]

    // MARK: - Cross-cutting
    var appearanceMode: AppearanceMode
    /// UI language preference. `.auto` follows the system locale (zh-* →
    /// Chinese, else English); the other cases hard-override.
    var uiLanguage: UILanguage
    var cacheEnabled: Bool
    var cacheTTLDays: Int
    var cacheMaxEntries: Int
    var textHotKey: KeyboardShortcutConfig
    var screenshotHotKey: KeyboardShortcutConfig
    /// When on, pinned notes survive Spaces / desktop switches by joining
    /// every Space (`.canJoinAllSpaces`). Default off because most users
    /// pin a note in the context of one desktop and expect it to stay
    /// there. Opt-in for the "follow me everywhere" workflow.
    var pinnedNoteFollowsAcrossSpaces: Bool
    /// Registers the app as a login item via `SMAppService`. Only takes
    /// effect from a bundled .app — `swift run` builds log and skip.
    var launchAtLogin: Bool
    /// Hides the menu bar status item. Settings stay reachable from the
    /// translation window header and by launching the app again while it
    /// is already running.
    var hideMenuBarIcon: Bool

    static let defaultAPIProviders: [APIProviderEntry] = [
        .init(kind: .google, enabled: true),
        .init(kind: .microsoft, enabled: true),
        .init(kind: .deepl, enabled: true),
        .init(kind: .system, enabled: true)
    ]

    /// Every built-in service is a default until the user narrows the set.
    /// Keeping the IDs (rather than only the currently-enabled ones) means a
    /// provider enabled later joins the defaults without needing a migration.
    static let defaultProviderIDs: [String] = [
        TranslationProviderID.google,
        .microsoft,
        .deepl,
        .system,
        .ai
    ].map(\.rawValue)

    /// Default screenshot OCR languages — Simplified Chinese, English,
    /// Japanese. Covers the bulk of typical user input; settings lets the
    /// user add/remove from the full curated list.
    static let defaultOCRLanguages: [String] = ["zh-Hans", "en-US", "ja-JP"]

    static let defaultConfig = AppConfiguration(
        // AI is off by default — it requires the user to configure base URL /
        // key / model. API translation works out of the box with the
        // built-in Google + Microsoft adapters, so we ship it on.
        aiEnabled: false,
        apiEnabled: true,
        apiProviders: defaultAPIProviders,
        apiFallbackEnabled: false,
        baseURL: "http://localhost:11434/v1",
        apiKey: "",
        textModel: "",
        screenshotModel: "",
        targetLanguage: L.isChinese ? "简体中文" : "English",
        secondaryTargetLanguage: L.isChinese ? "English" : "简体中文",
        systemPrompt: defaultSystemPrompt,
        smartExplanationPrompt: defaultSmartExplanationPrompt,
        // 10s default — long enough for typical word/sentence translations
        // even on a slow LLM, short enough that users notice quickly when
        // the endpoint is unreachable.
        timeoutSeconds: 10,
        phoneticEnabled: false,
        smartExplanationEnabled: false,
        smartExplanationExpandedByDefault: false,
        aiResultFirst: false,
        appearanceMode: .auto,
        uiLanguage: .auto,
        cacheEnabled: true,
        cacheTTLDays: 90,
        cacheMaxEntries: 2000,
        textHotKey: .defaultText,
        screenshotHotKey: .defaultScreenshot,
        screenshotUseVisionOCR: true,
        ocrLanguages: defaultOCRLanguages,
        pinnedNoteFollowsAcrossSpaces: false,
        launchAtLogin: false,
        hideMenuBarIcon: false,
        dictionaryEnabled: true,
        dictionarySkipsTranslation: true,
        dictionaryMaxWords: 4
    )

    static let storageKey = "atst.configuration.v1"

    init(
        aiEnabled: Bool = false,
        apiEnabled: Bool = true,
        apiProviders: [APIProviderEntry] = AppConfiguration.defaultAPIProviders,
        apiFallbackEnabled: Bool = false,
        baseURL: String,
        apiKey: String,
        textModel: String,
        screenshotModel: String,
        targetLanguage: String,
        secondaryTargetLanguage: String = "",
        systemPrompt: String,
        smartExplanationPrompt: String,
        timeoutSeconds: Double,
        phoneticEnabled: Bool = false,
        smartExplanationEnabled: Bool = false,
        smartExplanationExpandedByDefault: Bool = false,
        aiResultFirst: Bool = false,
        appearanceMode: AppearanceMode = .auto,
        uiLanguage: UILanguage = .auto,
        cacheEnabled: Bool = true,
        cacheTTLDays: Int = 90,
        cacheMaxEntries: Int = 2000,
        textHotKey: KeyboardShortcutConfig = .defaultText,
        screenshotHotKey: KeyboardShortcutConfig = .defaultScreenshot,
        screenshotUseVisionOCR: Bool = true,
        ocrLanguages: [String] = AppConfiguration.defaultOCRLanguages,
        pinnedNoteFollowsAcrossSpaces: Bool = false,
        launchAtLogin: Bool = false,
        hideMenuBarIcon: Bool = false,
        defaultProviderIDs: [String] = AppConfiguration.defaultProviderIDs,
        dictionaryEnabled: Bool = true,
        dictionarySkipsTranslation: Bool = true,
        dictionaryMaxWords: Int = 4
    ) {
        self.aiEnabled = aiEnabled
        self.apiEnabled = apiEnabled
        self.apiProviders = apiProviders
        self.apiFallbackEnabled = apiFallbackEnabled
        self.defaultProviderIDs = defaultProviderIDs
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.textModel = textModel
        self.screenshotModel = screenshotModel
        self.targetLanguage = targetLanguage
        self.secondaryTargetLanguage = secondaryTargetLanguage
        self.systemPrompt = systemPrompt
        self.smartExplanationPrompt = smartExplanationPrompt
        self.timeoutSeconds = timeoutSeconds
        self.phoneticEnabled = phoneticEnabled
        self.smartExplanationEnabled = smartExplanationEnabled
        self.smartExplanationExpandedByDefault = smartExplanationExpandedByDefault
        self.aiResultFirst = aiResultFirst
        self.appearanceMode = appearanceMode
        self.uiLanguage = uiLanguage
        self.cacheEnabled = cacheEnabled
        self.cacheTTLDays = cacheTTLDays
        self.cacheMaxEntries = cacheMaxEntries
        self.textHotKey = textHotKey
        self.screenshotHotKey = screenshotHotKey
        self.screenshotUseVisionOCR = screenshotUseVisionOCR
        self.ocrLanguages = ocrLanguages
        self.pinnedNoteFollowsAcrossSpaces = pinnedNoteFollowsAcrossSpaces
        self.launchAtLogin = launchAtLogin
        self.hideMenuBarIcon = hideMenuBarIcon
        self.dictionaryEnabled = dictionaryEnabled
        self.dictionarySkipsTranslation = dictionarySkipsTranslation
        self.dictionaryMaxWords = min(4, max(1, dictionaryMaxWords))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfiguration.defaultConfig

        aiEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? defaults.aiEnabled
        apiEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiEnabled) ?? defaults.apiEnabled
        apiProviders = try container.decodeIfPresent([APIProviderEntry].self, forKey: .apiProviders)
            ?? defaults.apiProviders
        // Healing: make sure every known built-in provider has an entry.
        // Older persisted configs (or future ones missing a newly-added
        // built-in) get topped up with defaults rather than silently losing
        // an option.
        let knownIDs = Set(apiProviders.map(\.id))
        for fallback in defaults.apiProviders where !knownIDs.contains(fallback.id) {
            apiProviders.append(fallback)
        }
        defaultProviderIDs = try container.decodeIfPresent([String].self, forKey: .defaultProviderIDs)
            ?? defaults.defaultProviderIDs
        apiFallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiFallbackEnabled)
            ?? defaults.apiFallbackEnabled
        dictionaryEnabled = try container.decodeIfPresent(Bool.self, forKey: .dictionaryEnabled)
            ?? defaults.dictionaryEnabled
        dictionarySkipsTranslation = try container.decodeIfPresent(Bool.self, forKey: .dictionarySkipsTranslation)
            ?? defaults.dictionarySkipsTranslation
        dictionaryMaxWords = min(4, max(1, try container.decodeIfPresent(Int.self, forKey: .dictionaryMaxWords)
            ?? defaults.dictionaryMaxWords))

        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        textModel = try container.decodeIfPresent(String.self, forKey: .textModel) ?? defaults.textModel
        screenshotModel = try container.decodeIfPresent(String.self, forKey: .screenshotModel) ?? defaults.screenshotModel
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? defaults.targetLanguage
        secondaryTargetLanguage = try container.decodeIfPresent(String.self, forKey: .secondaryTargetLanguage) ?? defaults.secondaryTargetLanguage
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? defaults.systemPrompt
        smartExplanationPrompt = try container.decodeIfPresent(String.self, forKey: .smartExplanationPrompt) ?? defaults.smartExplanationPrompt
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        phoneticEnabled = try container.decodeIfPresent(Bool.self, forKey: .phoneticEnabled) ?? defaults.phoneticEnabled
        smartExplanationEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartExplanationEnabled) ?? defaults.smartExplanationEnabled
        smartExplanationExpandedByDefault = try container.decodeIfPresent(Bool.self, forKey: .smartExplanationExpandedByDefault) ?? defaults.smartExplanationExpandedByDefault
        aiResultFirst = try container.decodeIfPresent(Bool.self, forKey: .aiResultFirst) ?? defaults.aiResultFirst
        appearanceMode = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? defaults.appearanceMode
        uiLanguage = try container.decodeIfPresent(UILanguage.self, forKey: .uiLanguage) ?? defaults.uiLanguage
        cacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .cacheEnabled) ?? defaults.cacheEnabled
        cacheTTLDays = try container.decodeIfPresent(Int.self, forKey: .cacheTTLDays) ?? defaults.cacheTTLDays
        cacheMaxEntries = try container.decodeIfPresent(Int.self, forKey: .cacheMaxEntries) ?? defaults.cacheMaxEntries
        textHotKey = try container.decodeIfPresent(KeyboardShortcutConfig.self, forKey: .textHotKey) ?? defaults.textHotKey
        screenshotHotKey = try container.decodeIfPresent(KeyboardShortcutConfig.self, forKey: .screenshotHotKey) ?? defaults.screenshotHotKey
        screenshotUseVisionOCR = try container.decodeIfPresent(Bool.self, forKey: .screenshotUseVisionOCR) ?? defaults.screenshotUseVisionOCR
        ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? defaults.ocrLanguages
        if ocrLanguages.isEmpty {
            // Healing — if a user somehow saved an empty list, restore the
            // default so OCR still works without manual intervention.
            ocrLanguages = defaults.ocrLanguages
        }
        pinnedNoteFollowsAcrossSpaces = try container.decodeIfPresent(Bool.self, forKey: .pinnedNoteFollowsAcrossSpaces) ?? defaults.pinnedNoteFollowsAcrossSpaces
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        hideMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .hideMenuBarIcon) ?? defaults.hideMenuBarIcon
    }

    var chatCompletionsURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        return URL(string: "\(trimmed)/chat/completions")
    }

    static func load() -> AppConfiguration {
        var config = loadSavedConfig() ?? defaultConfig

        let environment = ProcessInfo.processInfo.environment
        if let value = environment["ATST_AI_BASE_URL"], !value.isEmpty {
            config.baseURL = value
        }
        if let value = environment["ATST_API_KEY"], !value.isEmpty {
            config.apiKey = value
        }
        if let value = environment["ATST_TEXT_MODEL"], !value.isEmpty {
            config.textModel = value
        }
        if let value = environment["ATST_SCREENSHOT_MODEL"], !value.isEmpty {
            config.screenshotModel = value
        }
        if let value = environment["ATST_TARGET_LANGUAGE"], !value.isEmpty {
            config.targetLanguage = value
        }

        return config
    }

    /// Subset of `apiProviders` that's currently enabled AND maps to a
    /// known built-in provider. Order preserved from settings.
    var enabledAPIProviderKinds: [TranslationProviderID] {
        guard apiEnabled else { return [] }
        return apiProviders.compactMap { entry in
            guard entry.enabled,
                  let kind = entry.kind,
                  kind.isRuntimeAvailable else { return nil }
            return kind
        }
    }

    /// Every service the user could call right now: enabled API providers
    /// in their configured order, then AI when its top-level switch is on.
    var availableProviderKinds: [TranslationProviderID] {
        var kinds = enabledAPIProviderKinds
        if aiEnabled {
            kinds.append(.ai)
        }
        return kinds
    }

    /// Services invoked by a new translation. Intersects the saved default
    /// selection with what is currently available; falls back to everything
    /// available when the selection is empty or entirely unavailable.
    var defaultProviderKinds: [TranslationProviderID] {
        let available = availableProviderKinds
        let selected = available.filter { defaultProviderIDs.contains($0.rawValue) }
        return selected.isEmpty ? available : selected
    }

    private static func loadSavedConfig() -> AppConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AppConfiguration.self, from: data)
    }
}

private let defaultSystemPrompt = """
You are atst (a-i-text-select-translate). Translate the user's input into the target language.

Translation rules:
- Produce natural, accurate, idiomatic text in the target language; avoid over-paraphrasing.
- Preserve identifier-like fragments verbatim: code snippets, shell commands, file paths, variable / function / class / API names, error messages, Markdown markers, and URLs.
- When prose and code are mixed, translate the prose only and leave code tokens as they are.
- If the input is already in the target language, echo it unchanged.
- No greetings, prefaces, or self-commentary in your output.
"""

private let defaultSmartExplanationPrompt = """
When the input is a word, short phrase, term, or abbreviation, emit a dictionary-style entry:
- Bold the original term; include the IPA in slashes if you are confident about pronunciation.
- List 1–4 senses, each labelled with part of speech and a short English example sentence with its translation into the target language.
- For technical frameworks, products, or abbreviations (e.g. SwiftUI, Kubernetes, LLM), add a "💡 Explanation" paragraph (2–3 sentences) covering what it is, the domain, and a typical use case.

When the input is a sentence or paragraph:
- Add a note only if the source contains an idiom / proverb / well-known quotation. Provide the meaning and, if known, the origin.
- Add notes for technical terms / product names / framework names — one short line per term.
- If nothing fits, leave the explanation empty rather than padding.
"""
