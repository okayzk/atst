import AVFoundation
import Combine
import Foundation

/// Pronunciation player for the dictionary card.
///
/// Youdao entries carry UK/US MP3 URLs, which sound natural and match the
/// displayed IPA. The macOS dictionary fallback has no audio URL, so it
/// speaks the headword with a system voice matching the accent
/// (`en-GB` / `en-US`). Playback is best-effort: a network/audio failure is
/// silent and never affects the dictionary card.
@MainActor
final class DictionarySpeaker: ObservableObject {
    private var player: AVPlayer?
    private let speech = TooltipSpeaker()

    func play(_ phonetic: DictionaryEntry.Phonetic?, text: String) {
        player?.pause()
        player = nil

        if let phonetic,
           let raw = phonetic.audioURL,
           let url = URL(string: raw) {
            speech.stop()
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
            return
        }

        let language: String?
        switch phonetic?.accent {
        case "UK":
            language = "en-GB"
        case "US":
            language = "en-US"
        default:
            language = nil
        }
        speech.speak(text, language: language)
    }

    func stop() {
        player?.pause()
        player = nil
        speech.stop()
    }
}
