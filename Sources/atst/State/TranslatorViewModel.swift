import AppKit
import Combine
import Foundation

@MainActor
final class TranslatorViewModel: ObservableObject {
    @Published private(set) var state: TranslationState = .idle
    @Published private(set) var configuration: AppConfiguration
    @Published var pinned: Bool = false
    /// Draft text for the manual-entry editor. Lives here (not in the
    /// SwiftUI view) so the input box can be prefilled when the user
    /// re-edits the source of a finished manual translation.
    @Published var inputDraft: String = ""
    /// The manual translation the user is currently re-editing, shown
    /// below the editor while they type. Provider tasks keep updating this
    /// snapshot, so a translation that is still streaming doesn't freeze
    /// when the editor opens.
    @Published private(set) var inputPrevious: TextSegments?
    /// Bumped whenever a new translation starts. The tooltip resets its
    /// per-result collapse state on a change; a provider switch does not
    /// bump it because that's still the same translation.
    @Published private(set) var translationGeneration: Int = 0

    private let settingsStore: SettingsStore
    private let selectedTextProvider: SelectedTextProvider
    private var cancellables = Set<AnyCancellable>()
    /// Tasks driving the currently-visible text translation — one per
    /// active provider segment, keyed by provider so a single result can
    /// be switched without disturbing the others. Replaced wholesale
    /// whenever a new selection arrives so older results can't write into
    /// the newer state.
    private var activeTextSegmentTasks: [TranslationProviderID: Task<Void, Never>] = [:]
    /// One dictionary lookup at a time. Dictionary data is auxiliary: it must
    /// never keep a translation task alive or block the normal provider rows.
    private var activeDictionaryTask: Task<Void, Never>?
    /// Per-provider run of failures since the last success, in memory only.
    /// Drives the collapsed "failed N times · Disable" row so a blocked
    /// endpoint stops shouting a full error on every translation.
    private var consecutiveFailures: [TranslationProviderID: Int] = [:]

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.configuration = settingsStore.configuration
        self.selectedTextProvider = SelectedTextProvider()

