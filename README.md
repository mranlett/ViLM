# ViLM — Video Library Manager

ViLM is a native SwiftUI app for **iOS and macOS** that manages and reviews a local video library. It scans a user-selected folder for video files, indexes them into a local SQLite database, and provides a fast UI for browsing, reviewing, tagging, and playing assets — including a full actor/studio/tag metadata graph.

The project is split into a **UI app** and a **shared core library** (`LibraryCore`) to keep domain logic clean, testable, and platform-independent.

---

## Features

- 📁 **Library scanning** — recursively indexes `mp4`/`mov`/`m4v` files; skips hidden files, packages, and the internal `.catalog` metadata folder; rescans preserve existing metadata
- 🗂 **Persistent library index** — SQLite via **GRDB**; stable UUIDs, relative paths, migration-managed schema
- 🏠 **Dashboard** — library stats, 30-day growth chart, recently added videos/actors, unreviewed queue, actors needing attention
- 🎞 **Video playback** — inline `AVPlayer`, pop-out player window (macOS), seek-to-frame from a 4×4 contact sheet
- 🏷 **Metadata graph** — actors (with AKAs/aliases), studios, tags, series; entity profiles with photos, galleries, bios, and per-actor filmography
- 🔎 **Filtering & search** — real-time search, filter builders for assets and actors, saved **Smart Collections** in the sidebar
- ✅ **Review workflow** — reviewed/unreviewed status, star ratings, notes, review progress tracking
- 🛠 **Maintenance tools** — force rescan, missing-file detection, file-name audit with batch rename, tag cleanup/merge, CSV export/import
- 📦 **Batch editing** — multi-select videos or actors and apply shared metadata
- 🕸 **A real graph, not just strings** — six edge tables connect videos to performers, studios and tags, performers to their traits, and studios to their parent networks. Edges carry provenance (where each came from) and the studio hierarchy carries validity dates, so a video resolves to the network that owned its imprint *when it was released*
- 📚 **Playlists** — hand-picked, drag-to-reorder lists, distinct from the filter-driven Smart Collections
- ⏱ **Scene markers** — named points inside a video
- 🔌 **Optional metadata plugins** — look videos, actors and studios up against a third-party service to fill in details automatically, with a review-before-apply sheet. Entirely optional; with no plugin installed the app makes no network requests at all. Credentials live in the system Keychain
- 🔗 **Attach a second library** — browse two libraries as one without merging them on disk; each record keeps living in the library that owns it
- ↔️ **Move the graph between libraries** — export actors, studios, tags and their connections to a file and merge it into another copy. The merge is additive: it fills gaps, never overrules the receiving library, and reports genuine disagreements instead of silently picking a side
- 🔍 **Self-auditing** — checks that find *wrong* data rather than merely absent data: a video released before a credited performer was born, a studio owning itself, a video filed under two studios
- 💾 **Backup & restore** — the catalog, not the video files, so a backup is small and merges on restore
- 🔒 **A privacy boundary you declare, not one that guesses** — every video is declared as a scene, film, episodic or personal. Personal content reaches no external service, and neither does anything still undeclared: unknown fails closed. Performers inherit the same rule from the videos they appear in, so a name only leaves the device when a video that person is in has been declared commercial
- 🏷 **Naming and filing, per content class** — a generated on-disk layout with a grammar per kind (Kodi/Plex conventions for films and series, a ViLM grammar for scenes). A dry run shows every move and every collision before anything happens; the run itself renames in place, records each move before making it so an interruption leaves nothing half-moved, and can put the whole thing back exactly
- 🏆 **Head to Head** — rank performers or videos by repeated pairwise choice rather than by scoring each one cold. Standings show how much evidence sits behind each place, and say so when there is not enough yet
- 🕵️ **Explore the graph** — questions no single record can answer: which tags always travel together and whether that means a merge or a hierarchy, where in a career each studio tends to work, and performers who share several studios but have never shared a video

---

## Project structure

