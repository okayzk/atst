import Combine
import Foundation

/// Probes translation endpoints for the settings page.
///
/// API providers are checked automatically when the API page appears, with
/// a short cache so navigating between settings pages doesn't spam the
/// services. AI is deliberately manual: the AI page has a Test button,
/// because a probe consumes tokens and depends on the user's draft fields.
///
/// Limitation: a green dot only means the host answered a tiny "ping"
/// request. It does not guarantee that every translation will succeed —
/// rate limits, payload size, auth/profile changes and endpoint changes can
/// still fail later. The runtime rows are the source of truth.
@MainActor
final class ProviderHealthMonitor: ObservableObject {
    static let shared = ProviderHealthMonitor()

    @Published private(set) var statuses: [TranslationProviderID: ProviderHealth] = [:]

    private var lastChecked: [TranslationProviderID: Date] = [:]
    private let cacheLifetime: TimeInterval = 60
    private let probeText = "ping"

    func status(for id: TranslationProviderID) -> ProviderHealth {
        statuses[id] ?? .unknown
    }

    /// Check Google / Microsoft / DeepL. Intentionally checks all built-in
    /// API services, including ones the user has not enabled, so the dot
    /// tells them whether enabling a provider would actually work.
    func checkAPIProviders(force: Bool = false) {
        for id in [TranslationProviderID.google, .microsoft, .deepl] {
            guard force || shouldCheck(id) else { continue }
            lastChecked[id] = Date()
            statuses[id] = .checking

            Task { [weak self] in
                let health = await Self.probeAPIProvider(id)
                self?.statuses[id] = health
                AppLogger.log("provider health \(id.rawValue)=\(String(describing: health))")
            }
        }
    }

    /// User-initiated AI test. Uses the settings draft, not the saved
    /// config, so the user can verify fields before saving.
    func checkAI(configuration: AppConfiguration) async -> ProviderHealth {
        let model = configuration.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return .unreachable(L.pick("Model not configured", "尚未配置模型"))
        }
        let provider = OpenAIProvider(configuration: configuration)
        let health = await Self.probe(provider)
        AppLogger.log("provider health ai=\(String(describing: health))")
        return health
    }

    private func shouldCheck(_ id: TranslationProviderID) -> Bool {
        guard let last = lastChecked[id] else { return true }
        return Date().timeIntervalSince(last) >= cacheLifetime
    }

    private static func probeAPIProvider(_ id: TranslationProviderID) async -> ProviderHealth {
        let provider: TranslationProvider
        switch id {
        case .google:
            provider = GoogleProvider(targetLanguage: "English")
        case .microsoft:
            provider = MicrosoftProvider(targetLanguage: "English")
        case .deepl:
            provider = DeepLProvider(targetLanguage: "English")
        case .system:
            return .unknown
        case .ai:
            return .unknown
        }
        return await probe(provider)
    }

    private static func probe(_ provider: TranslationProvider) async -> ProviderHealth {
        do {
            var sawFinal = false
            for try await emission in provider.translate(text: "ping") {
                if emission.isFinal {
                    sawFinal = true
                    break
                }
            }
            return sawFinal ? .reachable : .unreachable(L.pick("No response", "无响应"))
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