        settingsStore.$configuration
            .sink { [weak self] configuration in
                self?.configuration = configuration
            }
            .store(in: &cancellables)
    }

    func readCurrentSelection() async throws -> SelectedText {
        try await selectedTextProvider.selectedText()
    }

    /// Seed the visible state with placeholder segments so the tooltip can
    /// render its spinners immediately, before any provider has replied.
    /// Caller invokes this synchronously from the hotkey handler so we beat
    /// the network on screen.
    func beginTextTranslation(source: String, sourceEditable: Bool = false) {
        translationGeneration += 1
        inputDraft = ""
        inputPrevious = nil
        let languages = resolveLanguages(for: source)
        let segments = makePlaceholderSegments(targetLanguage: languages.target)
        if segments.api.isEmpty && segments.ai == nil {
            state = .text(TextSegments(
                source: source,
                api: [],
                ai: nil,
                bothDisabled: true,
                sourceEditable: sourceEditable
            ))
        } else {
            state = .text(TextSegments(
                source: source,
                api: segments.api,
                ai: segments.ai,
                bothDisabled: false,
                sourceLanguage: languages.source,
                targetLanguage: languages.target,
                sourceEditable: sourceEditable
            ))
        }
    }

    /// Detected source language (header label) plus the target language the
    /// providers should translate into. When the source is confidently
    /// already in the target language, swap to the secondary target —
    /// otherwise every provider would just echo the input as untranslatable.
    private func resolveLanguages(for source: String) -> (source: String?, target: String) {
        let detection = LanguageDetector.detect(source)
        var target = configuration.targetLanguage
        let secondary = configuration.secondaryTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetCode = LanguageCode.bcp47(from: target)?.lowercased()
        let secondaryCode = LanguageCode.bcp47(from: secondary)?.lowercased()

        var sourceCode = detection?.code
        var confidence = detection?.confidence ?? 0

        // Short Latin words are inherently ambiguous ("General" is both
        // English and Spanish; NaturalLanguage picks Spanish at 0.78). If the
        // recognizer picked a language outside the user's configured pair,
        // prefer a Latin language from that pair. Sentences are left alone.
        if LanguageDetector.isShortLatinPhrase(source) {
            let configured = [targetCode, secondaryCode].compactMap { $0 }
            let detectedPrimary = sourceCode.map(LanguageDetector.primary)
            let isConfigured = detectedPrimary.map { primary in
                configured.contains { LanguageDetector.primary($0) == primary }
            } ?? false
            if !isConfigured, let latin = configured.first(where: LanguageDetector.isLatin) {
                sourceCode = latin
                confidence = max(confidence, 0.5)
            }
        }

        if let sourceCode, confidence >= 0.5,
           !secondary.isEmpty, secondary != target,
           let targetCode,
           LanguageDetector.primary(sourceCode) == LanguageDetector.primary(targetCode) {
            target = secondary
        }
        return (sourceCode, target)
    }

    func beginScreenshotTranslation() {
        state = .screenshotLoading(
            message: L.pick("Translating…", "翻译中…"),
            model: configuration.screenshotModel,
            source: L.pick("Screenshot translation", "截图翻译")
        )
    }

    /// Transitional state shown while we're running Vision OCR on the
    /// freshly-captured screenshot, before any provider has been touched.
    /// Reuses the `.screenshotLoading` case with a different message so
    /// the tooltip just shows a spinner + the right text; once OCR is
    /// done AppDelegate calls `beginTextTranslation(...)` and the state
    /// transitions into the regular dual-segment text UI.
    func beginScreenshotOCR() {
        state = .screenshotLoading(
            message: L.pick("Recognising text…", "识别截图文字…"),
            model: "",
            source: L.pick("Screenshot translation", "截图翻译")
        )
    }

    /// Kick off the configured text providers in parallel. Cache lookups
    /// happen per-segment up front; on cache miss we spawn a Task per
    /// provider and let each one update its own segment as it completes.
    func translateSelection(
        _ selection: SelectedText,
        bypassCache: Bool = false,
        sourceEditable: Bool = false
    ) async {
        cancelActiveTextTasks()

        let languages = resolveLanguages(for: selection.text)
        let providers = buildEnabledProviders(targetLanguage: languages.target)

        // Dictionary-first mode: for eligible words/phrases, wait for the
        // dictionary before calling any translation provider. A hit shows the
        // card alone; a miss starts the normal providers.
        let dictionaryFirst = configuration.dictionaryEnabled
            && configuration.dictionarySkipsTranslation
            && DictionaryEligibility.isEligible(
                text: selection.text,
                targetLanguage: configuration.targetLanguage,
                secondaryTargetLanguage: configuration.secondaryTargetLanguage,
                maxWords: configuration.dictionaryMaxWords
            )
        if dictionaryFirst {
            state = .text(TextSegments(
                source: selection.text,
                api: [],
                ai: nil,
                bothDisabled: false,
                sourceLanguage: "en",
                targetLanguage: preferredChineseTarget(),
                sourceEditable: sourceEditable,
                dictionary: DictionarySegment(state: .loading),
                dictionaryFirst: true
            ))
            startDictionaryLookupIfNeeded(
                source: selection.text,
                bypassCache: bypassCache,
                markLoading: false,
                onMiss: { [weak self] in
                    self?.startProvidersAfterDictionaryMiss(bypassCache: bypassCache)
                }
            )
            return
        }

        if noTranslatorEnabled {
            // Both top-level switches are off — short-circuit to the
            // empty-state tooltip with the "Open settings" CTA.
            state = .text(TextSegments(
                source: selection.text,
                api: [],
                ai: nil,
                bothDisabled: true,
                sourceEditable: sourceEditable
            ))
            return
        }
        if providers.isEmpty {
            // Switches are on but every resolved provider was filtered out
            // (e.g. API toggle on with every provider disabled). Render an
            // explanatory empty state so the user doesn't get a silent
            // tooltip with no segments.
            state = .text(TextSegments(
                source: selection.text,
                api: [],
                ai: nil,
                bothDisabled: true,
                sourceEditable: sourceEditable
            ))
            return
        }

        startProviderTranslation(
            source: selection.text,
            sourceEditable: sourceEditable,
            languages: languages,
            providers: providers,
            bypassCache: bypassCache
        )
        startDictionaryLookupIfNeeded(source: selection.text, bypassCache: bypassCache)
    }

    /// Seed and start the configured translation providers. Extracted so the
    /// dictionary-first path can defer it until the dictionary misses.
    private func startProviderTranslation(
        source: String,
        sourceEditable: Bool,
        languages: (source: String?, target: String),
        providers: [TranslationProvider],
        bypassCache: Bool
    ) {
        var apiSegments: [ProviderSegment] = []
        var aiSegment: ProviderSegment? = nil
        var sawCacheMiss = false
        for provider in providers {
            let id = provider.id
            let cachedEntry = bypassCache ? nil : lookupCache(for: provider, source: source, targetLanguage: languages.target)
            let initialState: SegmentState
            if let entry = cachedEntry {
                initialState = .success(output: entry.output, latencyMs: nil, fromCache: true, cacheInfo: TranslationCache.CacheInfo(cachedAt: entry.createdAt, source: entry.source))
            } else {
                initialState = .loading
                sawCacheMiss = true
            }
            let segment = ProviderSegment(
                id: id,
                displayName: provider.displayName,
                modelHint: provider.modelHint,
                state: initialState
            )
            if id.segmentKind == .ai {
                aiSegment = segment
            } else {
                apiSegments.append(segment)
            }
        }

        // Count this as a "new translation" if at least one segment had
        // to actually call a provider. bypassCache (refresh button) always
        // forces a miss so it counts here too.
        if sawCacheMiss {
            TranslationStats.shared.recordCacheMiss()
        }

        state = .text(TextSegments(
            source: source,
            api: apiSegments,
            ai: aiSegment,
            bothDisabled: false,
            sourceLanguage: languages.source,
            targetLanguage: languages.target,
            sourceEditable: sourceEditable
        ))

        // For each provider that wasn't a cache hit, kick off a Task. Each
        // task updates its own segment in place; tasks are independent so
        // a fast provider lands first even if a slow one is still running.
        for provider in providers {
            let segment = segment(for: provider.id)
            if case .success(_, _, true, _) = segment?.state {
                continue
            }
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.run(provider: provider, source: source, targetLanguage: languages.target)
            }
            activeTextSegmentTasks[provider.id] = task
        }
    }

    /// Dictionary-first lookup missed: start the normal providers on the
    /// selection that is already on screen. If there are no usable
    /// translators, fall back to the usual empty state.
    private func startProvidersAfterDictionaryMiss(bypassCache: Bool) {
        guard case .text(let segments) = state, segments.dictionaryFirst else { return }

        let languages = resolveLanguages(for: segments.source)
        let providers = buildEnabledProviders(targetLanguage: languages.target)
        if noTranslatorEnabled || providers.isEmpty {
            state = .text(TextSegments(
                source: segments.source,
                api: [],
                ai: nil,
                bothDisabled: true,
                sourceEditable: segments.sourceEditable
            ))
            return
        }

        startProviderTranslation(
            source: segments.source,
            sourceEditable: segments.sourceEditable,
            languages: languages,
            providers: providers,
            bypassCache: bypassCache
        )
    }

    /// The Chinese target shown while a dictionary-first lookup is running.
    private func preferredChineseTarget() -> String {
        if DictionaryEligibility.isSimplifiedChinese(configuration.targetLanguage) {
            return configuration.targetLanguage
        }
        if DictionaryEligibility.isSimplifiedChinese(configuration.secondaryTargetLanguage) {
            return configuration.secondaryTargetLanguage
        }
        return configuration.targetLanguage
    }

    func translateScreenshot(_ capture: ScreenshotCapture) async {
        do {
            let service = ScreenshotVisionService(configuration: configuration)
            let raw = try await service.streamTranslateScreenshot(capture.imageData) { [weak self] delta in
                self?.appendScreenshotDelta(delta)
            }
            let output = TranslationOutputParser.parse(raw)
            let trimmed = output.result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || Self.looksLikeNoTextFallback(trimmed) {
                let preview = raw.replacingOccurrences(of: "\n", with: " ").prefix(300)
                AppLogger.log("screenshot translation flagged as no-text. rawLen=\(raw.count) parsedLen=\(trimmed.count) screenshotPath=\(capture.savedPath) rawPreview=\(preview)")
                state = .failure(DisplayError(AppError.noScreenshotText))
            } else {
                AppLogger.log("screenshot translation ok parsedLen=\(trimmed.count) screenshotPath=\(capture.savedPath)")
                // Vision-path screenshots aren't cached (each image is unique),
                // so a successful AI-vision result is always a "new" translation.
                TranslationStats.shared.recordCacheMiss()
                state = .screenshotSuccess(
                    output: output,
                    source: L.pick("Screenshot translation", "截图翻译"),
                    model: configuration.screenshotModel
                )
            }
        } catch {
            state = .failure(DisplayError(error))
        }
    }

    func showError(_ error: Error) {
        state = .failure(DisplayError(error))
    }

    /// Show the manual-entry editor. `prefill` and `previous` are used when
    /// the user clicks the source block of a finished manual translation:
    /// the editor opens with the original text and the previous result
    /// stays visible underneath. A fresh ⌥D input passes neither.
    func showInput(prefill: String = "", previous: TextSegments? = nil) {
        if previous == nil {
            cancelActiveTextTasks()
        }
        inputDraft = prefill
        inputPrevious = previous
        state = .input
    }

    /// Translate text this session already holds. The live tooltip goes
    /// through `AppDelegate`, which also owns the panel; pinned notes call
    /// this directly so their header refresh and manual editor use the same
    /// provider/cache pipeline.
    func translateText(_ text: String, bypassCache: Bool, sourceEditable: Bool? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let editable = sourceEditable ?? state.isSourceEditable
        TranslationStats.shared.recordTranslation()
        beginTextTranslation(source: trimmed, sourceEditable: editable)
        let selection = SelectedText(text: trimmed, anchorRect: nil)
        Task { [weak self] in
            guard let self else { return }
            await self.translateSelection(selection, bypassCache: bypassCache, sourceEditable: editable)
        }
    }

    /// "Disable" on a collapsed failure row. Persists through the settings
    /// store so the provider stops running, and drops its row from the
    /// tooltip that's currently on screen.
    func disableAPIProvider(_ id: TranslationProviderID) {
        var config = settingsStore.configuration
        guard let index = config.apiProviders.firstIndex(where: { $0.id == id.rawValue }) else { return }
        config.apiProviders[index].enabled = false
        do {
            try settingsStore.save(config)
        } catch {
            AppLogger.log("disable provider \(id.rawValue) failed to save: \(error)")
            return
        }
        consecutiveFailures[id] = 0
        activeTextSegmentTasks.removeValue(forKey: id)?.cancel()
        if case .text(var segments) = state {
            segments.api.removeAll { $0.id == id }
            state = .text(segments)
        }
    }

    /// Swap one visible result to another available provider. The old
    /// provider's in-flight request is cancelled; the replacement is seeded
    /// from cache when possible, otherwise its request starts immediately.
    /// This only changes the current translation — the next translation
    /// goes back to the configured default services.
    func switchProvider(from oldID: TranslationProviderID, to newID: TranslationProviderID) {
        guard oldID != newID,
              case .text(var segments) = state,
              !segments.allSegments.contains(where: { $0.id == newID }) else {
            return
        }

        let target = segments.targetLanguage.isEmpty
            ? resolveLanguages(for: segments.source).target
            : segments.targetLanguage
        guard let provider = makeProvider(for: newID, targetLanguage: target) else { return }

        activeTextSegmentTasks.removeValue(forKey: oldID)?.cancel()
        activeTextSegmentTasks.removeValue(forKey: newID)?.cancel()

        let cached = lookupCache(for: provider, source: segments.source, targetLanguage: target)
        let initialState: SegmentState
        if let entry = cached {
            initialState = .success(
                output: entry.output,
                latencyMs: nil,
                fromCache: true,
                cacheInfo: TranslationCache.CacheInfo(cachedAt: entry.createdAt, source: entry.source)
            )
        } else {
            initialState = .loading
        }
        let replacement = ProviderSegment(
            id: newID,
            displayName: provider.displayName,
            modelHint: provider.modelHint,
            state: initialState
        )

        if newID == .ai {
            segments.api.removeAll { $0.id == oldID }
            segments.ai = replacement
        } else if oldID == .ai {
            segments.ai = nil
            segments.api.append(replacement)
        } else if let index = segments.api.firstIndex(where: { $0.id == oldID }) {
            segments.api[index] = replacement
        } else {
            return
        }
        state = .text(segments)

        guard cached == nil else { return }
        TranslationStats.shared.recordCacheMiss()
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.run(provider: provider, source: segments.source, targetLanguage: target)
        }
        activeTextSegmentTasks[newID] = task
    }

    /// "Call all other enabled services" from a result's switch menu.
    /// Keeps every row already on screen and adds each enabled provider
    /// that isn't displayed yet, using cache when possible. This is still
    /// the same translation, so it doesn't bump `translationGeneration`
    /// (existing collapsed rows stay collapsed).
    func addAllAvailableProviders() {
        guard case .text(let segments) = state else { return }
        let used = Set(segments.allSegments.map(\.id))
        let additions = configuration.availableProviderKinds.filter { !used.contains($0) }
        addProviders(additions)
    }

    /// Append providers to the translation currently on screen. Existing
    /// rows are left untouched — the API fallback relies on this to keep
    /// the failed provider visible as an unreachable result.
    private func addProviders(_ additions: [TranslationProviderID]) {
        guard !additions.isEmpty, case .text(var segments) = state else { return }

        let source = segments.source
        let target = segments.targetLanguage.isEmpty
            ? resolveLanguages(for: source).target
            : segments.targetLanguage

        var pending: [(provider: TranslationProvider, segment: ProviderSegment, cacheHit: Bool)] = []
        for kind in additions {
            guard let provider = makeProvider(for: kind, targetLanguage: target) else { continue }
            let cached = lookupCache(for: provider, source: source, targetLanguage: target)
            let initialState: SegmentState
            if let entry = cached {
                initialState = .success(
                    output: entry.output,
                    latencyMs: nil,
                    fromCache: true,
                    cacheInfo: TranslationCache.CacheInfo(cachedAt: entry.createdAt, source: entry.source)
                )
            } else {
                initialState = .loading
            }
            let segment = ProviderSegment(
                id: kind,
                displayName: provider.displayName,
                modelHint: provider.modelHint,
                state: initialState
            )
            pending.append((provider: provider, segment: segment, cacheHit: cached != nil))
        }
        guard !pending.isEmpty else { return }

        for item in pending {
            if item.segment.id == .ai {
                segments.ai = item.segment
            } else {
                segments.api.append(item.segment)
            }
        }
        state = .text(segments)

        var sawCacheMiss = false
        for item in pending where !item.cacheHit {
            sawCacheMiss = true
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.run(provider: item.provider, source: source, targetLanguage: target)
            }
            activeTextSegmentTasks[item.segment.id] = task
        }
        if sawCacheMiss {
            TranslationStats.shared.recordCacheMiss()
        }
    }

    /// API fallback: when an enabled API provider cannot be reached and the
    /// user opted in, add every other enabled API provider that isn't on
    /// screen yet. The failed row stays visible — fallback only appends.
    private func fallbackAfterFailure(
        from failedID: TranslationProviderID,
        source: String
    ) {
        guard configuration.apiFallbackEnabled,
              case .text(let segments) = state,
              segments.source == source else {
            return
        }
        let used = Set(segments.allSegments.map(\.id))
        let additions = configuration.enabledAPIProviderKinds.filter {
            $0 != failedID && !used.contains($0)
        }
        guard !additions.isEmpty else { return }
        AppLogger.log(
            "api fallback after \(failedID.rawValue) failure, adding "
            + additions.map(\.rawValue).joined(separator: ",")
        )
        addProviders(additions)
    }

    // MARK: - Dictionary lookup

    /// Dictionary data is auxiliary: start it in parallel with the normal
    /// providers, never let it block them, and hide it silently when both
    /// sources miss. Youdao is the primary source; the macOS system
    /// dictionary is the single-word offline fallback.
    private func startDictionaryLookupIfNeeded(
        source: String,
        bypassCache: Bool,
        markLoading: Bool = true,
        onMiss: (() -> Void)? = nil
    ) {
        guard configuration.dictionaryEnabled,
              DictionaryEligibility.isEligible(
                  text: source,
                  targetLanguage: configuration.targetLanguage,
                  secondaryTargetLanguage: configuration.secondaryTargetLanguage,
                  maxWords: configuration.dictionaryMaxWords
              ) else {
            return
        }

        let generation = translationGeneration
        activeDictionaryTask?.cancel()
        if markLoading {
            updateDictionary(DictionarySegment(state: .loading), generation: generation)
        }
        activeDictionaryTask = Task { [weak self] in
            guard let self else { return }
            await self.runDictionaryLookup(
                query: source.trimmingCharacters(in: .whitespacesAndNewlines),
                bypassCache: bypassCache,
                generation: generation,
                onMiss: onMiss
            )
        }
    }

    private func runDictionaryLookup(
        query: String,
        bypassCache: Bool,
        generation: Int,
        onMiss: (() -> Void)?
    ) async {
        let cacheKey = DictionaryCache.key(for: query)
        if !bypassCache, configuration.cacheEnabled,
           let cached = DictionaryCache.shared.get(key: cacheKey) {
            updateDictionary(
                DictionarySegment(state: .success(cached)),
                generation: generation,
                clearDictionaryFirst: true
            )
            return
        }

        do {
            if let entry = try await YoudaoDictionaryService().lookup(query) {
                try Task.checkCancellation()
                if configuration.cacheEnabled {
                    DictionaryCache.shared.put(key: cacheKey, entry: entry)
                }
                updateDictionary(
                    DictionarySegment(state: .success(entry)),
                    generation: generation,
                    clearDictionaryFirst: true
                )
                return
            }
        } catch is CancellationError {
            return
        } catch {
            AppLogger.log("youdao dict failed q=\(query): \(error)")
        }

        // The system dictionary only has single-word entries; phrases stay
        // with Youdao. It is fully offline and returns in a few milliseconds.
        if query.split(whereSeparator: \.isWhitespace).count == 1,
           let entry = AppleDictionaryService.shared.lookup(query) {
            if configuration.cacheEnabled {
                DictionaryCache.shared.put(key: cacheKey, entry: entry)
            }
            updateDictionary(
                DictionarySegment(state: .success(entry)),
                generation: generation,
                clearDictionaryFirst: true
            )
            return
        }

        // Dictionary-first mode: keep the loading state until the provider
        // seeding replaces it, so the onMiss handler can see the flag.
        if let onMiss {
            guard generation == translationGeneration else { return }
            onMiss()
        } else {
            updateDictionary(nil, generation: generation)
        }
    }

    private func updateDictionary(
        _ dictionary: DictionarySegment?,
        generation: Int,
        clearDictionaryFirst: Bool = false
    ) {
        guard generation == translationGeneration,
              case .text(var segments) = state else {
            return
        }
        segments.dictionary = dictionary
        if clearDictionaryFirst {
            segments.dictionaryFirst = false
        }
        state = .text(segments)
    }

    /// Create an independent session for a pinned note. The note receives
    /// the current state and its own provider tasks, so switching,
    /// collapsing, and re-editing behave exactly like the live tooltip.
    /// Returns nil when there is nothing meaningful to pin.
    func makeDetachedSession() -> TranslatorViewModel? {
        switch state {
        case .text(let segments):
            guard segments.hasAnyContent else { return nil }
        case .screenshotSuccess(let output, _, _),
             .screenshotStreaming(_, let output, _, _):
            guard !output.items.isEmpty else { return nil }
        case .idle, .input, .screenshotLoading, .failure:
            return nil
        }

        let session = TranslatorViewModel(settingsStore: settingsStore)
        session.state = state
        session.translationGeneration = translationGeneration
        session.inputDraft = inputDraft
        session.inputPrevious = inputPrevious
        cancelActiveTextTasks()
        if case .text = state {
            session.resumeUnfinishedSegments()
        }
        return session
    }

    /// Take over a pinned note's session when it is unpinned back into the
    /// live tooltip. Unfinished providers are restarted on this session.
    func adoptState(from other: TranslatorViewModel) {
        cancelActiveTextTasks()
        other.cancelActiveTranslations()
        state = other.state
        inputDraft = other.inputDraft
        inputPrevious = other.inputPrevious
        translationGeneration = other.translationGeneration
        if case .text = state {
            resumeUnfinishedSegments()
        }
    }

    /// Public hook for a note that is closing: stop its network work.
    func cancelActiveTranslations() {
        cancelActiveTextTasks()
    }

    // MARK: - Provider plumbing

    /// Build the list of providers we should fan out to, honoring the
    /// user's default-service selection on top of the AI/API top-level
    /// toggles. AI is included without a configured model so its segment
    /// can surface a "model not configured" error inline instead of
    /// silently disappearing. API providers come from the user's enabled
    /// list in the order they're defined in settings.
    private func buildEnabledProviders(targetLanguage: String) -> [TranslationProvider] {
        configuration.defaultProviderKinds.compactMap { kind in
            makeProvider(for: kind, targetLanguage: targetLanguage)
        }
    }

    /// The AI provider reads its target from the configuration, so hand it
    /// a copy with the effective target substituted in.
    private func makeAIProvider(targetLanguage: String) -> OpenAIProvider {
        var config = configuration
        config.targetLanguage = targetLanguage
        return OpenAIProvider(configuration: config)
    }

    /// True only when the user has flipped both top-level switches off.
    /// "AI on but no model" or "API on with all providers disabled" are
    /// surfaced inline as segment errors / empty rows instead of via this
    /// global empty-state path.
    private var noTranslatorEnabled: Bool {
        !configuration.aiEnabled && !configuration.apiEnabled
    }

    private func makeProvider(for kind: TranslationProviderID, targetLanguage: String) -> TranslationProvider? {
        switch kind {
        case .ai:
            return makeAIProvider(targetLanguage: targetLanguage)
        case .google:
            return GoogleProvider(targetLanguage: targetLanguage)
        case .microsoft:
            return MicrosoftProvider(targetLanguage: targetLanguage)
        case .deepl:
            return DeepLProvider(targetLanguage: targetLanguage)
        }
    }

    /// Pre-flight placeholder segments used by `beginTextTranslation`. Mirrors
    /// what `translateSelection` will seed once it has the selection, so the
    /// hotkey-to-first-frame path doesn't flash an empty tooltip.
    private func makePlaceholderSegments(targetLanguage: String) -> (api: [ProviderSegment], ai: ProviderSegment?) {
        var apiSegments: [ProviderSegment] = []
        var aiSegment: ProviderSegment? = nil
        for kind in configuration.defaultProviderKinds {
            let provider = makeProvider(for: kind, targetLanguage: targetLanguage)
            let segment = ProviderSegment(
                id: kind,
                displayName: provider?.displayName ?? kind.displayName,
                modelHint: provider?.modelHint,
                state: .loading
            )
            if kind == .ai {
                aiSegment = segment
            } else {
                apiSegments.append(segment)
            }
        }
        return (apiSegments, aiSegment)
    }

    private func cancelActiveTextTasks() {
        for task in activeTextSegmentTasks.values { task.cancel() }
        activeTextSegmentTasks.removeAll()
        activeDictionaryTask?.cancel()
        activeDictionaryTask = nil
    }

    /// Restart providers whose segment was still loading or streaming when
    /// a session was detached/adopted. Completed and failed segments are
    /// kept, and a cache hit is applied without another request.
    private func resumeUnfinishedSegments() {
        guard case .text(let segments) = state,
              !segments.targetLanguage.isEmpty else {
            return
        }
        let source = segments.source
        let target = segments.targetLanguage

        for segment in segments.allSegments {
            switch segment.state {
            case .success, .failure:
                continue
            case .loading, .streaming:
                guard let provider = makeProvider(for: segment.id, targetLanguage: target) else { continue }
                if let entry = lookupCache(for: provider, source: source, targetLanguage: target) {
                    updateSegment(id: segment.id) { current in
                        current.state = .success(
                            output: entry.output,
                            latencyMs: nil,
                            fromCache: true,
                            cacheInfo: TranslationCache.CacheInfo(cachedAt: entry.createdAt, source: entry.source)
                        )
                    }
                    continue
                }
                let task: Task<Void, Never> = Task { [weak self] in
                    guard let self else { return }
                    await self.run(provider: provider, source: source, targetLanguage: target)
                }
                activeTextSegmentTasks[segment.id] = task
            }
        }

        if let dictionary = segments.dictionary, case .loading = dictionary.state {
            let onMiss: (() -> Void)? = segments.dictionaryFirst
                ? { [weak self] in self?.startProvidersAfterDictionaryMiss(bypassCache: false) }
                : nil
            startDictionaryLookupIfNeeded(
                source: source,
                bypassCache: false,
                markLoading: false,
                onMiss: onMiss
            )
        }
    }

    /// Drive a single provider's translate() stream and patch the matching
    /// segment in `state` on each emission / final / failure. Streaming
    /// providers (AI) call this with many emissions; APIs call once.
    private func run(provider: TranslationProvider, source: String, targetLanguage: String) async {
        let started = Date()
        let cacheKey = cacheKey(for: provider, source: source, targetLanguage: targetLanguage)
        do {
            for try await emission in provider.translate(text: source) {
                try Task.checkCancellation()
                let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
                if emission.isFinal {
                    consecutiveFailures[provider.id] = 0
                    updateSegment(id: provider.id) { segment in
                        segment.state = .success(
                            output: emission.output,
                            latencyMs: latencyMs,
                            fromCache: false,
                            cacheInfo: nil
                        )
                        segment.consecutiveFailures = 0
                    }
                    // Cache only successful, non-untranslatable results that
                    // actually produced content.
                    if let key = cacheKey,
                       Self.shouldCache(source: source, output: emission.output) {
                        let cacheSource: TranslationCache.Source = provider.id.segmentKind == .ai ? .ai : .api
                        TranslationCache.shared.put(
                            key: key,
                            source: cacheSource,
                            output: emission.output,
                            model: provider.modelHint ?? provider.displayName,
                            sourceText: source
                        )
                    } else {
                        AppLogger.log("cache skipped for \(provider.id.rawValue): untranslatable=\(emission.output.untranslatable)")
                    }
                } else {
                    updateSegment(id: provider.id) { segment in
                        segment.state = .streaming(raw: emission.raw, output: emission.output)
                    }
                }
            }
        } catch is CancellationError {
            // Surface nothing — a newer translation has already replaced our
            // segments; writing into a stale segment would race.
        } catch {
            consecutiveFailures[provider.id, default: 0] += 1
            let failures = consecutiveFailures[provider.id, default: 0]
            updateSegment(id: provider.id) { segment in
                segment.state = .failure(DisplayError(error))
                segment.consecutiveFailures = failures
            }
            AppLogger.log("provider \(provider.id.rawValue) failed (\(failures) in a row): \(error)")
            if provider.id.segmentKind == .api {
                fallbackAfterFailure(from: provider.id, source: source)
            }
        }
    }

    private func cacheKey(for provider: TranslationProvider, source: String, targetLanguage: String) -> String? {
        switch provider.id.segmentKind {
        case .ai:
            var config = configuration
            config.targetLanguage = targetLanguage
            return TranslationCache.makeAIKey(text: source, configuration: config)
        case .api:
            return TranslationCache.makeProviderKey(
                providerID: provider.id,
                text: source,
                targetLanguage: targetLanguage
            )
        }
    }

    private func lookupCache(for provider: TranslationProvider, source: String, targetLanguage: String) -> TranslationCache.Entry? {
        guard let key = cacheKey(for: provider, source: source, targetLanguage: targetLanguage) else { return nil }
        return TranslationCache.shared.get(key: key)
    }

    private func segment(for id: TranslationProviderID) -> ProviderSegment? {
        guard case .text(let segments) = state else { return nil }
        if let api = segments.api.first(where: { $0.id == id }) { return api }
        if segments.ai?.id == id { return segments.ai }
        return nil
    }

    /// Mutate the segment matching `id` in place. No-op if the current state
    /// isn't a text translation or no segment matches — covers the race
    /// where a newer selection arrived between this task's await and now.
    private func updateSegment(id: TranslationProviderID, mutate: (inout ProviderSegment) -> Void) {
        if case .text(var segments) = state {
            if let index = segments.api.firstIndex(where: { $0.id == id }) {
                mutate(&segments.api[index])
                state = .text(segments)
                return
            }
            if var ai = segments.ai, ai.id == id {
                mutate(&ai)
                segments.ai = ai
                state = .text(segments)
            }
            return
        }

        // While the user re-edits the source of a manual translation, the
        // previous result lives in `inputPrevious`. Keep patching it so a
        // provider that is still streaming finishes instead of freezing
        // behind the editor.
        if case .input = state, var previous = inputPrevious {
            if let index = previous.api.firstIndex(where: { $0.id == id }) {
                mutate(&previous.api[index])
                inputPrevious = previous
                return
            }
            if var ai = previous.ai, ai.id == id {
                mutate(&ai)
                previous.ai = ai
                inputPrevious = previous
            }
        }
    }

    private func appendScreenshotDelta(_ delta: String) {
        let current: String
        if case .screenshotStreaming(let raw, _, _, _) = state {
            current = raw
        } else {
            current = ""
        }
        let updated = current + delta
        let output = TranslationOutputParser.parse(updated)
        state = .screenshotStreaming(
            raw: updated,
            output: output,
            model: configuration.screenshotModel,
            source: L.pick("Screenshot translation", "截图翻译")
        )
    }

    /// Decide whether a successful translation should land in the local
    /// cache. Skip when any of the following hold — caching long, unique,
    /// or low-value entries just bloats the LRU without ever paying off.
    ///
    /// Hit-rate gates (cheap):
    ///   1. Source spans multiple lines — paragraphs / articles / code
    ///      blocks. Re-selection probability ≈ 0.
    ///   2. Source longer than ~200 chars — even single-line, a sentence
    ///      that long is almost certainly something the user pasted
    ///      once and won't paste again.
    ///   3. Source contains an http/https URL — we don't translate URLs,
    ///      and any "translation" of a URL-containing chunk is best-effort.
    ///
    /// Quality gates:
    ///   4. Provider tagged the input as untranslatable (model self-report
    ///      for AI, source==result heuristic for API).
    ///   5. Output echoed the source unchanged (modulo case + whitespace)
    ///      with no extras — defensive fallback in case the flag was missed.
    ///   6. Result trimmed of whitespace + punctuation is empty — there
    ///      is nothing useful to remember.
    private static func shouldCache(source: String, output: TranslationOutput) -> Bool {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)

        // Hit-rate gates
        if trimmedSource.contains("\n") || trimmedSource.contains("\r") {
            return false
        }
        if trimmedSource.count > 200 {
            return false
        }
        if trimmedSource.range(of: #"https?://"#, options: .regularExpression) != nil {
            return false
        }

        // Quality gates
        if output.untranslatable { return false }
        guard let first = output.items.first else { return false }
        let strippedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if strippedFirst.isEmpty {
            return false
        }
        let normSource = trimmedSource.lowercased()
        let normResult = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normSource == normResult, !output.hasDescription, !output.hasPhonetic {
            return false
        }
        return true
    }

    private static func looksLikeNoTextFallback(_ text: String) -> Bool {
        guard text.count <= 60 else { return false }
        let collapsed = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
        let needles = [
            "没有识别到可翻译",
            "没有可翻译",
            "未识别到",
            "未发现可翻译",
            "(notext)",
            "notranslatabletext",
            "notext"
        ]
        return needles.contains { collapsed.contains($0) }
    }
}

