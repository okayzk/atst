import SwiftUI

/// Dictionary card shown above the API / AI rows for eligible words and
/// fixed phrases. Youdao supplies structured senses and examples; the macOS
/// system dictionary fallback supplies one readable text block.
struct DictionaryCard: View {
    let entry: DictionaryEntry

    @State private var expanded = false
    @StateObject private var speaker = DictionarySpeaker()

    private let collapsedSenseGroups = 2
    private let collapsedMeaningsPerGroup = 3
    private let collapsedExamples = 2
    private let collapsedPhrases = 3
    private let collapsedRelated = 2
    private let collapsedRawCharacters = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            headwordRow
            if !entry.tags.isEmpty {
                Text(entry.tags.joined(separator: " · "))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            if !entry.senses.isEmpty {
                sensesSection
            }
            if !entry.examples.isEmpty {
                examplesSection
            }
            if !entry.phrases.isEmpty {
                phrasesSection
            }
            if !entry.related.isEmpty {
                relatedSection
            }
            if let rawText = entry.rawText, !rawText.isEmpty {
                rawTextSection(rawText)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .onDisappear { speaker.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 5) {
            Text(L.pick("Dictionary", "词典"))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            Text(sourceLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.quaternary)
            Spacer(minLength: 4)
            if needsExpansion {
                ResultIconButton(
                    systemName: expanded ? "chevron.up" : "chevron.down",
                    help: expanded
                        ? L.pick("Show less", "收起")
                        : L.pick("Show more", "展开")
                ) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        expanded.toggle()
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

    private var headwordRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.headword)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
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

    private func pronunciationButton(_ phonetic: DictionaryEntry.Phonetic?) -> some View {
        Button {
            speaker.play(phonetic, text: entry.headword)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                if let phonetic {
                    Text("\(phonetic.accent) /\(phonetic.text)/")
                        .font(.system(size: 11))
                } else {
                    Text(L.pick("Play", "朗读"))
                        .font(.system(size: 11))
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
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, sense in
                VStack(alignment: .leading, spacing: 2) {
                    if !sense.partOfSpeech.isEmpty {
                        Text(sense.partOfSpeech)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    let meanings = expanded
                        ? sense.meanings
                        : Array(sense.meanings.prefix(collapsedMeaningsPerGroup))
                    ForEach(Array(meanings.enumerated()), id: \.offset) { _, meaning in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("•")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.tertiary)
                            Text(meaning)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var examplesSection: some View {
        let examples = expanded ? entry.examples : Array(entry.examples.prefix(collapsedExamples))
        return VStack(alignment: .leading, spacing: 5) {
            sectionTitle(L.pick("Examples", "例句"))
            ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                VStack(alignment: .leading, spacing: 1) {
                    Text(example.source)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !example.translation.isEmpty {
                        Text(example.translation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var phrasesSection: some View {
        let phrases = expanded ? entry.phrases : Array(entry.phrases.prefix(collapsedPhrases))
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle(L.pick("Phrases", "词组"))
            ForEach(Array(phrases.enumerated()), id: \.offset) { _, phrase in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(phrase.headword)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(phrase.translation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var relatedSection: some View {
        let related = expanded ? entry.related : Array(entry.related.prefix(collapsedRelated))
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle(L.pick("Related", "相关词"))
            ForEach(Array(related.enumerated()), id: \.offset) { _, group in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if !group.partOfSpeech.isEmpty {
                        Text(group.partOfSpeech)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(group.words.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func rawTextSection(_ rawText: String) -> some View {
        let visible = expanded
            ? rawText
            : String(rawText.prefix(collapsedRawCharacters))
            + (rawText.count > collapsedRawCharacters ? "…" : "")
        return Text(visible)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Expansion

    private var needsExpansion: Bool {
        if entry.senses.count > collapsedSenseGroups { return true }
        if entry.senses.contains(where: { $0.meanings.count > collapsedMeaningsPerGroup }) {
            return true
        }
        if entry.examples.count > collapsedExamples { return true }
        if entry.phrases.count > collapsedPhrases { return true }
        if entry.related.count > collapsedRelated { return true }
        if let rawText = entry.rawText, rawText.count > collapsedRawCharacters { return true }
        return false
    }
}
