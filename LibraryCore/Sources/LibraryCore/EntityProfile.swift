// EntityProfile.swift
// The profile record for an actor/studio/tag/series entity: bio, photo URL,
// demographics, tags, gallery photo tokens, and AKAs. Ids are prefixed
// ("actor:Name").

import Foundation
import GRDB

/// What an external metadata lookup concluded about an entity.
///
/// Deliberately names NO source. This is core schema and lands in the public
/// repository; a field or value naming a specific provider would be preserved
/// forever in migrations and in every backup archive. A second provider must
/// reuse this type with no schema change — if it cannot, the plugin
/// abstraction has failed.
public enum EnrichmentState: String, Codable, Equatable, Sendable, CaseIterable {
    /// A record was found and its values were applied or offered.
    case matched
    /// The source has no record under this name. An alias may still match by hand.
    case noMatch
    /// Several equally plausible records. Identity was deliberately not guessed.
    case ambiguous
    /// Matched, but something disagreed and a human must settle it.
    case needsReview
    /// A PERSON looked and concluded this entity is not in the source.
    ///
    /// Distinct from `noMatch`, which only means an automated search returned
    /// nothing — a name may be misspelled, or the search term wrong. This one
    /// is a human decision to stop asking, and it is the only state a machine
    /// never assigns.
    case unmatchable

    /// Whether this outcome is waiting on a person.
    ///
    /// `unmatchable` is settled, not pending: someone already looked. Counting
    /// it would leave the queue permanently full of entities nobody can do
    /// anything about, which is the fastest way to make a queue ignored.
    public var needsAttention: Bool {
        self != .matched && self != .unmatchable
    }

    /// True when only a person can have set this. Nothing automated may.
    public var isHumanJudgement: Bool { self == .unmatchable }

    public var displayName: String {
        switch self {
        case .matched: return "Matched"
        case .noMatch: return "No match"
        case .ambiguous: return "Ambiguous"
        case .needsReview: return "Needs review"
        case .unmatchable: return "Not findable"
        }
    }
}

