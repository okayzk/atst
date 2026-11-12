# Changelog

[简体中文](./CHANGELOG.zh-CN.md)

All notable changes are recorded here. Each version section is what gets pasted into the matching GitHub release notes.

## v0.8.0

- **Settings, redesigned** — the panel now uses a single glass surface like the translation tooltip: no inner cards, larger 13 pt group titles, one-step-larger body text, and a slightly wider 380 pt panel
- **Keep settings on top** — a pin in the settings header keeps the window above other apps and stops outside-click dismissal until you unpin
- **Translation services in one place** — default services, provider order and **Show AI result first** now share one section; ordering is gone from the API page
- **Fewer pages and switches** — translation prompts moved into AI → Advanced (the third-level page is gone), and the AI / API / Dictionary pages no longer repeat their enable switch or long explanatory paragraphs
- **Smaller fixes** — hotkeys read as one line with the shortcut on the right, pinned notes keep their top-left corner instead of jumping when created, and copy is trimmed to short labels and state

## v0.7.0

- **Apple system translation** — on macOS 26+, Apple's on-device Translation engine joins the API providers; it runs locally with no key, joins the existing multi-source rows, and points you to System Settings when the language pack isn't downloaded
- AI results now use the same 14 pt body as the API rows; AI and screenshot-AI text render inline Markdown (bold / italic / code) instead of showing the markers, so the distinction is real formatting rather than a larger font
- The tooltip header's refresh / pin / settings / close icons use the same 11 pt medium rounded secondary style as the language label, making them readable on the glass surface
- Release apps now bundle LICENSE and NOTICE, and the README credits the upstream project

## v0.6.0

- **Dictionary card, re-typeset** — a 21 pt headword with the source name on the same line, section headers carried by a hairline rule, 14 pt meanings on a hanging indent, and related words folded behind **Show all**. The nested card surface, the "Dictionary · Youdao" row and the CET tag line are gone, so the entry sits directly on the tooltip material
- **Result rows read as sections** — each provider gets a name + hairline header, the body grows to 14 pt (API) / 15 pt (AI), providers sit 16 pt apart, and the copy icon only appears while the pointer is over that provider
- **Show AI result first** — a new toggle under AI Translation → Status puts the AI block above the Google / Microsoft / DeepL rows
- Dictionary lookups use a 400 pt column instead of 320 pt so the larger type wraps less; the "looking up dictionary…" row no longer paints its own background; the header status dot is removed

## v0.5.0

- **PopClip extension** — select text, click **atst** in the PopClip bar, and the tooltip translates it in place; the app now registers an `atst://translate?text=…` URL scheme so external launchers can hand text to the existing translation pipeline (source in `PopClip-plugin/`)
- **Manual input keeps the original** — after Return the source stays visible above the result; click it to reopen the editor (with the previous result still shown underneath) and translate again
- **DeepL** — a third built-in API provider using DeepL's anonymous iOS oneshot endpoint (no key required); results join Google / Microsoft, long selections are split around the 1500-character anonymous limit, and the advertised client version is refreshed from the App Store
- **Choose default services** — General → Default translation services selects which enabled services run on each new translation (multiple allowed); unchecked ones stay available in the per-result switch menu
- **API fallback** — an opt-in toggle in API Translation adds every other enabled API provider to the same translation when one fails or is unreachable; the failed provider keeps its error row instead of disappearing
- **Dictionary lookup** — single English words and fixed phrases (up to 4 words) get a dictionary card with UK/US IPA and pronunciation playback, part-of-speech-grouped senses, bilingual examples, phrases and related words. Youdao's keyless web dictionary is the primary source; macOS's built-in 牛津英汉汉英词典 is the offline fallback. A new Dictionary settings page shows source status, a Test button, a manual-download guide and a **Skip translation when a definition exists** switch (on by default); with it on a dictionary hit replaces the API/AI rows for that lookup, with it off all results render together.
- **Per-result switch and collapse** — every result header can swap that row to another enabled service (unused ones only) or hide it temporarily; collapsing is visual only, and editing the original expands everything again. The live tooltip now keeps API rows separate so each row owns its controls (pinned notes still merge identical results)
- Result headers now share one layout across API and AI (same label, icon sizes and spacing); the switch menu gained a divider and **All others**, which keeps the current row and adds every other enabled provider
- **Pinned notes are live sessions** — pinning now detaches the translation into an independent session that uses the same result view, so service switching, collapsing and original-text editing keep working; the note header gained an unpin action that returns it to the normal tooltip (× still closes it)
- **Microsoft translation works again** — the Edge JWT auth endpoint was retired (now 404); migrated to the unauthenticated `edge.microsoft.com/translate/translatetext` endpoint
- **Service reachability** — API provider names in settings carry a dot checked automatically when the page opens; the AI page has a Test button with a dot next to its label
- The switch menu shows the concrete AI model name instead of "AI"; every result icon now renders at the same 10 pt size and tint, with the outline-heavy pin / copy glyphs bumped so their strokes match xmark and chevron; pin/unpin swaps windows without a fade flash

