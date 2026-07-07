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
        seriesGallery,
        settings,
    ]

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
