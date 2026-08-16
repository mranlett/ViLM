// LibraryStatsView.swift
// The Library Statistics page: film/actor/tag completeness stats with
// drill-down navigation, top actors by image count, and tag usage - all
// computed off the main thread from a full library scan.

import SwiftUI
import LibraryCore

struct LibraryStatsView: View {
    let libraryURL: URL?
    var onSelectAsset: ((Asset.ID) -> Void)?
    var onSelectActor: ((String) -> Void)?
    var onSelectTag: ((String) -> Void)?
    var onOpenTagGallery: (() -> Void)?
    
    // Films
    @State private var totalFilms = 0
    @State private var filmsWithTags: [Asset] = []
    @State private var untaggedFilms: [Asset] = []
    @State private var filmsWithActors: [Asset] = []
    @State private var filmsWithoutActors: [Asset] = []
    @State private var filmsWithThumbnails: [Asset] = []
    @State private var filmsWithoutThumbnails: [Asset] = []
    
    // Actors
    @State private var totalActors = 0
    @State private var actorsWithTags: [EntityProfile] = []
    @State private var actorsWithoutTags: [EntityProfile] = []
    @State private var actorsWithImages: [EntityProfile] = []
    @State private var actorsWithoutImages: [EntityProfile] = []
    @State private var actorsWithGender: [EntityProfile] = []
    @State private var actorsWithoutGender: [EntityProfile] = []
    @State private var actorsWithHairColor: [EntityProfile] = []
    @State private var actorsWithoutHairColor: [EntityProfile] = []
    @State private var actorsWithBirthYear: [EntityProfile] = []
    @State private var actorsWithoutBirthYear: [EntityProfile] = []
    @State private var actorsWithCountry: [EntityProfile] = []
    @State private var actorsWithoutCountry: [EntityProfile] = []
    @State private var actorsComplete: [EntityProfile] = []
    @State private var totalActorPhotos = 0
    
    struct TopActor: Hashable {
        let name: String
        let count: Int
    }
    @State private var topActorsByPhotos: [TopActor] = []
    
    // Tags
    @State private var totalTags = 0
    @State private var filmTagsCount = 0
    @State private var actorTagsCount = 0
    @State private var sharedTagsCount = 0
    
