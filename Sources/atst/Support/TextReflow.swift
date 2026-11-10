import Foundation

/// Rejoins visual line wraps inside a paragraph before translation.
///
/// Selected text copied from PDFs, web pages and most text views often
/// carries one newline per *rendered* line rather than per paragraph. The
/// translation pipeline treats every line as a separate unit (API
/// providers translate line by line; the AI prompt preserves line breaks),
/// so a single wrapped sentence arrives at the providers as fragments.
/// This helper folds those soft wraps back into sentences while keeping
/// structure that is meaningful:
///
///   - blank lines (real paragraph breaks)
///   - list items, headings, quotes and fenced code
///   - indented lines (code / quoted blocks)
///   - lines that end a sentence or a code block
///
/// Manual input is never passed through here — the user typed those line
/// breaks on purpose.
enum TextReflow {
    /// Returns `text` with soft-wrapped lines joined. Idempotent: running
    /// it on its own output changes nothing.
    static func joiningSoftWraps(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }

        var output: [String] = []
        var paragraph: String?
        var previousLine = ""
        var paragraphIsBlock = false

        func flushParagraph() {
            if let paragraph {
                output.append(paragraph)
            }
            paragraph = nil
        }

        for rawLine in lines {
            let line = strippingTrailingWhitespace(rawLine)

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                // A blank line is a real paragraph break. Collapse runs of
                // blank lines into one — repeated blank lines carry no
                // extra meaning for translation.
                if let last = output.last, !last.isEmpty {
                    output.append("")
                }
                continue
            }

            if let existing = paragraph {
                let startsBlock = isBlockLine(line)
                if paragraphIsBlock || startsBlock || endsBlock(previousLine) || !canJoin(previousLine, line) {
                    output.append(existing)
                    paragraph = line
                    paragraphIsBlock = startsBlock
                } else {
                    paragraph = joining(existing, with: line)
                }
            } else {
                paragraph = line
                paragraphIsBlock = isBlockLine(line)
            }
            previousLine = line
        }
        flushParagraph()

        return output.joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    // MARK: - Join rules

    /// Join `paragraph` (already containing one or more physical lines)
    /// with the next one, undoing PDF hyphenation such as
    /// "trans-\nlation" at the same time.
    private static func joining(_ paragraph: String, with line: String) -> String {
        if paragraph.hasSuffix("-"),
           let last = paragraph.dropLast().unicodeScalars.last,
           let first = line.unicodeScalars.first,
           !isCJK(last), !isCJK(first),
           CharacterSet.lowercaseLetters.contains(first) {
            return String(paragraph.dropLast()) + line
        }
        return paragraph + joiner(between: paragraph, and: line) + line
    }

    /// A line that starts a new structural unit and must not be merged
    /// into the previous one: Markdown headings / quotes / fences, list
    /// markers, or an indented (code / quoted) line.
    static func isBlockLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if first == " " || first == "\t" { return true }
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("```") { return true }
        let marker = #"^(?:[•·*–—-]|\d+[.、)]|\([0-9]+\))\s"#
        return line.range(of: marker, options: .regularExpression) != nil
    }

    /// True when `line` clearly finishes its sentence or code block, so
    /// the next line is a new unit rather than a visual wrap.
    private static func endsBlock(_ line: String) -> Bool {
        var body = Substring(line)
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "）", "]"]
        while let last = body.last, closers.contains(last) {
            body = body.dropLast()
        }
        guard let last = body.last else { return true }
        return ".!?。！？…；;：:{}".contains(last)
    }

    /// A very short line is more likely a list entry or a code statement
    /// than the first visual line of a wrapped sentence. Only join short
    /// lines when they clearly continue (trailing comma / hyphen) or the
    /// next line starts in lowercase.
    private static func canJoin(_ previous: String, _ next: String) -> Bool {
        if weightedLength(previous) >= 15 { return true }
        // CJK lines wrap between almost any two characters, and each
        // character counts double above. A handful of CJK glyphs is still
        // a plausible wrapped prose line (unlike a short Latin word).
        if let last = previous.unicodeScalars.last,
           let first = next.unicodeScalars.first,
           isCJK(last), isCJK(first),
           weightedLength(previous) >= 8 {
            return true
        }
        if previous.hasSuffix(",") || previous.hasSuffix("，") || previous.hasSuffix("、") || previous.hasSuffix("-") {
            return true
        }
        if let first = next.first, first.isLowercase { return true }
        return false
    }

    // MARK: - Shared helpers (also used by VisionOCRService)

    /// CJK text has no inter-word spaces, so wrapped CJK lines join
    /// directly; everything else gets a single space.
    static func joiner(between prev: String, and next: String) -> String {
        guard let last = prev.unicodeScalars.last, let first = next.unicodeScalars.first else { return " " }
        return isCJK(last) || isCJK(first) ? "" : " "
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x3000...0x303F,   // CJK punctuation
             0xFF00...0xFFEF:   // Fullwidth forms
            return true
        default:
            return false
        }
    }

    // MARK: - Private helpers

    private static func strippingTrailingWhitespace(_ line: String) -> String {
        var result = line
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    /// CJK characters visually occupy roughly two Latin characters, so a
    /// short CJK line can still be a full-width wrapped prose line.
    private static func weightedLength(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isCJK($1) ? 2 : 1) }
    }
}
