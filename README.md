# komix — a Komga client for KOReader

> **Honest note first.** `komix` is a **merge of two existing plugins** — `kokomga` and `komga` —
> with a few features added on top. It is **100% vibe coded**: written entirely by an AI assistant
> (**DeepSeek Flash 4.1**, driven through the Claude Code CLI), directed and tested by a human. It
> works, and it is tested (see [Status](#status)), but it has only been run on one Komga server so
> far. Read the code before trusting it with a library you care about.

A client for [Komga](https://komga.org) (a comics/manga media server) that runs inside
[KOReader](https://koreader.rocks): browse the server library, download books locally, and keep
reading progress in sync.

It is aimed at **e-ink readers** — developed and tested against a **Kindle Scribe (10.2", 2024)**
and a **Kobo Libra 2**.

## Where it comes from

| Source | License | What komix took from it |
|---|---|---|
| **kokomga** by Jim Davis | MIT | list/grid views with covers, the progress-sync engine, metadata writing, cover cache |
| **komga** by Jonathan Willian | AGPL-3.0-or-later | series search, download options (filename template, retries, timeouts), collections |

Features that did **not** exist in either plugin were added here: read lists, one-shots, category
subscriptions, and metadata rules (series-description fallback, author role filter).

Because it contains code derived from an AGPL-3.0-or-later work, **the combined plugin is
AGPL-3.0-or-later** — see [License](#license).

## Features

**Browsing**
- **List and grid** views with covers, status badges (new / in progress / finished), a
  "downloaded" badge, and multi-select for bulk downloads.
- Home screen: Search, Keep Reading, On Deck, Recently Added Series, Recently Added Books,
  All Series, **Collections**, **Read Lists**, **One-shots**, Libraries, Sync subscriptions.
  Every entry can be shown/hidden from **Options → Home screen**.

**Search** — by series, from the home entry or from the magnifier button in the bottom bar
(reachable from any screen).

**Collections, read lists, one-shots** — collections (collection → series → books), read lists
(read list → books, with cover), one-shots (series made of a single book).

**Reading-progress sync** — hooks into KOReader's KOSync and talks to Komga directly for recognised
books. Multi-layer book matching (cache → sidecar → metadata), atomic `.part` → rename downloads,
offline queue, background pre-download of upcoming chapters, automatic RTL.

**Downloads**
- Progress bar (bytes, when the server reports the file size) and a completion notification;
  bulk downloads show "(i of N)".
- Filename template (`{series}`, `{title}`, `{number}`), per-series subfolders, configurable stall
  and total timeouts, retry with backoff.

**Metadata** — title, description, series index and authors written into KOReader sidecars.
If a chapter has no description, the **series** description is used instead (optional). Authors to
save are selectable: **artist only** (default), writer only, both, or none.

**Category subscriptions** — subscribe to one or more read lists / collections; new books added on
Komga are downloaded automatically. Runs **manually** (home entry, menu, or quick action) and
**automatically** when the network comes back.

## Install

**Manual:** copy the `komix.koplugin` folder into `koreader/plugins/` (or unzip
`komix.koplugin.zip` there) and restart KOReader.

**From a community store:** komix is meant to be installed through KOReader's community stores
(e.g. **appstore.koplugin**, **KoStore**). Those do **not** use a central registry — they discover
plugins by searching GitHub for the topic **`koreader-plugin`** or for a repo named
`<name>.koplugin`. This repo has both, so it should be discoverable.

Then configure it in **Menu → komix → Server Setup** (server URL and API key; the key can be
generated from a username and password) and pick a download folder in **Menu → komix → Options**.

> If you already have `kokomga` and/or `komga` installed you can remove them: `komix` includes
> their features. Its internal modules live under a `komix/` namespace specifically so they don't
> clash with other plugins installed alongside.

## Requirements

- A reachable **Komga** server (developed against the v1/v2 API).
- **KOSync configured in KOReader** for progress sync — the plugin hooks into its events, so
  progress sync does nothing without it.
- Everything else (browsing, searching, downloading) works with just the server URL and API key.

## Status

Honest picture:

- **Verified on real KOReader** (Linux x86_64 build, headless, driven with a mock Komga server that
  serves covers and a fake catalogue): browsing, covers, search, download with progress bar,
  metadata, counts, badges, and the subscription logic. The test suite is 100+ assertions and is
  run with KOReader's own LuaJIT.
- **Downloaded files were checked** for integrity, and the metadata sidecars were inspected
  (series-description fallback and the "artist only" author filter both behave as intended).
- **Not yet tested on physical devices.** Gestures, RTL, suspend/resume and large downloads on a
  real Kindle/Kobo are untested. Treat those as unverified.
- Things that are known to be rough: collection covers don't exist in the Komga API, so collections
  are shown as a plain list; the code has been read by exactly one human being.

## Development

The plugin is self-contained Lua; the pure-logic modules (`komix/core/naming.lua`,
`komix/core/metadata.lua`, `komix/core/retry.lua`) have no KOReader dependency and are unit-tested.

If you want to hack on it: the plugin's own repo has no test harness, but the development tree it
was built in runs the full suite (syntax check + unit tests + a live test against a mock Komga
server) with KOReader's LuaJIT. Pull requests and bug reports are welcome — especially from anyone
who can test it on hardware.

## License

**AGPL-3.0-or-later.** `komix` is a combined work: the parts derived from the `komga` plugin are
AGPL-3.0-or-later (original author: Jonathan Willian), the parts derived from `kokomga` are MIT
(original author: Jim Davis). See [LICENSE](LICENSE) and the SPDX headers in the affected files.

If you redistribute or run this on a network service, the AGPL's obligations apply.
