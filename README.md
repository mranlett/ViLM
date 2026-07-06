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

Covers `LibraryStore` (CRUD, entity profiles, AKA resolution, global rename/merge, smart collections, reopen persistence), `LibraryScanner` (formats, recursion, hidden/`.catalog` exclusion, idempotent rescans), and the tag utilities.

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

See `BACKLOG.md` (repo root) for the prioritized backlog. Highlights:

- [ ] Picture-in-Picture playback while browsing
- [ ] Manual playlists with drag-and-drop ordering
- [ ] File change monitoring (incremental rescans)
- [ ] Advanced metadata extraction (duration, codec, resolution)
- [ ] Resume playback & watch history

---

## License

BSD 3-Clause License. See `LICENSE`.
