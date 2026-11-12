import Foundation
import Translation

/// macOS on-device translation via Apple's Translation framework.
///
/// Available on macOS 26+ only: before that the framework's
/// `TranslationSession` can only be obtained from SwiftUI's
/// `.translationTask`, which would couple a provider to a view's
/// lifecycle. `TranslationSession(installedSource:target:)` (macOS 26)
/// lets a provider translate without any UI plumbing.
///
/// Everything runs on-device. Language packs are managed by the system;
/// when a pair isn't downloaded yet we fail with a message that points at
/// System Settings instead of silently degrading. The framework supports a
/// fixed set of ~20 languages, so unsupported pairs are reported the same
/// way.
struct SystemTranslationProvider: TranslationProvider {
    let id: TranslationProviderID = .system
    let displayName: String = "Apple"
    let modelHint: String? = nil
    let targetLanguage: String

    /// Whether this build can offer the provider on the current OS. Used
    /// to keep it out of Settings and the switch menu on older macOS
    /// versions.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    func translate(text: String) -> AsyncThrowingStream<TranslationProviderEmission, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard #available(macOS 26.0, *) else {
                        throw AppError.systemTranslationUnavailable(
                            L.pick(
                                "Apple system translation requires macOS 26 or later.",
                                "Apple 系统翻译需要 macOS 26 或更高版本。"
                            )
                        )
                    }
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

    @available(macOS 26.0, *)
    private func performTranslate(text: String) async throws -> TranslationProviderEmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.emptyTranslation }

        guard let targetCode = LanguageCode.bcp47(from: targetLanguage) else {
            throw AppError.systemTranslationUnavailable(
                L.pick(
                    "Unsupported target language: \(targetLanguage)",
                    "不支持的目标语言：\(targetLanguage)"
                )
            )
        }
        let target = Locale.Language(identifier: targetCode)

        // Reuse the app's detector so the provider's source language agrees
        // with the header label and the reverse-translation decision.
        guard let detection = LanguageDetector.detect(trimmed) else {
            throw AppError.systemTranslationUnavailable(
                L.pick(
                    "Couldn't identify the source language.",
                    "无法识别原文语言。"
                )
            )
        }
        let source = Locale.Language(identifier: detection.code)

        let sourceName = LanguageDetector.displayName(for: source.maximalIdentifier)
        let targetName = LanguageDetector.displayName(for: target.maximalIdentifier)

        if source.maximalIdentifier == target.maximalIdentifier {
            throw AppError.systemTranslationUnavailable(
                L.pick(
                    "The text is already in \(targetName).",
                    "原文已经是\(targetName)。"
                )
            )
        }

        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported:
            throw AppError.systemTranslationUnavailable(
                L.pick(
                    "The \(sourceName) → \(targetName) language pack isn't downloaded. Open System Settings › General › Language & Region › Translation Languages, download it, then translate again.",
                    "「\(sourceName) → \(targetName)」语言包尚未下载。请到 系统设置 › 通用 › 语言与地区 › 翻译语言 中下载，然后重新翻译。"
                )
            )
        case .unsupported:
            throw AppError.systemTranslationUnavailable(
                L.pick(
                    "Apple translation doesn't support \(sourceName) → \(targetName).",
                    "Apple 系统翻译不支持「\(sourceName) → \(targetName)」。"
                )
            )
        @unknown default:
            throw AppError.systemTranslationUnavailable(
                L.pick("Translation isn't available for this language pair.", "该语言对暂时无法翻译。")
            )
        }

        let session = TranslationSession(installedSource: source, target: target)
        let batch = LineBatch(text: text)
        let requests = batch.payload.map { TranslationSession.Request(sourceText: $0) }

        let responses: [TranslationSession.Response]
        do {
            responses = try await session.translations(from: requests)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranslationError {
            if error ~= TranslationError.notInstalled {
                throw AppError.systemTranslationUnavailable(
                    L.pick(
                        "The \(sourceName) → \(targetName) language pack isn't downloaded. Open System Settings › General › Language & Region › Translation Languages, download it, then translate again.",
                        "「\(sourceName) → \(targetName)」语言包尚未下载。请到 系统设置 › 通用 › 语言与地区 › 翻译语言 中下载，然后重新翻译。"
                    )
                )
            }
            throw AppError.systemTranslationUnavailable(error.localizedDescription)
        } catch {
            throw AppError.systemTranslationUnavailable(error.localizedDescription)
        }

        let translatedLines = responses.map(\.targetText)
        guard let decoded = batch.merge(translatedLines), !decoded.isEmpty else {
            throw AppError.providerRequestFailed(
                name: displayName,
                detail: L.pick(
                    "Apple returned an unexpected number of lines.",
                    "Apple 返回的行数与输入不一致。"
                )
            )
        }

        let output = TranslationOutput(
            result: decoded,
            items: [decoded],
            phonetic: nil,
            description: nil,
            untranslatable: looksUntranslatable(source: trimmed, result: decoded)
        )
        return TranslationProviderEmission(output: output, raw: decoded, isFinal: true)
    }

    /// Same heuristic the HTTP providers use: a case/whitespace-identical
    /// echo means the system had nothing to translate, so skip the cache
    /// and mark the row as untranslatable.
    private func looksUntranslatable(source: String, result: String) -> Bool {
        let normSource = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normResult = result
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normSource.isEmpty && normSource == normResult
    }
}
