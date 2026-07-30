// HelpContent.swift
// All in-app help copy, one HelpTopic per screen. Add a topic here when a
// screen gains controls worth explaining; screens deep-link to their topic
// via HelpView(initialTopicID:).

import Foundation

/// A single help topic, matching one screen or feature area of the app.
/// Written in plain language for end users — no code/architecture terms.
struct HelpTopic: Identifiable {
    struct Item: Identifiable {
        var id: String { label }
        let label: String
        let description: String
    }

    let id: String
    let title: String
    /// One or two sentences describing what this screen is for.
    let summary: String
    /// Each notable button/control on the screen, in the order a user
    /// encounters them, with a plain-language description of what it does.
    let items: [Item]
}

/// All help content for the app. Add a new `HelpTopic` here whenever a
/// screen gains a control worth explaining; screens can jump straight to
/// their topic via `HelpView(initialTopicID:)`, and everything is also
/// browsable from the table of contents.
enum HelpContent {
    static let topics: [HelpTopic] = [
        dashboard,
        allAssets,
        actorGallery,
        tagGallery,
        seriesGallery,
        videoDetails,
        actorProfile,
        openLibraries,
        settings,
    ]

    static let openLibraries = HelpTopic(
        id: "openLibraries",
        title: "Open Libraries (Attach a Second Library)",
        summary: "Attach one or more additional libraries — say, a portable drive — and browse everything as if it were a single library. Nothing is merged on disk: every video and actor keeps living in its own library, edits and deletes always land in the library that owns the record, and attachments close automatically when you quit the app.",
        items: [
            .init(label: "Attach Library…",
                  description: "In the sidebar's Open Libraries section: pick another ViLM library folder to open alongside your main one. Its videos and actors immediately appear everywhere — All Assets, Actors, Series, Tags, the Dashboard, search, and filters."),
            .init(label: "Library names",
                  description: "Libraries are always shown by PATH, not just folder name — two libraries can both be called “Videos”, so the volume or route (~/Downloads/Videos vs PortableSSD/Downloads/Videos) is what tells them apart. Compact badges use the shortest unique part."),
            .init(label: "Precedence (attach order)",
                  description: "The main library comes first, then attachments in the order you attached them — the sidebar list IS the order. When the same actor exists in several libraries, the earlier library's value wins any conflict in the combined view; nothing is changed on disk."),
            .init(label: "Actors in several libraries",
                  description: "Actor pages show a combined view (bio, rating, tags, AKAs, and photos from every open library together). Editing writes only to the library that owns the actor — the editor says which one — so no data ever silently copies between libraries. Use the Actor Merge tools if you actually want to merge."),
            .init(label: "Detach (eject button)",
                  description: "Closes that library: its videos and actors leave the view, and its files and catalog are untouched. Quitting the app detaches everything automatically — attachments are never remembered across launches."),
            .init(label: "Identical entries shown once",
                  description: "If an attached library was created from a backup of an open one, some videos exist in both with the same internal identity. Those are shown once (the earlier library's copy); a notice tells you how many were hidden."),
            .init(label: "Find Duplicates across libraries",
                  description: "The duplicate finder scans every open library together, so copies living in different libraries are found — exact copies, re-encodes, and trimmed versions alike. Each copy's row shows which library it lives in before you delete."),
            .init(label: "Tools that need one library",
                  description: "Back Up, Move Videos, File Name Audit, Migrate Episode Info, Tag & Actor Cleanup, Series Standardize, and the Actor Merge tools work on a single library — detach first to use them. Check for Changes works while attached and refreshes every open library."),
        ]
    )

    static let dashboard = HelpTopic(
        id: "dashboard",
        title: "Dashboard",
        summary: "Your library's home base — quick stats, what's new, and shortcuts to videos and actors that need attention.",
        items: [
            .init(label: "Stat cards",
                  description: "Your total video count, total known actors, and total unique tags at a glance."),
            .init(label: "Library Growth chart",
                  description: "How many videos you've added over the last 30 days, so you can see your library growing over time."),
            .init(label: "Recently Added",
                  description: "Your newest videos. Tap one to open it, or tap See All to view every video sorted by date added."),
            .init(label: "Unreviewed",
                  description: "Videos you haven't marked as reviewed yet. Tap a thumbnail to open the video, or tap Mark Reviewed right on the card to check it off without opening it. Tap See All to view every unreviewed video."),
            .init(label: "Recently Added Actors",
                  description: "Your newest actor profiles. Tap one to open their profile, or tap See All to view every actor sorted by date added."),
            .init(label: "Actors Needing Attention",
                  description: "Actors missing a profile photo. Tap one to open their profile and fill it in. Tap See All for the fuller list, which also includes actors missing a bio or tags."),
        ]
    )