// MARK: - State model

/// Top-level translation state — the single source of truth the tooltip and
/// pinned-note logic observe.
enum TranslationState: Equatable {
    case idle
    /// Manual-entry mode: the tooltip shows a text editor instead of
    /// results. Entered from ⌥D with nothing selected or from settings.
    case input
    /// Text translation in flight or complete. Carries the per-segment
    /// states (API rows + optional AI row). `bothDisabled == true` means
    /// the user has neither AI nor API enabled; the UI renders an empty
    /// state with a "Open settings" prompt.
    case text(TextSegments)
    case screenshotLoading(message: String, model: String, source: String)
    case screenshotStreaming(raw: String, output: TranslationOutput, model: String, source: String)
    case screenshotSuccess(output: TranslationOutput, source: String, model: String)
    case failure(DisplayError)
}

/// Snapshot of all text segments for a single translation. Stored inside
/// `TranslationState.text(...)`.
struct TextSegments: Equatable {
    var source: String
    /// API provider rows, in user-configured order. Always rendered above
    /// the AI row.
    var api: [ProviderSegment]
    /// Optional AI row (gpt-4o, claude, ollama, …).
    var ai: ProviderSegment?
    /// True iff both AI and API switches are off — UI shows an empty-state
    /// "no provider enabled" prompt with a "Open settings" CTA.
    var bothDisabled: Bool
    /// BCP-47 tag of the detected source language; nil when undecidable.
    var sourceLanguage: String? = nil
    /// Display string of the target the providers were asked for. Differs
    /// from the configured target when reverse translation kicked in.
    var targetLanguage: String = ""
    /// True when the source came from the manual-entry editor. The tooltip
    /// then shows the original above the result and lets the user click it
    /// to edit and re-translate. Selection / PopClip / OCR sources leave
    /// this false.
    var sourceEditable: Bool = false
    /// Optional dictionary card shown above the translation rows for eligible
    /// single words / fixed phrases. `nil` means "not a dictionary lookup";
    /// loading/success are independent of the provider segments.
    var dictionary: DictionarySegment? = nil
    /// True while a dictionary-first lookup is in flight and the normal
    /// providers have deliberately not been started yet. On a dictionary
    /// miss the view model starts the providers; on a hit the card stands
    /// alone.
    var dictionaryFirst: Bool = false

