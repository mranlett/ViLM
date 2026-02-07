# ViLM — Video Library Manager

ViLM is a native SwiftUI app for managing and reviewing a local video library.  
It scans a user-selected folder for video files, indexes them into a local SQLite database, and provides a fast, desktop-first UI for browsing, reviewing, tagging, and playing assets.

This project is intentionally split into a **UI app** and a **shared core library** to keep the domain logic clean, testable, and reusable.

---

## Features (implemented)

- 📁 **Library scanning**
  - Recursively scans a selected folder for video files
  - Skips hidden files and packages
  - Ignores internal metadata folders
- 🗂 **Persistent library index**
  - Assets stored in SQLite using **GRDB**
  - Stable UUIDs, relative paths, tags, and review status
- 🎞 **Video playback**
  - Inline player
  - Pop-out player window
  - Centralized playback coordination
- 🧭 **SwiftUI navigation**
  - Sidebar-driven navigation
  - Asset grid view
  - Inspector panel for selected assets
- 🏷 **Asset metadata**
  - Tags
  - Review status (reviewed / unreviewed)
- 🧱 **Clean architecture**
  - UI isolated from storage & scanning logic
  - Core logic lives in a standalone Swift Package

---

## Project structure
```
ViLM/
├─ ViLM.xcodeproj/ # Xcode project
├─ ViLM/ # SwiftUI app target
│ ├─ ViLMApp.swift # App entry point
│ ├─ ContentView.swift
│ ├─ SidebarView.swift
│ ├─ AssetGridView.swift
│ ├─ InspectorView.swift
│ ├─ PlayerView.swift
│ ├─ PlayerPopoutView.swift
│ ├─ PlaybackCoordinator.swift
│ └─ VideoPlaybackController.swift
│
├─ LibraryCore/ # Shared Swift Package
│ ├─ Package.swift
│ └─ Sources/LibraryCore/
│ ├─ Asset.swift
│ ├─ LibraryStore.swift
│ ├─ LibraryScanner.swift
│ ├─ ContactSheetService.swift
│ └─ LibraryCore.swift
│
├─ LICENSE
└─ README.md
```

---

## Architecture overview

### LibraryCore (Swift Package)

`LibraryCore` is the domain layer. It has **no SwiftUI dependency**.

Responsibilities:
- File system scanning (`LibraryScanner`)
- Asset model & persistence (`Asset`, `LibraryStore`)
- SQLite access via **GRDB**
- Deterministic indexing using relative paths

Key design choice:
> The UI never scans the filesystem directly. It asks `LibraryCore` to do it.

---

### ViLM App (SwiftUI)

The app layer handles:
- Navigation & layout (sidebar, grid, inspector)
- Video playback coordination
- Platform-specific UI concerns
- State management for selection and playback

Playback is centralized so:
- Only one asset plays at a time
- Pop-out windows stay in sync
- UI views remain declarative

---

## Platform support

- **macOS** (primary target)
- Architecture is compatible with iOS/iPadOS, but the current UI and file access model are desktop-oriented

---

## Requirements

- macOS
- Xcode (current stable)
- Swift 5.9+
- SQLite (via GRDB)

---

## Build & run

1. Clone the repo
2. Open `ViLM.xcodeproj` in Xcode
3. Select the `ViLM` scheme
4. Build & Run

On first launch:
- Select a folder containing video files
- ViLM will scan and index the library automatically

---

## Design goals

- ⚡ Fast startup after initial scan
- 🧠 Explicit state (no magic observers)
- 🧪 Testable core logic
- 🧱 Clear separation between UI and domain
- 🧭 Desktop-grade UX, not a “phone app on a Mac”

---

## Roadmap (realistic next steps)

- [ ] File change monitoring (incremental rescans)
- [ ] Advanced metadata extraction (duration, codec, resolution)
- [ ] Smart collections / saved filters
- [ ] iOS-specific UI & file access flow
- [ ] Unit tests for `LibraryCore`

---

## License

BSD 3-Clause License. See `LICENSE`.