public struct EntityProfile: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    /// The primary key.
    ///
    /// ⚠️ `private(set)`, so it can only be changed inside this file — by
    /// `reidentified(as:)` and nothing else. It was `let`, and had to become
    /// settable for v28's federation boundary, which must re-key an arriving
    /// profile to a LOCAL id rather than adopting the sender's.
    ///
    /// 🚨 Kept this tight deliberately. A freely mutable primary key is a
    /// silent corruption waiting to happen, and reconstructing the struct
    /// field-by-field instead would have added a NINTH place that must be
    /// updated whenever a property is added — the trap that has already cost
    /// this project a whole-graph data loss.
    public private(set) var id: String

    /// `actor` / `studio`, stored rather than parsed out of the key.
    ///
    /// ⚠️ Optional because a profile constructed in code has not been through
    /// the database yet, and every existing call site builds one that way.
    /// Read `type`, never this.
    public private(set) var entityType: String?

    /// The name as a person reads it, stored rather than parsed out of the key.
    ///
    /// 🚨 This is what makes the re-key survivable. Once `id` is an opaque uid
    /// it carries no name at all, and a name is NOT recoverable from a uid — so
    /// the moment ids stop encoding names, this column is the only record of
    /// what anything is called.
    ///
    /// Read `name`, never this.
    public private(set) var displayName: String?
    public var bio: String?
    public var photoUrl: String?
    public var homePage: String?
    
    public var gender: String?
    public var hairColor: String?

    /// Identifying marks, as the source describes them (v33).
    ///
    /// ⭐ Held for IDENTIFICATION rather than description. Two performers of
    /// one name is the recurring difficulty in this app, and a tattoo
    /// distinguishes them where a birth year does not.
    ///
    /// ⚠️ A SNAPSHOT, not a standing fact. Piercings come out and tattoos are
    /// reworked, and nothing here records when the description was true — so it
    /// is shown with `enrichmentCheckedAt` beside it. See `marksAsOf`.
    ///
    /// ⚠️ Free text. Not filterable, deliberately: it cannot reliably answer
    /// "who has a back piece", and a filter that half works is worse than none.
    public var tattoos: String?
    public var piercings: String?
    public var birthYear: Int?
    public var countryOfOrigin: String?
    /// 1–5 star favorite rating (nil = unrated). Added in schema v15.
    public var rating: Int?
    public var createdAt: Date?

    // MARK: - Career span (schema v17)
    //
    // Generic by design: a career span, a birth date and an age at first credit
    // are meaningful for any performer in any video — documentary, film,
    // television. Nothing here assumes a domain or a source.

    /// Precise birth date as ISO `YYYY-MM-DD`.
    ///
    /// `birthYear` is KEPT as the fallback for records where only a year is
    /// known, and stays the CSV's birth column, so nothing that reads it today
    /// has to change. When a full date is known, both are written.
    public var birthDate: String?

    /// Verbatim career-span text, exactly as a prose source stated it.
    ///
    /// A provenance slot: it is **never generated**. Structured sources leave it
    /// `nil`, and the display string is computed from the years rather than read
    /// from here.
    public var careerSpanRaw: String?

    public var careerStartYear: Int?

    /// `nil` means the span is OPEN — "still performing" — not "we failed to
    /// find an end". Career-end scarcity is a fact of the data (three
    /// independent sources agree), so a missing end is rendered as `-present`
    /// rather than carrying a separate status field.
    public var careerEndYear: Int?

    /// Age when the career began, where a source stated it outright.
    ///
    /// Stored rather than always derived because a prose source may state it
    /// directly, and because it is a fixed historical fact that cannot go stale.
    /// Prefer `careerStartAge`, which falls back to deriving it.
    public var ageAtCareerStart: Int?

    // MARK: - Enrichment state (schema v18)
    //
    // Records THAT an external lookup ran and WHAT it concluded — never which
    // provider concluded it. See EnrichmentState.

    public var enrichmentState: EnrichmentState?

    /// The provider's display name, supplied at RUNTIME by whichever plugin ran.
    /// Data, not code: storing a name a plugin handed us is not the repository
    /// naming a source.
    public var enrichmentSource: String?
    /// The source's own identifier for this person.
    ///
    /// Without it every later lookup re-searches by name and re-guesses which
    /// of several same-named people was meant — discarding a match that was
    /// already validated once. Recording it turns that into a lookup.
    public var enrichmentSourceId: String?

    /// When the lookup ran. `nil` means NEVER ATTEMPTED, which is not the same
    /// as `noMatch` — conflating them would make every un-enriched entity look
    /// like a failure.
    public var enrichmentCheckedAt: Date?

    /// Labelled external references (schema v19).
    ///
    /// Generalises the single `homePage` field: an entity may sit on several
    /// systems, and a bare URL with no label renders poorly. Populated by the
    /// operator, by a provider, or both. Core stores them and never fetches them.
    public var links: [EntityLink] = []

    /// The identifying marks with the date they were last checked, or nil when
    /// there are none.
    ///
    /// ⚠️ Exists so no caller renders these as a permanent truth about someone.
    /// The date is the profile's, not the marks' — the source does not say when
    /// a tattoo appeared — so it answers "as of when did we look", which is the
    /// most that can honestly be claimed.
    public var marksAsOf: (marks: [(String, String)], checked: Date?)? {
        var found: [(String, String)] = []
        if let tattoos, !tattoos.isEmpty { found.append(("Tattoos", tattoos)) }
        if let piercings, !piercings.isEmpty { found.append(("Piercings", piercings)) }
        return found.isEmpty ? nil : (found, enrichmentCheckedAt)
    }

    /// True only when a lookup has run and concluded something needing a person.
    /// An entity never checked is not "needing attention"; it is unknown.
    public var needsEnrichmentAttention: Bool {
        enrichmentState?.needsAttention ?? false
    }

    // MARK: - Derived, never stored
    //
    // Follows the `age` precedent: computing from stored facts avoids baking in
    // a number that is wrong the following year.

    /// The birth year, preferring the precise date when one is known.
    public var resolvedBirthYear: Int? {
        if let birthDate, birthDate.count >= 4, let year = Int(birthDate.prefix(4)) {
            return year
        }
        return birthYear
    }

    public var age: Int? { age(asOf: Date()) }

    /// Exact where a full birth date is known — a birthday later this year has
    /// not happened yet, and rounding it up would overstate the age by a year.
    public func age(asOf now: Date) -> Int? {
        let calendar = Calendar.current
        if let birthDate, let born = EntityProfile.isoDate(birthDate) {
            return calendar.dateComponents([.year], from: born, to: now).year.map { max(0, $0) }
        }
        guard let birthYear else { return nil }
        return max(0, calendar.component(.year, from: now) - birthYear)
    }

    /// True when the performer has a recorded start and no recorded end.
    public var isCareerOngoing: Bool { careerStartYear != nil && careerEndYear == nil }

    public var yearsActive: Int? { yearsActive(asOf: Date()) }

    public func yearsActive(asOf now: Date) -> Int? {
        guard let start = careerStartYear else { return nil }
        let end = careerEndYear ?? Calendar.current.component(.year, from: now)
        return max(0, end - start)
    }

    /// Age at career start: stated by a source where available, otherwise
    /// derived. Deriving on read means correcting a birth year fixes this too.
    public var careerStartAge: Int? {
        if let ageAtCareerStart { return ageAtCareerStart }
        guard let start = careerStartYear, let born = resolvedBirthYear else { return nil }
        let derived = start - born
        return (0...120).contains(derived) ? derived : nil
    }

    /// `"1994-present (started around 18 years old; 32 years active)"`.
    ///
    /// `nil` when there is no start year, because a span with no beginning says
    /// nothing worth showing.
    public var careerDisplay: String? { careerDisplay(asOf: Date()) }

    public func careerDisplay(asOf now: Date) -> String? {
        guard let start = careerStartYear else { return nil }
        let span = careerEndYear.map { "\(start)-\($0)" } ?? "\(start)-present"

        var notes: [String] = []
        if let age = careerStartAge { notes.append("started around \(age) years old") }
        if let years = yearsActive(asOf: now), years > 0 { notes.append("\(years) years active") }

        return notes.isEmpty ? span : "\(span) (\(notes.joined(separator: "; ")))"
    }

    /// Parses the stored ISO date. Fixed to UTC and POSIX so a stored date means
    /// the same thing regardless of where the device is.
    static func isoDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    
    public var tags: [String]
    public var galleryUrls: [String]
    public var akas: [String]
    
    public static let databaseTableName = "entity_profiles"
    
    public init(id: String,
                entityType: String? = nil,
                displayName: String? = nil,
                bio: String? = nil, photoUrl: String? = nil, homePage: String? = nil, gender: String? = nil, hairColor: String? = nil, tattoos: String? = nil, piercings: String? = nil, birthYear: Int? = nil, countryOfOrigin: String? = nil, rating: Int? = nil, tags: [String] = [], galleryUrls: [String] = [], akas: [String] = [], createdAt: Date? = Date(), birthDate: String? = nil, careerSpanRaw: String? = nil, careerStartYear: Int? = nil, careerEndYear: Int? = nil, ageAtCareerStart: Int? = nil, enrichmentState: EnrichmentState? = nil, enrichmentSource: String? = nil, enrichmentSourceId: String? = nil, enrichmentCheckedAt: Date? = nil, links: [EntityLink] = []) {
        self.links = links
        self.enrichmentState = enrichmentState
        self.enrichmentSource = enrichmentSource
        self.enrichmentSourceId = enrichmentSourceId
        self.enrichmentCheckedAt = enrichmentCheckedAt
        self.birthDate = birthDate
        self.careerSpanRaw = careerSpanRaw
        self.careerStartYear = careerStartYear
        self.careerEndYear = careerEndYear
        self.ageAtCareerStart = ageAtCareerStart
        self.id = id
        // ⭐ Derived when not supplied, so the EIGHT sites that rebuild a
        // profile field-by-field stay correct without each having to carry
        // these — while `id` still encodes the name, deriving and carrying
        // give the same answer.
        //
        // 🚨 That equivalence ENDS at the re-key. Once `id` is a uid there is
        // nothing to derive from, and every one of those sites must pass the
        // fields through explicitly or it will rebuild a nameless profile.
        // See `EntityProfilePreservationTests.testFieldCountIsPinned`.
        self.entityType = entityType ?? NodeIdentity.parse(id)?.type
        self.displayName = displayName ?? NodeIdentity.parse(id)?.displayName
        self.bio = bio
        self.photoUrl = photoUrl
        self.homePage = homePage
        self.gender = gender
        self.hairColor = hairColor
        self.tattoos = tattoos
        self.piercings = piercings
        self.birthYear = birthYear
        self.countryOfOrigin = countryOfOrigin
        self.rating = rating
        self.tags = tags
        self.galleryUrls = galleryUrls
        self.akas = akas
        self.createdAt = createdAt
    }
    
    /// The same node under a new NAME, keeping its id.
    ///
    /// ⭐ What a rename becomes after the re-key. The node does not move —
    /// its uid is stable — so nothing else in the library has to be told
    /// about it. Compare `renamed(to:)`, which changes the key and therefore
    /// obliges the caller to re-point every edge and photo that named it.
    ///
    /// ⚠️ Refuses an empty name. A profile with no display name is one the
    /// operator can no longer find, and after the re-key the name is the only
    /// record of what the node is called.
    public func renamedInPlace(to newName: String) -> EntityProfile {
        guard !newName.isEmpty else { return self }
        var copy = self
        copy.displayName = newName
        return copy
    }

    /// The same profile under a new id.
    ///
    /// Exists so that renaming enumerates the fields in exactly ONE place. Every
    /// rename bug this model has had was a second copy of that list drifting
    /// behind it: first dropped AKAs, then the whole of the career span, then
    /// enrichment state and links. A caller that writes the list itself will
    /// eventually be wrong again, and the compiler cannot warn about it because
    /// every added field has a default.
    public func renamed(to newId: String) -> EntityProfile {
        EntityProfile(
            id: newId,
            // ⭐ A rename is the one site where the name legitimately CHANGES —
            // but only while the key still encodes it. Once ids are uids a
            // rename must not blank the name it cannot read from the new key.
            entityType: NodeIdentity.parse(newId)?.type ?? entityType,
            displayName: NodeIdentity.parse(newId)?.displayName ?? displayName,
            bio: bio,
            photoUrl: photoUrl,
            homePage: homePage,
            gender: gender,
            hairColor: hairColor,
            tattoos: tattoos,
            piercings: piercings,
            birthYear: birthYear,
            countryOfOrigin: countryOfOrigin,
            rating: rating,
            tags: tags,
            galleryUrls: galleryUrls,
            akas: akas,
            createdAt: createdAt,
            birthDate: birthDate,
            careerSpanRaw: careerSpanRaw,
            careerStartYear: careerStartYear,
            careerEndYear: careerEndYear,
            ageAtCareerStart: ageAtCareerStart,
            enrichmentState: enrichmentState,
            enrichmentSource: enrichmentSource,
            enrichmentSourceId: enrichmentSourceId,
            enrichmentCheckedAt: enrichmentCheckedAt,
            links: links
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case entityType = "entity_type"
        case displayName = "display_name"
        case bio
        case photoUrl = "photo_url"
        case homePage = "home_page"
        case gender
        case hairColor = "hair_color"
        case tattoos
        case piercings
        case birthYear = "birth_year"
        case countryOfOrigin = "country_of_origin"
        case rating
        case tags
        case galleryUrls = "gallery_urls"
        case akas
        case createdAt = "created_at"
        case birthDate = "birth_date"
        case careerSpanRaw = "career_span_raw"
        case careerStartYear = "career_start_year"
        case careerEndYear = "career_end_year"
        case ageAtCareerStart = "age_at_career_start"
        case enrichmentState = "enrichment_state"
        case enrichmentSource = "enrichment_source"
        case enrichmentSourceId = "enrichment_source_id"
        case enrichmentCheckedAt = "enrichment_checked_at"
        case links
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        // ⚠️ `decodeIfPresent`, so a file or row written before these existed
        // reads as "derive it from the id" rather than failing.
        self.entityType = try container.decodeIfPresent(String.self, forKey: .entityType)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.bio = try container.decodeIfPresent(String.self, forKey: .bio)
        self.photoUrl = try container.decodeIfPresent(String.self, forKey: .photoUrl)
        self.homePage = try container.decodeIfPresent(String.self, forKey: .homePage)
        self.gender = try container.decodeIfPresent(String.self, forKey: .gender)
        self.hairColor = try container.decodeIfPresent(String.self, forKey: .hairColor)
        self.tattoos = try container.decodeIfPresent(String.self, forKey: .tattoos)
        self.piercings = try container.decodeIfPresent(String.self, forKey: .piercings)
        self.birthYear = try container.decodeIfPresent(Int.self, forKey: .birthYear)
        self.countryOfOrigin = try container.decodeIfPresent(String.self, forKey: .countryOfOrigin)
        self.rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.birthDate = try container.decodeIfPresent(String.self, forKey: .birthDate)
        self.careerSpanRaw = try container.decodeIfPresent(String.self, forKey: .careerSpanRaw)
        self.careerStartYear = try container.decodeIfPresent(Int.self, forKey: .careerStartYear)
        self.careerEndYear = try container.decodeIfPresent(Int.self, forKey: .careerEndYear)
        self.ageAtCareerStart = try container.decodeIfPresent(Int.self, forKey: .ageAtCareerStart)
        // Tolerant: a value written by a newer build must not fail the whole
        // decode on an older one, and archives predate the column entirely.
        self.enrichmentState = (try? container.decodeIfPresent(String.self, forKey: .enrichmentState))
            .flatMap { $0.flatMap(EnrichmentState.init(rawValue:)) }
        self.enrichmentSource = try container.decodeIfPresent(String.self, forKey: .enrichmentSource)
        self.enrichmentSourceId = try container.decodeIfPresent(String.self, forKey: .enrichmentSourceId)
        self.enrichmentCheckedAt = try container.decodeIfPresent(Date.self, forKey: .enrichmentCheckedAt)
        // Stored as a JSON string in SQLite, like tags/akas — accept either
        // shape so an archive and a live row both decode.
        if let array = try? container.decode([EntityLink].self, forKey: .links) {
            self.links = array
        } else if let text = try? container.decode(String.self, forKey: .links),
                  let data = text.data(using: .utf8) {
            self.links = (try? JSONDecoder().decode([EntityLink].self, from: data)) ?? []
        } else {
            self.links = []
        }
        
        var decodedTags: [String] = []
        if let tagsArray = try? container.decode([String].self, forKey: .tags) {
            decodedTags = tagsArray
        } else if let tagsString = try? container.decode(String.self, forKey: .tags),
                  let data = tagsString.data(using: .utf8) {
            decodedTags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        self.tags = decodedTags.map { TagNormalizer.normalize(fullTag: $0) }
        
        var decodedGallery: [String] = []
        if let galleryArray = try? container.decode([String].self, forKey: .galleryUrls) {
            decodedGallery = galleryArray
        } else if let galleryString = try? container.decode(String.self, forKey: .galleryUrls),
                  let data = galleryString.data(using: .utf8) {
            decodedGallery = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        self.galleryUrls = decodedGallery
        
        var decodedAkas: [String] = []
        if let akasArray = try? container.decode([String].self, forKey: .akas) {
            decodedAkas = akasArray
        } else if let akasString = try? container.decode(String.self, forKey: .akas),
                  let data = akasString.data(using: .utf8) {
            decodedAkas = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        self.akas = decodedAkas
    }
}

// MARK: - GRDB Persistence
extension EntityProfile {
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id

        // v34 (Opaque Node Identity, additive half). Written on EVERY save, not
        // only backfilled by the migration.
        //
        // 🚨 Without this the columns would be correct for every row that
        // existed when v34 ran and permanently NULL for every row created
        // after — a column that is right for the old data and silently empty
        // for the new is worse than no column, because the first thing to read
        // it would look correct in testing and be wrong in use.
        //
        // ⚠️ Derived from `id` only while `id` still encodes the name. When the
        // re-keying tool makes `id` an opaque uid, `display_name` becomes
        // authoritative and these two lines must become stored properties
        // instead. That is the tool's job, and it rewrites every row anyway.
        // 🚨 Written ONLY while the id still encodes them.
        //
        // After the re-keying tool runs, `id` is an opaque uid with no colon,
        // so `nodeIdentity` is nil — and assigning nil here would blank
        // `display_name` on the very next save of every profile, destroying the
        // only remaining record of what each node is called. The name is not
        // recoverable from a uid.
        //
        // ⚠️ Omitting the keys leaves the stored values untouched: GRDB builds
        // its UPDATE from the columns present in the container, so a column
        // that is never set is never written.
        // ⭐ The RESOLVED values: stored if we have them, derived while the id
        // still encodes them. Either way the column ends up correct.
        //
        // 🚨 Never nil-out. After the re-key `nodeIdentity` is nil, and writing
        // that would blank the only record of what this node is called on the
        // very next save.
        if let type = type { container["entity_type"] = type }
        if displayName != nil || nodeIdentity != nil { container["display_name"] = name }
        container["bio"] = bio
        container["photo_url"] = photoUrl
        container["home_page"] = homePage
        container["gender"] = gender
        container["hair_color"] = hairColor
        container["tattoos"] = tattoos
        container["piercings"] = piercings
        container["birth_year"] = birthYear
        container["country_of_origin"] = countryOfOrigin
        container["rating"] = rating
        container["created_at"] = createdAt
        container["birth_date"] = birthDate
        container["career_span_raw"] = careerSpanRaw
        container["career_start_year"] = careerStartYear
        container["career_end_year"] = careerEndYear
        container["age_at_career_start"] = ageAtCareerStart
        container["enrichment_state"] = enrichmentState?.rawValue
        container["enrichment_source"] = enrichmentSource
        container["enrichment_source_id"] = enrichmentSourceId
        container["enrichment_checked_at"] = enrichmentCheckedAt
        if let data = try? JSONEncoder().encode(links),
           let string = String(data: data, encoding: .utf8) {
            container["links"] = string
        } else {
            container["links"] = "[]"
        }
        
        if let data = try? JSONEncoder().encode(tags),
           let string = String(data: data, encoding: .utf8) {
            container["tags"] = string
        } else {
            container["tags"] = "[]"
        }
        
        if let data = try? JSONEncoder().encode(galleryUrls),
           let string = String(data: data, encoding: .utf8) {
            container["gallery_urls"] = string
        } else {
            container["gallery_urls"] = "[]"
        }
        
        if let data = try? JSONEncoder().encode(akas),
           let string = String(data: data, encoding: .utf8) {
            container["akas"] = string
        } else {
            container["akas"] = "[]"
        }
    }

    /// The name to show.
    ///
    /// ⭐ Stored value first, then the id-derived one, then the raw id. While
    /// ids still encode names the first two agree, so preferring the stored one
    /// changes nothing today and is required the moment they diverge.
    ///
    /// ⚠️ Falls back to the id rather than to an empty string: a row rendered
    /// blank is one nobody can find or fix.
    public var name: String {
        displayName ?? nodeIdentity?.displayName ?? id
    }

    /// What kind of node this is, by the same precedence.
    public var type: String? {
        entityType ?? nodeIdentity?.type
    }

    /// The same profile under a different primary key.
    ///
    /// 🚨 Exists for ONE caller: the federation boundary, which must write an
    /// arriving profile under an id THIS library derives rather than the one
    /// the sender happened to use. After v28 the sender's id may be an opaque
    /// uid minted on a machine this library has never seen, and adopting it
    /// would key a local row by a foreign identifier.
    ///
    /// ⭐ Today it is almost always a no-op, because the local form and the
    /// arriving form are the same string. That is the point — phase 0 changes
    /// no behaviour, so it can be shipped and exercised on real libraries
    /// before there is any re-keying to debug it against.
    ///
    /// ⚠️ Every other field is carried untouched, and deliberately NOT
    /// re-listed. Enumerating them here would make this the ninth place that
    /// must be updated whenever a property is added — the omission that once
    /// discarded studios, tags and every graph edge on import.
    ///
    /// Returns `self` unchanged when the id already matches, so callers need
    /// not check first.
    public func reidentified(as newId: String) -> EntityProfile {
        guard newId != id, !newId.isEmpty else { return self }
        var copy = self
        copy.id = newId
        return copy
    }
}
