# Roadmap

This file records dictionary plans that were explicitly deferred, plus the v1
scope for context. Deferred does not mean abandoned; nothing here is a release
commitment.

[简体中文](./ROADMAP.zh-CN.md)

## Dictionary lookup — v1 scope

- English → Simplified Chinese, single words and fixed phrases (1–4 words).
- UK/US pronunciation: play Youdao's audio when available; use system
  `en-GB` / `en-US` voices for the macOS dictionary fallback.
- Primary source: Youdao web dictionary JSON (signed `jsonapi_s` web endpoint,
  keyless; the signature and its failure modes are documented in code).
- Offline fallback: macOS system dictionary "Oxford Chinese-English", single
  words only. When it is missing, the settings page offers a **Manually
  Download** sheet with steps and a **Test** button.
- Default: a dictionary hit replaces the API/AI rows for that lookup; a
  setting can show the dictionary and translation results together.
- Dedicated "Dictionary" settings subpage: enable toggle, source status, Apple
  dictionary download guidance, max word count.
- Dictionary failures degrade silently and never block translation.

## Deferred

### Bundled offline dictionaries

- Candidates: FreeDict eng-zho (~26.6k headwords, ~2 MB) or an ECDICT subset
  (MIT; ~760k entries; full CSV ~63 MB).
- Open questions: license and data provenance; a frequency-trimmed compact
  index; bundle vs first-use download; installer size.

### Traditional Chinese target

- Youdao and Apple dictionary data are mostly Simplified Chinese today.
- Options: Foundation `StringTransform` or MediaWiki `variant=zh-hans/zh-hant`
  conversion, or a traditional-specific dictionary source. Verify entry quality.

### More language pairs

- v1 is English → Simplified Chinese only.
- Later: Youdao `ce` (Chinese → English), other Apple dictionary pairs,
  Wiktionary, etc. Abstract `DictionarySource` first so the app is not tied to
  one provider.

---

_Last updated: 2026-11-10_
