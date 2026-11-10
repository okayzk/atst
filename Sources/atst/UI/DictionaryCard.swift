import SwiftUI

/// Dictionary card shown above the API / AI rows for eligible words and
/// fixed phrases. Youdao supplies structured senses and examples; the macOS
/// system dictionary fallback supplies one readable text block.
///
/// Typography is deliberately editorial: one large headword, a 14pt body,
/// section headers with a hairline rule, and no nested card surface — the
/// card sits directly on the tooltip material. Everything that is not the
/// entry itself (CET labels, source chrome) is gone; the source name rides
/// on the headword line instead of taking a row of its own.
struct DictionaryCard: View {
    let entry: DictionaryEntry

    @State private var expanded = false
    @StateObject private var speaker = DictionarySpeaker()

    private let collapsedSenseGroups = 2
    private let collapsedMeaningsPerGroup = 3
    private let collapsedExamples = 1
    private let collapsedPhrases = 1
    private let collapsedRawCharacters = 500

    /// One left inset for everything under a section header, so meanings,
    /// examples, phrases and related words share a single ragged-free edge.
    private let contentIndent: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            if !entry.senses.isEmpty {
                sensesSection
            }
            if !entry.examples.isEmpty {
                examplesSection
            }
            if !entry.phrases.isEmpty {
                phrasesSection
            }
            if expanded, !entry.related.isEmpty {
                relatedSection
            }
            if let rawText = entry.rawText, !rawText.isEmpty {
                rawTextSection(rawText)
            }
            if needsExpansion {
                expandButton
            }
        }
        .onDisappear { speaker.stop() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.headword)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(sourceLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                if entry.phonetics.isEmpty {
                    pronunciationButton(nil)
                } else {
                    ForEach(Array(entry.phonetics.enumerated()), id: \.offset) { _, phonetic in
                        pronunciationButton(phonetic)
                    }
                }
            }
        }
    }

    private var sourceLabel: String {
        switch entry.source {
        case .youdao:
            return "Youdao"
        case .apple:
            return L.pick("macOS Dictionary", "系统词典")
        }
    }

    private func pronunciationButton(_ phonetic: DictionaryEntry.Phonetic?) -> some View {
        Button {
            speaker.play(phonetic, text: entry.headword)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                if let phonetic {
                    Text("\(phonetic.accent) /\(phonetic.text)/")
                        .font(.system(size: 12))
                } else {
                    Text(L.pick("Play", "朗读"))
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(phonetic.map {
            L.pick("Play \($0.accent) pronunciation", "播放\($0.accent)发音")
        } ?? L.pick("Play pronunciation", "播放发音"))
    }

    // MARK: - Sections

    private var sensesSection: some View {
        let groups = expanded ? entry.senses : Array(entry.senses.prefix(collapsedSenseGroups))
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, sense in
                VStack(alignment: .leading, spacing: 6) {
                    if !sense.partOfSpeech.isEmpty {
                        Text(sense.partOfSpeech)
                            .font(.system(size: 12))
                            .italic()
                            .foregroundStyle(.tertiary)
                    }
                    let meanings = expanded
                        ? sense.meanings
                        : Array(sense.meanings.prefix(collapsedMeaningsPerGroup))
                    ForEach(Array(meanings.enumerated()), id: \.offset) { _, meaning in
                        meaningRow(meaning)
                    }
                }
            }
        }
    }

    /// Dot in the gutter, text on a hanging indent: wrapped lines stay under
    /// the first line instead of folding back beneath the bullet.
    private func meaningRow(_ meaning: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 3, height: 3)
                .padding(.top, 7)
            Text(meaning)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
    }

    private var examplesSection: some View {
        let examples = expanded ? entry.examples : Array(entry.examples.prefix(collapsedExamples))
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L.pick("Examples", "例句"))
            ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                VStack(alignment: .leading, spacing: 2) {
                    Text(example.source)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !example.translation.isEmpty {
                        Text(example.translation)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, contentIndent)
            }
        }
    }

    private var phrasesSection: some View {
        let phrases = expanded ? entry.phrases : Array(entry.phrases.prefix(collapsedPhrases))
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle(L.pick("Phrases", "词组"))
            ForEach(Array(phrases.enumerated()), id: \.offset) { _, phrase in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(phrase.headword)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(phrase.translation)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, contentIndent)
            }
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(L.pick("Related", "相关词"))
            ForEach(Array(entry.related.enumerated()), id: \.offset) { _, group in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !group.partOfSpeech.isEmpty {
                        Text(group.partOfSpeech)
                            .font(.system(size: 12))
                            .italic()
                            .foregroundStyle(.tertiary)
                    }
                    Text(group.words.joined(separator: ", "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, contentIndent)
            }
        }
    }

    private func rawTextSection(_ rawText: String) -> some View {
        let visible = expanded
            ? rawText
            : String(rawText.prefix(collapsedRawCharacters))
            + (rawText.count > collapsedRawCharacters ? "…" : "")
        return Text(visible)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Section header with the same hairline rule the result rows use, so
    /// the whole tooltip shares one structural language.
    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.18), Color.primary.opacity(0.02)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
        }
    }

    /// "Show all" sits at the end of the entry as plain text rather than as
    /// a chevron in the header: one discoverable affordance, no chrome row.
    private var expandButton: some View {
        Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expanded.toggle()
            }
        } label: {
            Text(expanded ? L.pick("Show less", "收起") : L.pick("Show all", "展开全部"))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .padding(.leading, contentIndent)
    }

    // MARK: - Expansion

    private var needsExpansion: Bool {
        if !entry.related.isEmpty { return true }
        if entry.senses.count > collapsedSenseGroups { return true }
        if entry.senses.contains(where: { $0.meanings.count > collapsedMeaningsPerGroup }) {
            return true
        }
        if entry.examples.count > collapsedExamples { return true }
        if entry.phrases.count > collapsedPhrases { return true }
        if let rawText = entry.rawText, rawText.count > collapsedRawCharacters { return true }
        return false
    }
}
