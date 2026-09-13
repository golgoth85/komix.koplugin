# Changelog

## [1.0.7] - 2026-09-13

### Added
- **Subscribe / unsubscribe straight from the catalog you are looking at**: the top-left menu
  (next to view mode and rows) now offers *Subscribe to this collection* / *this read list* /
  *this series* — and the matching *Unsubscribe from …* once you are subscribed. No need to go
  through the Subscriptions menu any more.
- **Series can be subscribed to**, like read lists and collections: a series subscription keeps
  every volume of that series downloaded as new ones come out.

## [1.0.6] - 2026-09-13

### Added
- **Local files of comics removed from a subscription are no longer orphaned**: a sync now
  notices the comics that were in a subscribed read list or collection last time, are gone from
  the server now, and are still on the device. It asks once, listing the series and files, with
  **Delete** / **Keep**. Only the files of those comics are removed — a series folder is deleted
  only when it is left empty, and the other volumes are never touched.
- **"Don't ask again (always keep local files)"** checkbox in that dialog: ticking it and
  answering *Keep* turns the check off for good.
- **Subscriptions → "Offer to delete comics removed from subscriptions"** menu option, on by
  default. Turning it off disables the check entirely, so nothing is ever deleted locally by a
  sync. Removing a subscription forgets its comics instead of prompting about them.

### Notes
- The check only covers comics downloaded by a subscription; books downloaded by hand are never
  proposed for deletion. The set of comics each subscription holds is refreshed on every sync
  (also when the check is off), so re-enabling it never proposes deletions for books that
  disappeared long ago.

## [1.0.5] - 2026-09-13

### Fixed
- **A minimized download window no longer pops back up**: hiding the window now keeps it hidden
  for the rest of the queue, so a subscription sync with dozens of books doesn't reopen it on
  every file. It comes back only when asked (**komix → Active downloads**), or on the next
  download started after the queue has drained.
- **Progress line off-centre**: the byte/percentage line was drawn at the offset of the previous
  (shorter) text, so it ended up pushed to the side as the numbers grew. The layout is now
  recomputed on every update, and the line uses the same font as the book name.

## [1.0.4] - 2026-09-13

### Added
- **Downloads run in the background**: the transfer happens in a separate process, so KOReader
  stays usable while downloading (previously the UI froze until it finished).
- **Pause / Resume and Cancel** in the download window. Pause genuinely freezes the transfer
  (the server stops sending); Cancel removes the partial file and stops the whole queue,
  subscriptions included.
- **Hide**: the window closes but the download keeps going. **komix → Active downloads** brings
  it back (disabled when nothing is running).
- **Series name in the download window** (e.g. "Vagabond - 0003.cbz"), useful for bulk downloads
  where the file name alone doesn't say which series it belongs to.

### Changed
- **Search icon moved to the bottom-right corner**: it used to be centred in the bottom bar,
  next to the page arrows.

### Fixed
- **Download window not redrawn**: on close (download finished or cancelled) the window stayed
  on screen because the refresh was requested without a refresh mode.

## [1.0.3] - 2026-09-13

### Fixed
- **Spurious "no download folder" warning**: while browsing books (to tell which ones are
  already downloaded) the plugin showed an error when no download folder was configured. The
  path check is now silent; the warning only appears when a download is actually attempted.
  Bulk and subscription downloads no longer show the warning repeatedly.

### Notes
- First release verified **on real KOReader** (Linux x86_64 build, headless): browsing, covers,
  counts, series names and the download folder were tested on screen.

## [1.0.2] - 2026-09-13

### Fixed
- **Wrong search icon**: the name `search` doesn't exist in KOReader, so the fallback icon
  (a triangle with "!") was shown. It now uses `appbar.search`.
- **Overlapping buttons**: the options menu goes back to the top-left (the slot the Menu
  reserves, as in native OPDS) and search moves to the bottom-right bar. The options button no
  longer ends up over the ✕ close button.

### Added
- **Progress bar while downloading**: a dialog with a progress bar (bytes downloaded when the
  server reports the file size, otherwise just status and file name). For bulk downloads the
  subtitle also shows "(i of N)".
- **Download-complete notification**: a pop-up per downloaded file ("Downloaded: …"), with a
  final summary for bulk downloads.

## [1.0.1] - 2026-09-13

### Fixed
- **Title bar**: the options button no longer overlaps search. Search stays on the left
  (the standard position), options move to the right.
- **Coverless lists** (home, libraries, collections): compact density like KOReader's standard
  Menu, so they fit on a single page; the server-side page size now matches the on-screen one
  (they could get out of sync before).
- **Read lists and collections**: the count no longer shows `(0)` — when the server doesn't
  expose `bookCount`/`seriesCount`, the length of `bookIds`/`seriesIds` is used instead.
- **Read lists**: each book also shows its series name.
- Fixed shadowing of the translation function `_` inside `for _,` loops (it could error when
  opening the options with subscriptions present).

### Added
- **Options → Home screen**: show/hide each home-screen entry (e.g. On Deck, Recently Added
  Books).

## [1.0.0] - 2026-09-13

First release: a merge of `kokomga` (v2.1.0) and `komga` (v2026.08.31.1).

### Added
- Series search, from the home screen and the title bar (from `komga`).
- Navigation of **collections**, **read lists** (with cover) and **one-shots**.
- **Subscriptions** to read lists / collections: automatic download of new comics, triggered
  manually or automatically when back online.
- Metadata: description fallback from the series; author selection
  (artist / writer / both / none).
- Downloads: filename template, stall and total timeouts, retry with backoff (from `komga`).
- Download folder picker (PathChooser).

### Inherited from kokomga
- List and grid views with covers and badges, multi-select and bulk download.
- Reading-progress sync via KOSync, multi-layer book recognition.
- Atomic downloads, offline queue, background pre-download, automatic RTL.
- Cover cache, i18n, dispatcher actions (now `komix_*`).