```
ViLM/
├─ ViLM.xcodeproj/              # Xcode project
├─ ViLM/                        # SwiftUI app target
│  ├─ ViLMApp.swift             # App entry point
│  ├─ ContentView.swift         # Navigation root (compact stack / split view) + SidebarItem
│  ├─ AppRoute.swift            # Typed navigation routes
│  ├─ SidebarView.swift         # Sidebar: sections, smart collections, filters
│  ├─ DashboardView.swift       # Home dashboard
│  ├─ AssetGridView.swift       # Asset grid + AssetFilterCriteria
│  ├─ ActorGridView.swift       # Actor gallery
│  ├─ TagGalleryView.swift      # Tag gallery
│  ├─ InspectorView.swift       # Video details (player, metadata, tags)
│  ├─ ActorInspectorView.swift  # Batch actor editing entry point
│  ├─ EntityProfileEditorView.swift      # Actor/entity profile editor
│  ├─ BatchEntityProfileEditorView.swift # Batch profile editor
│  ├─ ProfileGraphHeaderView.swift       # Entity profile header (photos, related tags)
│  ├─ FilterBuilderView.swift / ActorFilterBuilderView.swift
│  ├─ SettingsView.swift / LibraryStatsView.swift / FileNameAuditView.swift / TagCleanupView.swift
│  ├─ PlayerView.swift / PlayerPopoutView.swift / PlaybackCoordinator.swift
│  │  VideoPlaybackController.swift / PlayerWindowController.swift
│  └─ AppComponents.swift       # Shared components (TagBubble, FlowLayout, thumbnails, env keys)
│
├─ LibraryCore/                 # Shared Swift Package (no SwiftUI dependency)
│  ├─ Package.swift
│  ├─ Sources/LibraryCore/
│  │  ├─ Asset.swift            # Asset model + GRDB persistence + display helpers
│  │  ├─ EntityProfile.swift    # Actor/studio/tag profile model
│  │  ├─ SmartCollection.swift  # Saved filter model
│  │  ├─ LibraryStore.swift     # SQLite access, migrations, global tag rename
│  │  ├─ LibraryScanner.swift   # Filesystem scanning
│  │  ├─ ContactSheetService.swift # Thumbnail & contact sheet generation
│  │  ├─ ContentNaming.swift     # The four filing grammars, pure
│  │  ├─ PathComponentName.swift # Path sanitising (ExFAT/Windows safe)
│  │  ├─ RelocationPlan.swift    # The dry run: every move, before any move
│  │  ├─ RelocationMover.swift   # The rename itself — interruptible, reversible
│  │  ├─ RelocationJournal.swift # Write-ahead record that makes both possible
│  │  ├─ ContentKind.swift       # What a video IS, and the provider boundary
│  │  ├─ PerformerExposure.swift # The same boundary, for names
│  │  ├─ ActorCredits.swift      # One crediting rule, shared by every consumer
│  │  ├─ FileRenamerService.swift
│  │  ├─ TagNormalizer.swift / TagSuggester.swift
│  │  └─ LibraryCore.swift
│  └─ Tests/LibraryCoreTests/   # Unit tests (store, scanner, tag utilities)
│
├─ LICENSE
└─ README.md
```

---

## Navigation architecture

Navigation adapts to the horizontal size class of the **window** and is driven by shared state, so rotating a device preserves context.