    /// "English → 简体中文" for the tooltip header; nil when nothing is known.
    var languagePairLabel: String? {
        guard !targetLanguage.isEmpty else { return nil }
        guard let sourceLanguage else { return targetLanguage }
        return "\(LanguageDetector.displayName(for: sourceLanguage)) → \(targetLanguage)"
    }

    var hasAnyContent: Bool {
        if let dictionary, case .success = dictionary.state { return true }
        if let ai = ai, ai.state.hasContent { return true }
        return api.contains { $0.state.hasContent }
    }

    var hasAnyTerminalSuccess: Bool {
        if let ai = ai, case .success = ai.state { return true }
        return api.contains { if case .success = $0.state { return true } else { return false } }
    }

    var allSegments: [ProviderSegment] {
        if let ai = ai { return api + [ai] }
        return api
    }

    /// Copy with the editable-source affordance stripped. Used when the
    /// previous result is shown underneath the re-edit box, where showing
    /// a second "Original" block would duplicate the editor's content.
    var withoutSourceEditing: TextSegments {
        var copy = self
        copy.sourceEditable = false
        return copy
    }
}

/// Per-provider segment carrying everything the UI needs to render one row.
struct ProviderSegment: Equatable, Identifiable {
    let id: TranslationProviderID
    let displayName: String
    let modelHint: String?
    var state: SegmentState
    /// Failures since this provider last succeeded (this app run). At
    /// `APISegmentsBlock.collapseAfterFailures` the row collapses.
    var consecutiveFailures: Int = 0
}