    static let allAssets = HelpTopic(
        id: "allAssets",
        title: "All Assets",
        summary: "The main way to browse your video library — search, filter, sort, and open videos.",
        items: [
            .init(label: "Search bar",
                  description: "Searches filenames, series names, episode titles, notes, actor names (including aliases and bios), tags, and studios. You can type multiple words — each word can match a different field, so \"jane beach\" finds a video where \"jane\" is an actor and \"beach\" is in the title."),
            .init(label: "Videos / Actors toggle",
                  description: "Appears whenever the grid is narrowed down — by a search, a filter, or viewing a tag/actor/studio/series from elsewhere in the app — and switches between the matching videos and the actors who appear in them, so you can jump straight to an actor's profile instead of scrolling through their videos one by one."),
            .init(label: "Filter button",
                  description: "Opens detailed filters — review status, minimum rating, and specific actors, tags, studios, or actor details like hair color, gender, and country — to narrow the grid down. You can save your current filters as the default, or save them as a named Smart Collection in the sidebar."),
            .init(label: "Sort menu",
                  description: "Choose Series Order (season, then episode, then date), Name, Date Added, or File Size, and flip between ascending and descending."),
            .init(label: "View Options",
                  description: "Switch each thumbnail between a single poster frame and a contact-sheet grid of frames, and choose how many videos appear per row (Auto, 1, 2, or 3)."),
            .init(label: "Save Collection",
                  description: "Appears once a filter is active — saves the current filter (and whatever actor/tag/studio you're viewing) as a Smart Collection you can jump back to from the sidebar."),
            .init(label: "Select (iPhone)",
                  description: "Turns on multi-select so you can tap several videos, then Edit Selected to change tags, reviewed status, or series/season for all of them at once."),
            .init(label: "Filter chips",
                  description: "When you're viewing more than one actor, tag, studio, or series at once, each appears as a removable chip at the top of the grid."),
            .init(label: "Pull to refresh (iPhone/iPad)",
                  description: "Pull down on the grid to re-scan the library folder for added or removed video files — the same check Settings → Check for Changes runs."),
        ]
    )

    static let actorGallery = HelpTopic(
        id: "actorGallery",
        title: "Actor Gallery",
        summary: "Browse, search, and manage your cast of actors.",
        items: [
            .init(label: "Search bar",
                  description: "Searches actor names and their aliases (AKAs)."),
            .init(label: "A–Z picker",
                  description: "Jump straight to actors whose name starts with a given letter."),
            .init(label: "Sort menu",
                  description: "Sort actors alphabetically or by number of videos, ascending or descending."),
            .init(label: "Filter button",
                  description: "Filter actors by gender, hair color, country, or actor tags."),
            .init(label: "Select",
                  description: "Turns on multi-select so you can tap several actors, then Edit to bulk-apply shared tags or details to all of them at once, or View Matches to see their combined videos."),
            .init(label: "Export to CSV",
                  description: "Saves every actor's name, bio, photo URL, home page, gender, hair color, birth year, and country to a spreadsheet file you can edit in Excel or Numbers. This is text only — it doesn't move actual photo files, just the photo's URL if one is set. The country is exported as its plain name (the flag emoji is stripped, since CSV can't carry it reliably)."),
            .init(label: "Import from CSV",
                  description: "Reads a CSV file (in the format Export produces) and updates matching actors. Only fills in the fields the CSV has a value for — a blank cell leaves whatever's already there untouched, and tags, gallery photos, and aliases are always preserved, since this format doesn't carry them. The country's flag emoji is added back automatically from the country name."),
            .init(label: "Pull to refresh (iPhone/iPad)",
                  description: "Pull down on the grid to re-scan the library folder for added or removed video files — the same check Settings → Check for Changes runs."),
        ]
    )

    static let tagGallery = HelpTopic(
        id: "tagGallery",
        title: "Tag Gallery",
        summary: "Browse every tag used across your library.",
        items: [
            .init(label: "A–Z picker",
                  description: "Jump straight to tags starting with a given letter."),
            .init(label: "Tag cards",
                  description: "Tap a tag to select it (you can select more than one); each card shows how many videos match that tag, plus a color-coded scope: green \"Film\" tags are applied directly to videos, blue \"Actor\" tags only live on actor profiles (like a hair color or physical trait), and orange \"Shared\" tags are used both ways. Selecting an Actor tag still finds videos — specifically, videos featuring an actor who carries that tag."),
            .init(label: "View Matches",
                  description: "Appears once you've selected one or more tags — switches to the All Assets grid filtered to videos with those tags."),
            .init(label: "Pull to refresh (iPhone/iPad)",
                  description: "Pull down on the grid to re-scan the library folder for added or removed video files — the same check Settings → Check for Changes runs."),
        ]
    )

