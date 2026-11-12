import Foundation

/// Stable identifier for a translation provider. Doubles as a cache key
/// segment and a settings-persistence key.
enum TranslationProviderID: String, Codable, CaseIterable, Hashable {
    /// OpenAI-compatible Chat Completions endpoint (user-configured).
    case ai
    /// Built-in Google Translate adapter (unofficial public endpoint).
    case google
    /// Built-in Microsoft Translator adapter (unofficial edge endpoint).
    case microsoft
    /// Built-in DeepL adapter (unofficial iOS oneshot endpoint).
    case deepl
    /// macOS on-device translation (Apple Translation framework, 26+).
    case system
}

/// Whether the provider is "AI" (rich, configurable, model-bound) or "API"
/// (flat string, built-in, free). Drives top-level segment grouping in the
/// tooltip and settings.
enum TranslationSegmentKind: String, Codable, Equatable {
    case ai
    case api
}

extension TranslationProviderID {
    var segmentKind: TranslationSegmentKind {
        switch self {
        case .ai: return .ai
        case .google, .microsoft, .deepl, .system: return .api
        }
    }

    /// Service name for settings and the per-result switch menu. Result
    /// headers keep using the provider's own `displayName` — the AI row
    /// shows its model there instead of the generic "AI".
    var displayName: String {
        switch self {
        case .ai: return "AI"
        case .google: return "Google"
        case .microsoft: return "Microsoft"
        case .deepl: return "DeepL"
        case .system: return "Apple"
        }
    }

    /// False for services that need a newer macOS than this build is
    /// running on. Keep them out of settings lists and switch menus
    /// instead of offering a provider that can never run.
    var isRuntimeAvailable: Bool {
        switch self {
        case .system: return SystemTranslationProvider.isSupported
        case .ai, .google, .microsoft, .deepl: return true
        }
    }
}

/// Single emission of a `TranslationProvider.translate(...)` stream.
///
/// - `output` is a snapshot of what's known so far. For non-streaming
///   providers there is exactly one emission with `isFinal == true`. For
///   streaming (AI) providers each delta carries the cumulative parsed
///   output; only the last emission has `isFinal == true`.
/// - `raw` carries the underlying text accumulated so far (mostly useful for
///   AI parsing). Empty for non-streaming providers.
struct TranslationProviderEmission: Equatable {
    var output: TranslationOutput
    var raw: String
    var isFinal: Bool
}

/// Common protocol implemented by `OpenAIProvider`, `GoogleProvider`,
/// `MicrosoftProvider`, `DeepLProvider` and `SystemTranslationProvider`.
/// Everything that translates text in atst goes through this so the
/// ViewModel and cache layer don't have to special-case per backend.
protocol TranslationProvider: Sendable {
    /// Stable identifier — drives cache keys and UI badges.
    var id: TranslationProviderID { get }
    /// Human-readable name shown in the tooltip header (e.g. "Google",
    /// "gpt-4o", "Microsoft").
    var displayName: String { get }
    /// Optional model identifier (only AI sets this — APIs leave it nil).
    var modelHint: String? { get }

    /// Translate `text`. Implementations should:
    ///   - emit at least one final emission on success;
    ///   - propagate errors via stream termination (`throw`);
    ///   - respect Task cancellation.
    /// The target language is bound at provider construction time —
    /// each impl normalises it internally (BCP-47 for HTTP APIs, freeform
    /// prompt text for AI).
    func translate(text: String) -> AsyncThrowingStream<TranslationProviderEmission, Error>
}