/// Dictionary lookup state carried alongside the provider segments. A
/// failure removes the segment rather than surfacing an error row: the
/// dictionary is an optional enhancement, not a translation provider.
struct DictionarySegment: Equatable {
    var state: DictionaryState
}

enum DictionaryState: Equatable {
    case loading
    case success(DictionaryEntry)
}

/// Per-segment lifecycle state. AI hits `.streaming(...)` between `.loading`
/// and `.success`; API providers go straight from `.loading` to `.success`
/// or `.failure`.
enum SegmentState: Equatable {
    case loading
    case streaming(raw: String, output: TranslationOutput)
    case success(output: TranslationOutput, latencyMs: Int?, fromCache: Bool, cacheInfo: TranslationCache.CacheInfo?)
    case failure(DisplayError)

    var hasContent: Bool {
        switch self {
        case .streaming(_, let output): return !output.items.isEmpty
        case .success(let output, _, _, _): return !output.items.isEmpty
        case .loading, .failure: return false
        }
    }

    /// `TranslationOutput` derived from this state for read-only display.
    var output: TranslationOutput {
        switch self {
        case .streaming(_, let output): return output
        case .success(let output, _, _, _): return output
        case .loading, .failure: return .empty
        }
    }
}

extension TranslationState {
    /// True only for a finished manual translation whose source can be
    /// reopened in the editor.
    var isSourceEditable: Bool {
        if case .text(let segments) = self { return segments.sourceEditable }
        return false
    }