    static let videoDetails = HelpTopic(
        id: "videoDetails",
        title: "Video Details",
        summary: "Everything about one video: playback, metadata, tags, and file management. Selecting more than one video at once shows a batch-edit version instead, for changing shared details across all of them together.",
        items: [
            .init(label: "Frame grid",
                  description: "Tap or drag across the thumbnail grid to seek the player to that point in the video."),
            .init(label: "Player controls",
                  description: "Show or hide the inline player, pop it out into its own window (Mac), or play from the start."),
            .init(label: "Scene Markers",
                  description: "Name and jump to specific moments in the video — like \"Lightsaber Fight\" at 5:25. Tap the + to add a marker at wherever the player is currently paused/scrubbed to, give it an optional name, and it appears as a thumbnail card you can tap anytime to jump straight back there. The preview picture is grabbed a few seconds after the marked moment (so it shows the actual scene rather than a transition frame), but tapping the card still jumps to the exact time you marked. Use the card's ⋯ menu to rename or delete a marker."),
            .init(label: "Reviewed toggle",
                  description: "Marks the video as reviewed or unreviewed."),
            .init(label: "Rating stars",
                  description: "Tap a star to set a 1–5 star rating; tap the same star again to clear the rating."),
            .init(label: "Notes",
                  description: "A free-text field for your own notes — saved as you type."),
            .init(label: "Play count",
                  description: "Shows how many times you've played the video and when you last watched it, once you've played it at least once. Counts once per visit to the video, not once per seek — scrubbing around while watching doesn't inflate the count."),
            .init(label: "Series Name, Season/Movie #, Episode #, Episode Title",
                  description: "Set which series this video belongs to, its season or movie number, its episode number, and an optional episode title. A preview underneath shows exactly how this will sort and file."),
            .init(label: "Tags, Actors, Studios",
                  description: "Add, rename, or remove entries in each category. Typing shows matching existing values to reuse, plus suggestions guessed from the filename. Tapping an existing tag/actor/studio jumps to its own page."),
            .init(label: "Rename File",
                  description: "Appears when the filename doesn't match what your metadata suggests it should be — lets you rename the file to match."),
            .init(label: "Missing file handling",
                  description: "If a video's file can't be found on disk, shows a Remove Missing File button that deletes just the library record (the file itself is already gone, so there's nothing to move)."),
            .init(label: "Previous / Next",
                  description: "Step through the same list of videos you arrived from, without going back to the grid."),
            .init(label: "Full-screen toggle",
                  description: "Expands the detail pane to fill the window."),
            .init(label: "Delete Video",
                  description: "In the Danger Zone section — moves the video file and its metadata to the Trash. Recoverable from the Trash, but not undoable within the app."),
            .init(label: "Batch edit (multiple videos selected)",
                  description: "Toggle reviewed status for all selected videos at once, add or remove tags shared across the whole selection, and set the same Series Name or Season number for every selected video. Episode number and episode title are edited one video at a time, since those are usually unique per video."),
        ]
    )

    static let actorProfile = HelpTopic(
        id: "actorProfile",
        title: "Actor Profile",
        summary: "An actor's full profile: photo, bio, details, and every video they appear in.",
        items: [
            .init(label: "Explore Related Links",
                  description: "A collapsible section (closed by default) showing studios, co-actors, tags, and series connected to this actor — tap any of them to jump straight there."),
            .init(label: "Profile photo",
                  description: "Tap it to browse a full-screen gallery of every photo you've added for this actor. Swipe left or right to move between photos, including wrapping from the last photo back to the first. Pinch to zoom in on a photo, and double-tap to reset it back to fit."),
            .init(label: "Ellipsis menu",
                  description: "Rename Globally changes this actor's name everywhere in your library at once. Edit Bio opens the full details form. Delete Profile removes the actor's profile — only available once they have no videos left."),
            .init(label: "Edit Bio form",
                  description: "Add a profile photo and gallery photos (by pasting an image URL), bio, home page, gender, hair color, birth year, country of origin (this adds a flag emoji automatically), tags, and aliases (AKAs) used to automatically match old filenames to this actor."),
            .init(label: "Filmography",
                  description: "Every video featuring this actor, shown as a grid — tap one to open it."),
        ]
    )