## v0.4.0

- **Line breaks survive translation** — the AI prompt now demands the source's line / paragraph structure, Microsoft translates line by line like Google, and screenshot OCR merges soft-wrapped lines inside a paragraph so line-by-line translators see whole sentences
- **Reverse translation** — when the selection is already in your target language it's translated into a new **Secondary language** setting instead (Chinese ⇄ English by default)
- **Type to translate** — `⌥D` with nothing selected opens a text box in the tooltip; Return translates, Shift+Return inserts a newline
- **Launch at login** toggle in General settings
- **First-launch Accessibility prompt** — without the grant the hotkeys could never fire, and a fresh install sat there silently; the app now asks once per version and opens settings
- Tooltip header shows the detected source language and the target (`English → 简体中文`) instead of the app name
- Google and Microsoft rows merge into one when they return the same text
- A provider that fails three times in a row collapses to a single line with a **Disable** button instead of a full error every time
- `Esc` dismisses the tooltip (it never could — the panel wasn't a key window)
- Selection is read through the Accessibility API first (instant, no clipboard round-trip); the ⌘C fallback gives up after 0.6 s instead of 1.2 s, so the input box appears faster when nothing is selected
- Google / Microsoft errors are labelled with the provider's name instead of "AI"
- Pronunciation picks a voice matching the detected language instead of the system locale
- AI few-shot examples follow the target language (English targets no longer see Chinese examples)
- Connection prewarming happens when you press a hotkey's modifier key, replacing a permanent 4-minute timer
- Settings: permission rows drop the redundant refresh button; Timeout moves to the AI page (it never applied to Google / Microsoft); Reset restores everything except the AI endpoint, key and models; every toggle uses the same compact size
- README: corrected the Accessibility install step, added Troubleshooting, Apple Silicon requirement, fuller Privacy notes, environment-variable overrides; roadmap trimmed of shipped items

## v0.3.1

- Tooltip header is easier to grab — the drag region now bleeds edge-to-edge of the floating panel without changing the header's visible size, so you don't need pixel-perfect aim on the 22pt strip
- Cache size in Stats no longer wraps to two lines — the unit (KB / MB) renders in a smaller font next to the number, and the formatter switches to 1024-based progression (1 KB at 1024 bytes, not 1000) to match developer-tool conventions

## v0.3.0

- **Translation activity sparkline** — stats section gains a 14-day mini chart showing daily translation volume. Solid line counts every translation (cache hits included); dashed line counts only fresh translations (cache misses). Hover any day for a popover with that day's exact numbers
- **Minimum macOS version raised to 14 (Sonoma)** — unlocks the native `chartXSelection` API for the sparkline's mouse-following tooltip. macOS 13 (Ventura) is no longer supported
- DMG size reduced ~60% (from ~5.3 MB to ~2.0 MB) thanks to pngquant-compressed app icon during build. Visually identical at icon render sizes
- Fixed pasteboard restoration when selection translation is re-triggered mid-capture — your original clipboard contents are no longer lost on rapid-fire ⌥D presses
- Trimmed the "Hotkeys blocked by another app" warning to one sentence (was a full paragraph)

## v0.2.2

- New "Notes on all desktops" toggle in General settings — when on, pinned notes follow you across Spaces / desktop switches instead of staying on the desktop they were pinned on. Default off; flipping it updates already-pinned notes live without needing to re-pin
- Settings copy polished throughout — tightened bilingual subtitles, dropped mixed-language phrases, renamed "TTL (days)" to "Days to keep" for clarity, fixed the Chinese "Reset" button label
- Fixed vertical alignment of items in the OCR recognition-language chip row — the "+ Add" pill and language chips are now centered on the same baseline rather than top-aligned

## v0.2.1

- Settings panel adopts Liquid Glass on macOS 26+ (Swift 6.2+ builds), matching the tooltip / pinned-note treatment from v0.2.0; older systems fall back to the existing menu material automatically
- All four right-side controls in the General page (target language, timeout, interface language, appearance) now align to a single right edge — segmented pickers no longer drift based on label width
- Settings header gains a version label (`atst v0.2.1`) that links to the matching release page, plus an auto-update pill that surfaces when a newer GitHub release is available
- Google translation now preserves newlines and blank lines in multi-line selections, keeping list / paragraph structure intact
- API providers can be reordered with ▲/▼ buttons in the API subpage; the tooltip and result panel honour the new order
- "翻译方式" section in General now lists API Translation above AI Translation, matching the tooltip layout
- Diagnostic for the macOS Secure Keyboard Entry trap: if another app (e.g. 1Password) is holding secure input, an orange warning now surfaces in Settings so the hotkey-not-working case is identifiable in seconds rather than mistaken for a permission bug
- Comprehensive internal cleanup pass — removed dead code, unused fields / parameters, vestigial methods, and orphaned UI files; no behaviour change

## v0.2.0

- Translation tooltips and pinned notes now use native Liquid Glass on macOS 26+ when built with Swift 6.2+, while older systems automatically keep the existing AppKit tooltip material fallback

## v0.1.3

- General settings layout unified: every control in the section now aligns to a single right-edge guideline; target-language picker is upsized so its value reads as clearly as the row label
- Tooltip width now adapts to the source — short selections stay compact (320pt), long sentences or multi-line input expand to 480pt for comfortable reading
- Tooltip can no longer overflow the screen: a built-in ScrollView caps content at the available height, and the scroll bar disappears automatically when you drag the panel to a position with more room
- Cache is more selective: multi-line text, sentences over 200 chars, inputs containing URLs, and empty / punctuation-only results are all skipped — the cache fills with high-reuse words and phrases instead of single-use chunks
- App icon source is now full-bleed: the icon's source PNG controls the full visual (background + artwork) rather than being centred inside a system-drawn white squircle, eliminating the previous "tiny artwork inside a big white frame" problem

## v0.1.2

- Target language dropdown now uses a native AppKit popup button (cleaner chevron)
- Bilingual `CHANGELOG.md` / `CHANGELOG.zh-CN.md` introduced
- `Scripts/release.sh` ties together build + git tag + GitHub release in one command

## v0.1.1

- Interface language picker added (Auto / English / 中文); Auto follows the system locale
- Target language is a dropdown over a curated preset list
- Default request timeout 60s → 10s
- README clarifies the `atst` acronym (`a` AI · `t` text · `s` select · `t` translate)
- Highlight tiny footprint (~2 MB DMG, ~4 MB installed)
- Liquid Glass tooltip recorded as a roadmap entry (auto-enables on macOS 26 + Xcode 26 / Swift 6.2)

## v0.1.0

- Initial public release.