- **Compact width** (iPhone, narrow iPad windows): a single `NavigationStack` with a typed `[AppRoute]` path. The sidebar is the root "home" screen; `AppRoute.browse` pushes the content hub (dashboard / asset grid / actor gallery / tag gallery, chosen by the sidebar selection); deeper routes (`.asset`, `.entityProfile`, …) push detail pages.
- **Regular width** (iPad full screen, landscape large phones, macOS): a three-pane `NavigationSplitView` — sidebar, content grid, and a detail pane with its own `NavigationStack` for drill-downs (e.g. tapping a tag on a video pushes that tag's page in the detail pane).

Rules that keep this working — please preserve them when contributing:

1. **`navigationDestination(for: AppRoute.self)` is registered exactly once per stack**, attached to the stack's root view. Duplicate or misplaced registrations silently break links.
2. **Views never infer the navigation mode from `horizontalSizeClass`.** Split-view columns report their own (compact) size class even in regular-width windows. Use the `\.usesStackNavigation` environment value (defined in `AppComponents.swift`, set by `ContentView`): `true` → taps push `NavigationLink`s; `false` → taps select into the detail pane.
3. **`EntityProfileEditorView` only wraps itself in a `NavigationStack` when presented as a sheet** (`embedsInNavigationStack`). Nesting stacks inside a pushed view breaks links and toolbars on iOS.
4. `sidebarSelection: Set<SidebarItem>` doubles as the active filter set (selected actors/tags/studios). Top-level sections navigate immediately; entity items toggle as filters.

---

## LibraryCore (Swift Package)

`LibraryCore` is the domain layer with **no SwiftUI dependency**:

- File system scanning (`LibraryScanner`) — insert-only registration, so rescans never clobber user metadata
- Persistence (`LibraryStore`) — GRDB migrations, asset/profile/smart-collection CRUD, global tag rename with profile merging
- Note: `LibraryStore.saveAsset` is **insert-only** (`INSERT OR IGNORE`); use `updateAsset` to modify existing rows
- Thumbnail/contact-sheet generation (`ContactSheetService`) into the library's `.catalog` folder
- Tag normalization and filename-based tag suggestion

The UI never scans the filesystem or touches SQLite directly — it asks `LibraryCore`.

---

## Testing

```bash
cd LibraryCore
swift test
```

Roughly 2,000 tests. Covers `LibraryStore` (CRUD, entity profiles, AKA resolution, global rename/merge, smart collections, reopen persistence), `LibraryScanner` (formats, recursion, hidden/`.catalog` exclusion, idempotent rescans), the tag utilities, the graph edges and their migrations, the cross-library merge, and the audit rules.

⚠️ The **app target has no test target.** Anything asserted about the UI is asserted in `LibraryCore` by keeping the decision out of the view — which is why policies like `StudioBatchPolicy` and `VideoEnrichmentReview` are pure types in the package rather than logic inside a `View`.

---

## Platform support

- **iOS / iPadOS 17+** — size-class-adaptive navigation, `UIDocumentPickerViewController` folder access with security-scoped bookmarks
- **macOS 14+** — three-pane desktop layout, pop-out player window, `NSOpenPanel` folder access

---

## Build & run

1. Clone the repo
2. Open `ViLM.xcodeproj` in Xcode
3. Select the `ViLM` scheme and a destination (iPhone, iPad, or My Mac)
4. Build & Run

On first launch, select a folder containing video files; ViLM scans and indexes it automatically and remembers it via a security-scoped bookmark.

---

## Roadmap

⚠️ Specs and the backlog are **not in this repository** — they live in Notion, and
work items are GitHub issues. A local file would be invisible to every other
machine.

Still open:

- [ ] Picture-in-Picture playback while browsing
- [ ] File change monitoring (incremental rescans)
- [ ] Advanced metadata extraction (duration, codec, resolution)
- [ ] Resume playback & watch history
- [ ] A tag hierarchy (broad tags containing narrow ones), the shape studios already have — the evidence for it is now measured rather than assumed: a handful of narrow tags sit almost entirely inside two broad ones
- [ ] Persisting confirmed duplicate verdicts so the same question is not asked twice
- [ ] Metadata sidecars, so a file that leaves the library still means something

Shipped since this list was first written: manual playlists with drag-and-drop
ordering, scene markers, the metadata graph, plugin-based matching, attaching a
second library, backup/restore, the content-kind privacy boundary, per-class
file naming with a reversible bulk rename, Head to Head ranking, and the graph
exploration screens.

---

## License

BSD 3-Clause License. See `LICENSE`.