    static let seriesGallery = HelpTopic(
        id: "seriesGallery",
        title: "Series Gallery",
        summary: "Groups your videos by the Series Name you've given them — useful for multi-part movies, franchises, or anything filmed as \"episodes.\" Tap a series to see all its videos together.",
        items: [
            .init(label: "Series cards",
                  description: "Each card shows a series name and how many videos belong to it. Tap a card to open that series."),
            .init(label: "Season grouping",
                  description: "If your videos have a Season / Movie # set, opening a series while sorted by \"Series Order\" splits the videos into collapsible sections — Season 1, Season 2, and so on. A video with no season number is treated as Season 1. Tap a season's header to fold it away, which helps with series that have a lot of episodes."),
            .init(label: "Episode badges",
                  description: "Inside a series, each video's thumbnail shows its episode number in the corner, and the title underneath shows the episode's title (if you've given it one) instead of the raw filename."),
            .init(label: "Sort menu",
                  description: "Switch between \"Series Order\" (season, then episode, then date), Name, Date Added, or File Size. Season grouping only appears in Series Order — any other sort shows every video in one flat grid."),
            .init(label: "Explore Related Links",
                  description: "The collapsible card at the top of a series shows actors, studios, and tags that appear across the series' videos — tap any of them to jump to that actor, studio, or tag. It's closed by default; tap it to open."),
            .init(label: "Standardize Series (wand icon)",
                  description: "Videos are often typed by hand, so the same series can end up spelled slightly differently — \"Training\" vs \"training \" vs \"TRAINING.\" This tool finds names that are the same once you ignore capitalization and stray spaces, lets you pick (or type) the correct spelling, and merges them into one series."),
            .init(label: "Pull to refresh (iPhone/iPad)",
                  description: "Pull down on the grid to re-scan the library folder for added or removed video files — the same check Settings → Check for Changes runs."),
        ]
    )

    static let settings = HelpTopic(
        id: "settings",
        title: "Settings",
        summary: "Library-wide preferences and maintenance tools. Everything here works on your whole library, not just one video.",
        items: [
            .init(label: "Default Home Page",
                  description: "Which screen opens first when you launch the app: Dashboard, All Assets, Actors Gallery, or Tags Gallery."),
            .init(label: "Library Statistics",
                  description: "Counts for your library — total videos, actors, and tags, and how many are missing information like photos or bios — plus lists you can tap into to fix gaps."),
            .init(label: "Open Library",
                  description: "Switch to a different folder of videos, or point the app at a library for the first time."),
            .init(label: "Check for Changes",
                  description: "Re-scans your library folder for videos you've added or removed since the last time the app looked, and flags any video whose file has gone missing."),
            .init(label: "Move Videos Between Libraries",
                  description: "Moves videos between the open library and a second one you pick (e.g. a portable copy), a few at a time — handy when the destination drive can't hold everything at once. Pick the other library folder, choose which direction to move, and the tool shows the destination's free space and blocks a batch that won't fit. The source's videos appear as thumbnail cards with an A–Z jump strip at the top; tap to select any number, across letters, then move them together. Each video is copied and verified byte-for-byte before its original is removed, so nothing is lost mid-transfer. It also finds videos that exist in both libraries — confirmed truly identical by reading their full contents, not just size — and shows each with a thumbnail so you can tell what it is; for each you choose which copy to keep (the other is deleted), or leave it on Skip to decide later. Applying only acts on the ones you've decided; skipped duplicates stay in the list. Each moved video brings everything with it: all its metadata, tags, and scene markers, plus the profile data and photos of every actor it features (merged into the destination the same way the Actor Library merge tools do — existing actors are enriched, photos are added and never removed). So a moved video's actor info is always current, with no need to run a separate actor merge."),
            .init(label: "File Name Audit",
                  description: "Compares each video's actual filename to what its metadata (actors, series, tags) suggests it should be named, and lets you rename files in bulk to match."),
            .init(label: "Find Duplicates",
                  description: "Looks for videos that are likely the same file saved twice — matched by file size and, when needed, by checking the video's length too — so you can review and delete the extra copies."),
            .init(label: "Migrate Episode Info",
                  description: "A one-time cleanup for older videos that have season/episode info typed as plain text (like \"2 Episode 12\") instead of in the dedicated Season and Episode fields. It reads that old text, guesses the season and episode numbers, and lets you review and confirm before anything changes."),
            .init(label: "Tag & Actor Cleanup",
                  description: "Merges duplicate tags or actors (e.g. combining \"Sci-Fi\" and \"SciFi\"), and finds actor/tag/studio profiles that no longer have any videos attached, so you can remove them."),
            .init(label: "Export Actor Library For Merge",
                  description: "Packages up all of your actors' bios, details, and photos into a single file you can save anywhere (like iCloud Drive). Meant for moving enriched actor information between two copies of your library — for example, a \"portable\" library you've been working on and your main one."),
            .init(label: "Import and Merge Actor Library",
                  description: "Reads a file created by \"Export Actor Library For Merge\" and merges it into this library. Actors that don't exist yet are added. Actors that already exist have their bio and details fully replaced by the imported version, but photos are only ever added — you'll never lose a photo you already had, and it shows you exactly what will change before anything is applied."),
        ]
    )
}