    var sourceText: String {
        switch self {
        case .text(let segments): return segments.source
        case .screenshotLoading(_, _, let source),
             .screenshotStreaming(_, _, _, let source),
             .screenshotSuccess(_, let source, _):
            return source
        case .idle, .input, .failure: return ""
        }
    }

    /// Convenience accessor for the live-tooltip auto-expand logic and the
    /// pin-as-note snapshot path. Returns the AI segment's output if it
    /// exists, falling back to the first successful API segment.
    var currentOutput: TranslationOutput {
        switch self {
        case .text(let segments):
            if let ai = segments.ai {
                let output = ai.state.output
                if !output.items.isEmpty { return output }
            }
            for segment in segments.api {
                let output = segment.state.output
                if !output.items.isEmpty { return output }
            }
            return .empty
        case .screenshotStreaming(_, let output, _, _),
             .screenshotSuccess(let output, _, _):
            return output
        case .idle, .input, .screenshotLoading, .failure:
            return .empty
        }
    }
}

struct DisplayError: Equatable {
    var title: String
    var message: String?

    init(_ error: Error) {
        let fallback = L.pick("Something went wrong", "出错了")
        if let localizedError = error as? LocalizedError {
            title = localizedError.errorDescription ?? fallback
            message = localizedError.recoverySuggestion
        } else {
            title = fallback
            message = error.localizedDescription
        }
    }
}