    struct TopTag: Hashable {
        let name: String
        let count: Int
    }
    @State private var topTagsByUsage: [TopTag] = []
    
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Calculating Statistics...")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        
                        // Header details
                        Text("\(totalFilms) films · \(totalActors) actors · \(totalTags) unique tags")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 18)
                        
                        // Dashboard Top Row
                        HStack(spacing: 10) {
                            let filmPct = totalFilms > 0 ? Double(filmsWithTags.count) / Double(totalFilms) : 0
                            StatRingView(percentage: filmPct, label: "Films Complete")
                            
                            let actorPct = totalActors > 0 ? Double(actorsComplete.count) / Double(totalActors) : 0
                            StatRingView(percentage: actorPct, label: "Actors Complete")
                            
                            VStack(spacing: 6) {
                                Text("\(totalTags)")
                                    .font(.system(size: 24, weight: .bold))
                                Text("Unique Tags")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.primary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(PlatformSystemBackground))
                            .cornerRadius(20)
                            .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                        
                        // Films Section
                        Text("FILMS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text("Total Films")
                                    .font(.system(size: 15))
                                Spacer()
                                Text("\(totalFilms)")
                                    .font(.system(size: 17, weight: .bold))
                            }
                            .padding(.vertical, 12)
                            
                            Divider()
                            
                            NavigationLink(destination: UntaggedFilmsView(films: untaggedFilms, onSelect: onSelectAsset)) {
                                StatProgressBarRow(title: "Tags", value: filmsWithTags.count, missing: untaggedFilms.count, valueLabel: "tagged", missingLabel: "untagged")
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Divider()
                            
                            NavigationLink(destination: FilmsWithoutActorsView(films: filmsWithoutActors, onSelect: onSelectAsset)) {
                                StatProgressBarRow(title: "Actors", value: filmsWithActors.count, missing: filmsWithoutActors.count, valueLabel: "have actors", missingLabel: "no actors")
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Divider()
                            
                            StatProgressBarRow(title: "Thumbnails", value: filmsWithThumbnails.count, missing: filmsWithoutThumbnails.count, valueLabel: "have thumbnail", missingLabel: "missing", showChevron: false)
                        }
                        .padding(.horizontal, 16)
                        .background(Color(PlatformSystemBackground))
                        .cornerRadius(20)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                        
                        // Actors Section
                        Text("ACTORS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text("Total Actors")
                                    .font(.system(size: 15))
                                Spacer()
                                Text("\(totalActors)")
                                    .font(.system(size: 17, weight: .bold))
                            }
                            .padding(.vertical, 12)
                            
                            Divider()
                            
                            StatProgressBarRow(title: "Saved Images", value: actorsWithImages.count, missing: actorsWithoutImages.count, valueLabel: "have images", missingLabel: "missing", showChevron: false, barColor: .blue)

                            Divider()

                            NavigationLink(destination: ActorsMissingFieldView(title: "Actors Without Gender", profiles: actorsWithoutGender, onSelect: onSelectActor)) {
                                StatProgressBarRow(title: "Gender", value: actorsWithGender.count, missing: actorsWithoutGender.count, valueLabel: "set", missingLabel: "missing", barColor: .blue)
                            }
                            .buttonStyle(PlainButtonStyle())

                            Divider()

                            NavigationLink(destination: ActorsMissingFieldView(title: "Actors Without Hair Color", profiles: actorsWithoutHairColor, onSelect: onSelectActor)) {
                                StatProgressBarRow(title: "Hair Color", value: actorsWithHairColor.count, missing: actorsWithoutHairColor.count, valueLabel: "set", missingLabel: "missing", barColor: .blue)
                            }
                            .buttonStyle(PlainButtonStyle())

                            Divider()

                            NavigationLink(destination: ActorsMissingFieldView(title: "Actors Without Date of Birth", profiles: actorsWithoutBirthYear, onSelect: onSelectActor)) {
                                StatProgressBarRow(title: "Date of Birth", value: actorsWithBirthYear.count, missing: actorsWithoutBirthYear.count, valueLabel: "set", missingLabel: "missing", barColor: .blue)
                            }
                            .buttonStyle(PlainButtonStyle())

                            Divider()

                            NavigationLink(destination: ActorsMissingFieldView(title: "Actors Without Country of Origin", profiles: actorsWithoutCountry, onSelect: onSelectActor)) {
                                StatProgressBarRow(title: "Country of Origin", value: actorsWithCountry.count, missing: actorsWithoutCountry.count, valueLabel: "set", missingLabel: "missing", barColor: .blue)
                            }
                            .buttonStyle(PlainButtonStyle())

                            Divider()

                            NavigationLink(destination: ActorsWithoutTagsView(profiles: actorsWithoutTags, onSelect: onSelectActor)) {
                                StatProgressBarRow(title: "Tags", value: actorsWithTags.count, missing: actorsWithoutTags.count, valueLabel: "tagged", missingLabel: "untagged", barColor: .blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Divider()
                            
                            HStack {
                                Text("Total Saved Images")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text("\(totalActorPhotos)")
                                    .font(.system(size: 15, weight: .bold))
                            }
                            .padding(.vertical, 12)
                        }
                        .padding(.horizontal, 16)
                        .background(Color(PlatformSystemBackground))
                        .cornerRadius(20)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        
                        // Top Actors By Image Count
                        Text("TOP ACTORS BY IMAGE COUNT")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        
                        VStack(spacing: 0) {
                            let maxImg = topActorsByPhotos.first?.count ?? 0
                            ForEach(Array(topActorsByPhotos.enumerated()), id: \.element.name) { index, actor in
                                Button(action: { onSelectActor?(actor.name) }) {
                                    StatBarChartRow(index: index + 1, title: actor.name, count: actor.count, maxCount: maxImg, barColor: .blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                                if index < topActorsByPhotos.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(Color(PlatformSystemBackground))
                        .cornerRadius(20)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                        
                        // Tags Section
                        Text("TAGS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        
                        Button(action: { onOpenTagGallery?() }) {
                            VStack(spacing: 0) {
                                HStack {
                                    Text("Total Unique Tags")
                                        .font(.system(size: 15))
                                    Spacer()
                                    Text("\(totalTags)")
                                        .font(.system(size: 17, weight: .bold))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14))
                                        .foregroundColor(Color.secondary.opacity(0.4))
                                }
                                .padding(.vertical, 12)

                                Divider()

                                HStack {
                                    Text("Film Tags")
                                        .font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    Text("\(filmTagsCount)")
                                        .font(.system(size: 13))
                                        .foregroundColor(.primary)
                                }
                                .padding(.vertical, 12)

                                Divider()

                                HStack {
                                    Text("Actor Tags")
                                        .font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    Text("\(actorTagsCount)")
                                        .font(.system(size: 13))
                                        .foregroundColor(.primary)
                                }
                                .padding(.vertical, 12)

                                Divider()

                                HStack {
                                    Text("Shared Tags")
                                        .font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    Text("\(sharedTagsCount)")
                                        .font(.system(size: 13))
                                        .foregroundColor(.primary)
                                }
                                .padding(.vertical, 12)
                            }
                            .padding(.horizontal, 16)
                            .background(Color(PlatformSystemBackground))
                            .cornerRadius(20)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        
                        Text("Film and actor tag pools overlap — shared tags are used on both.")
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                        
                        // Top Tags By Usage
                        Text("TOP TAGS BY USAGE")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        
                        VStack(spacing: 0) {
                            let maxTag = topTagsByUsage.first?.count ?? 0
                            ForEach(topTagsByUsage, id: \.name) { tag in
                                Button(action: { onSelectTag?(tag.name) }) {
                                    StatBarChartRow(index: nil, title: tag.name, count: tag.count, maxCount: maxTag, barColor: .blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                                if tag.name != topTagsByUsage.last?.name {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(Color(PlatformSystemBackground))
                        .cornerRadius(20)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                    }
                    .padding(.top, 10)
                }
                .background(Color(PlatformSystemGroupedBackground).edgesIgnoringSafeArea(.all))
            }
        }
        .navigationTitle("Library Statistics")
        .task {
            await loadStats()
        }
    }
    
    private func loadStats() async {
        guard let url = libraryURL else {
            isLoading = false
            return
        }

        // Videos come from the session union (all open libraries); actor
        // profiles remain primary-only until the merged actor view lands.
        let unionAssets = (try? LibrarySession.shared.fetchUnionAssets().assets) ?? []

        await Task.detached(priority: .utility) {
            do {
                let store = try LibraryStore(at: url)
                let assets = unionAssets
                // fetchAllEntityProfiles() returns actors, studios, tags, and
                // series alike — this page's "Actors" stats only make sense
                // for actor profiles.
                let profiles = try store.fetchAllEntityProfiles().filter { $0.type == "actor" }
                
                let thumbDir = url.appendingPathComponent(".catalog/thumbnails")
                let profileDir = url.appendingPathComponent(".catalog/profiles")
                
                // Films lists
                var fWithTags: [Asset] = []
                var fNoTags: [Asset] = []
                var fWithActors: [Asset] = []
                var fNoActors: [Asset] = []
                var fWithThumbs: [Asset] = []
                var fNoThumbs: [Asset] = []
                
                var allFilmTagsSet = Set<String>()
                var tagUsageCounts: [String: Int] = [:]
                
                for asset in assets {
                    if !asset.actions.isEmpty {
                        fWithTags.append(asset)
                        for tag in asset.actions { 
                            allFilmTagsSet.insert(tag)
                            tagUsageCounts[tag, default: 0] += 1
                        }
                    } else {
                        fNoTags.append(asset)
                    }
                    
                    if !asset.actors.isEmpty {
                        fWithActors.append(asset)
                    } else {
                        fNoActors.append(asset)
                    }
                    
                    let thumbFile = thumbDir.appendingPathComponent("\(asset.id.uuidString).jpg")
                    if FileManager.default.fileExists(atPath: thumbFile.path) {
                        fWithThumbs.append(asset)
                    } else {
                        fNoThumbs.append(asset)
                    }
                }
                
                // The actor stats must cover every actor the library
                // references, not just those with a saved EntityProfile row —
                // an actor tagged on a video but never opened/edited has no
                // profile, which trivially means it's missing every field.
                // Build the full universe (asset actor-tags ∪ profile ids,
                // with AKA resolution) and back each name with its real
                // profile or a synthesized blank one, so the completeness
                // checks and drill-down lists see unprofiled actors too.
                var profilesById: [String: EntityProfile] = [:]
                for p in profiles { profilesById[p.id] = p }

                // ⚠️ ACTORS only. This loop never had a type filter — it
                // sliced six characters off every id, so a studio contributed
                // ":Foo" and a tag "ar": garbage that happened to match
                // nothing. Reading the name column returns the REAL studio
                // name, which would land actual studios in the actor lists —
                // so the filter the old code got away with omitting is now
                // load-bearing.
                var akaMap: [String: String] = [:]
                for p in profiles where p.type == "actor" {
                    for aka in p.akas { akaMap[aka] = p.name }
                }

                var actorNames = Set<String>()
                for asset in assets {
                    for name in asset.actors {
                        actorNames.insert(akaMap[name] ?? name)
                    }
                }
                for p in profiles where p.type == "actor" {
                    actorNames.insert(p.name)
                }

                // ⭐ Looked up by NAME. `profilesById` is keyed by id, which
                // stops matching a name-form key after the re-key — every
                // actor would then get a blank stand-in and the completeness
                // stats would report the whole library as unenriched.
                let byName = EntityProfileIndex(profiles)
                let actorEntities: [EntityProfile] = actorNames.map { name in
                    byName[actor: name]
                        ?? EntityProfile(id: "actor:\(name)", entityType: "actor",
                                         displayName: name)
                }

                // Actors lists
                var aWithTags: [EntityProfile] = []
                var aNoTags: [EntityProfile] = []
                var aWithImages: [EntityProfile] = []
                var aNoImages: [EntityProfile] = []
                var aWithGender: [EntityProfile] = []
                var aNoGender: [EntityProfile] = []
                var aWithHairColor: [EntityProfile] = []
                var aNoHairColor: [EntityProfile] = []
                var aWithBirthYear: [EntityProfile] = []
                var aNoBirthYear: [EntityProfile] = []
                var aWithCountry: [EntityProfile] = []
                var aNoCountry: [EntityProfile] = []
                var aComplete: [EntityProfile] = []

                var aTotalPhotos = 0
                var actorPhotoCounts: [String: Int] = [:]
                var allActorTagsSet = Set<String>()

                let allProfileFiles = (try? FileManager.default.contentsOfDirectory(atPath: profileDir.path)) ?? []
                let jpgFiles = allProfileFiles.filter { $0.hasSuffix(".jpg") }

                for profile in actorEntities {
                    if !profile.tags.isEmpty {
                        aWithTags.append(profile)
                        for tag in profile.tags {
                            allActorTagsSet.insert(tag)
                            tagUsageCounts[tag, default: 0] += 1
                        }
                    } else {
                        aNoTags.append(profile)
                    }

                    let safeId = profile.id.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
                    let actorPhotos = jpgFiles.filter { $0 == "\(safeId).jpg" || $0.hasPrefix("\(safeId)_") }.count
                    let hasPhoto = actorPhotos > 0 || profile.photoUrl != nil

                    if actorPhotos > 0 {
                        aWithImages.append(profile)
                        aTotalPhotos += actorPhotos

                        let displayName = profile.name
                        actorPhotoCounts[displayName] = actorPhotos
                    } else {
                        aNoImages.append(profile)
                    }

                    let hasGender = !(profile.gender ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    if hasGender { aWithGender.append(profile) } else { aNoGender.append(profile) }

                    let hasHairColor = !(profile.hairColor ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    if hasHairColor { aWithHairColor.append(profile) } else { aNoHairColor.append(profile) }

                    let hasBirthYear = profile.birthYear != nil
                    if hasBirthYear { aWithBirthYear.append(profile) } else { aNoBirthYear.append(profile) }

                    let hasCountry = !(profile.countryOfOrigin ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    if hasCountry { aWithCountry.append(profile) } else { aNoCountry.append(profile) }

                    if hasPhoto && hasGender && hasHairColor && hasBirthYear && hasCountry {
                        aComplete.append(profile)
                    }
                }

                let top5Actors = actorPhotoCounts.map { TopActor(name: $0.key, count: $0.value) }
                                           .sorted { $0.count > $1.count }
                                           .prefix(5)
                                           
                let top5Tags = tagUsageCounts.map { TopTag(name: $0.key, count: $0.value) }
                                           .sorted { $0.count > $1.count }
                                           .prefix(5)
                
                let finalTotalFilms = assets.count
                let finalTotalActors = actorEntities.count
                
                let finalAllTags = allFilmTagsSet.union(allActorTagsSet)
                let finalSharedTags = allFilmTagsSet.intersection(allActorTagsSet)
                
                let finalTop5Actors = Array(top5Actors)
                let finalTop5Tags = Array(top5Tags)
                let finalTotalPhotos = aTotalPhotos
                let finalFilmTagsCount = allFilmTagsSet.count
                let finalActorTagsCount = allActorTagsSet.count
                
                await MainActor.run { [fWithTags, fNoTags, fWithActors, fNoActors, fWithThumbs, fNoThumbs, aWithTags, aNoTags, aWithImages, aNoImages, aWithGender, aNoGender, aWithHairColor, aNoHairColor, aWithBirthYear, aNoBirthYear, aWithCountry, aNoCountry, aComplete] in
                    self.totalFilms = finalTotalFilms
                    self.filmsWithTags = fWithTags
                    self.untaggedFilms = fNoTags
                    self.filmsWithActors = fWithActors
                    self.filmsWithoutActors = fNoActors
                    self.filmsWithThumbnails = fWithThumbs
                    self.filmsWithoutThumbnails = fNoThumbs

                    self.totalActors = finalTotalActors
                    self.actorsWithTags = aWithTags
                    self.actorsWithoutTags = aNoTags
                    self.actorsWithImages = aWithImages
                    self.actorsWithoutImages = aNoImages
                    self.actorsWithGender = aWithGender
                    self.actorsWithoutGender = aNoGender
                    self.actorsWithHairColor = aWithHairColor
                    self.actorsWithoutHairColor = aNoHairColor
                    self.actorsWithBirthYear = aWithBirthYear
                    self.actorsWithoutBirthYear = aNoBirthYear
                    self.actorsWithCountry = aWithCountry
                    self.actorsWithoutCountry = aNoCountry
                    self.actorsComplete = aComplete

                    self.totalActorPhotos = finalTotalPhotos
                    self.topActorsByPhotos = finalTop5Actors
                    
                    self.totalTags = finalAllTags.count
                    self.filmTagsCount = finalFilmTagsCount
                    self.actorTagsCount = finalActorTagsCount
                    self.sharedTagsCount = finalSharedTags.count
                    self.topTagsByUsage = finalTop5Tags
                    
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }.value
    }
}
