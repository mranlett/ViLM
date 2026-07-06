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

```

---

## User Interface Guide

ViLM utilizes a classic macOS `NavigationSplitView` architecture consisting of three primary resizable panes: the Sidebar (Navigation), the Content View (Grids/Lists), and the Detail Pane (Inspector).

### Pane 1: Sidebar (Navigation)
The Sidebar is the primary routing mechanism for the application, providing access to top-level collections and settings.

**Buttons & Functions:**
- **Dashboard**: Routes Pane 2 to the high-level Library Dashboard.
- **All Assets**: Routes Pane 2 to the primary Asset Grid, displaying all indexed video files.
- **Actor Gallery**: Routes Pane 2 to the Actor Grid, displaying all known actors.
- **Tag Gallery**: Routes Pane 2 to a comprehensive list of all metadata tags.
- **Smart Collections**: Dynamically generated links (e.g., "Unreviewed", "Favorites") that act as quick-filters for the Asset Grid.
- **Settings (Gear Icon)**: Opens the global settings modal sheet.
- **Library Selector (Top Dropdown)**: Allows switching between multiple indexed local folders seamlessly.

---

### Pane 2: Content Views
The Content View dynamically changes based on the Sidebar selection, presenting the primary data list or grid.

#### 1. Dashboard (`DashboardView`)
A high-level overview of library health and recent additions.
- **Statistics Bar**: Displays total video count, total known actors, and total unique tags.
- **Library Path**: Shows the physical absolute path of the currently active library.
- **New / Unreviewed Videos**: A horizontal carousel of recently added or unreviewed assets. Clicking a thumbnail opens the video in Pane 3.
- **New Actors**: A horizontal carousel of recently created actor profiles. Clicking opens the actor profile in Pane 3.
- **Top Tags / Top Studios**: Lists the most frequently applied metadata tags and studios across the library.

#### 2. Assets Grid (`AssetsGridView`)
The primary interface for browsing video files.
- **Search Bar (Top)**: Real-time filtering by video title, actor name, studio, or tags.
- **Filter Menu**: Filters the grid by Review Status (All, Reviewed, Unreviewed).
- **Sort Menu**: Reorders the grid by Title, Date Added, File Size, Duration, or User Rating (Ascending or Descending).
- **Video Thumbnails**: Displays the extracted poster frame, title, and duration overlay. Clicking a thumbnail selects it and loads its deep metadata into Pane 3.
- **Edit Mode (Multi-Select)**: Allows the user to Shift/Cmd-click multiple videos simultaneously for bulk editing and deletion.

#### 3. Actor Gallery (`ActorGridView`)
The primary interface for browsing the cast database.
- **Search Bar (Top)**: Real-time filtering by actor name or their known AKAs (Aliases).
- **Sort Menu**: Reorders the grid alphabetically or by total associated video count.
- **Actor Cards**: Displays the actor's profile avatar, primary name, and a badge showing how many videos they appear in. Clicking a card loads their profile into Pane 3.
- **Batch Edit Mode**: Allows selecting multiple actors to apply shared metadata.

---

### Pane 3: Detail Pane (Inspector)
The Detail Pane is where deep interaction, playback, and metadata editing occurs for the currently selected item.

#### 1. Video Details (`InspectorView`)
Loaded when a video is selected from the Dashboard or Assets Grid.
- **Full Screen Toggle (Arrows Icon)**: Expands Pane 3 to fill the entire window, temporarily hiding the Sidebar and Content View for distraction-free viewing.
- **Inline Video Player**: An `AVPlayer` instance that plays the selected video directly within the pane.
- **Pop-out Player**: Detaches the video player into a floating, resizable macOS window (Picture-in-Picture style).
- **Edit / Done Button**: Toggles the metadata form between read-only and edit modes.
  - **Title Field**: Editable text field for the video title.
  - **Star Rating**: A 1-to-5 star picker for user rating.
  - **Studio Field**: Auto-completing text field linking the video to a production studio.
  - **Actors List**: Tokenized list of actors in the video. Clicking an actor acts as a deep link, instantly pushing their Actor Profile onto the Pane 3 stack.
  - **Tags List**: Tokenized list of categorical tags. Clicking a tag deep-links to the Tag Gallery.
  - **Description**: Multiline text editor for synopsis or notes.
  - **URL**: External reference link.
- **Scrubber / Contact Sheet (`FrameExtractView`)**: A 4x4 matrix of thumbnail frames extracted evenly across the video's total duration.
  - **Seek-to-Frame Click**: Clicking any of the 16 thumbnails instantly seeks the video player to that exact timestamp.

#### 2. Actor Profile (`ActorInspectorView`)
Loaded when an actor is selected from the Actor Gallery, or deep-linked from a Video Details page.
- **Profile Image**: Displays the actor's avatar. Clicking the image allows the user to browse their disk for a new photo or paste an image from the clipboard.
- **Primary Name**: Editable text field for the actor's canonical name.
- **AKAs (Also Known As)**: A list of alternative aliases used to automatically map legacy filenames to this canonical profile.
- **Biography**: Multiline text editor for actor notes.
- **Filmography Grid**: A responsive grid of video thumbnails featuring this actor. Clicking any video acts as a deep link, pushing the Video Details page onto the Pane 3 stack.

---

### Global Settings Sheet (`SettingsView`)
Accessed via the gear icon in the Sidebar.
- **Library Path Management**: Add, remove, or change the root physical folder the app scans.
- **Force Rescan**: Manually triggers a deep SQLite index refresh against the physical filesystem.
- **Audit File Names**: A maintenance tool that scans physical file names against database records to flag inconsistencies or missing files.
- **Tag Cleanup**: A bulk management tool used to merge duplicate tags or delete unused categorical tags globally.

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
