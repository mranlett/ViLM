// AssetFilterCriteria.swift
// The advanced-filter model for the All Assets grid: review status, minimum
// rating, and AND/OR sets of actors, tags, studios, plus actor-metadata
// filters (tags, hair color, gender, country) that match videos through the
// actors appearing in them. Codable so a filter can be persisted as the
// default (AppStorage) or as a Smart Collection.

import Foundation

struct AssetFilterCriteria: Equatable, Codable {
    enum Logic: String, CaseIterable, Equatable, Codable { case and = "AND", or = "OR" }
    enum ReviewStatusFilter: String, CaseIterable, Equatable, Codable { case all = "All", reviewed = "Reviewed", unreviewed = "Unreviewed" }

    var reviewStatus: ReviewStatusFilter = .all
    var minRating: Int? = nil
    
    var actorsLogic: Logic = .and
    var selectedActors: Set<String> = []
    
    var tagsLogic: Logic = .and
    var selectedTags: Set<String> = []
    
    var studiosLogic: Logic = .and
    var selectedStudios: Set<String> = []
    
    // Actor metadata filters
    var actorTagsLogic: Logic = .and
    var selectedActorTags: Set<String> = []
    
    var actorHairColorsLogic: Logic = .or
    var selectedActorHairColors: Set<String> = []
    
    var actorGendersLogic: Logic = .or
    var selectedActorGenders: Set<String> = []
    var actorCountriesLogic: Logic = .or
    var selectedActorCountries: Set<String> = []
    
    var isEmpty: Bool {
        reviewStatus == .all && minRating == nil && 
        selectedActors.isEmpty && selectedTags.isEmpty && selectedStudios.isEmpty &&
        selectedActorTags.isEmpty && selectedActorHairColors.isEmpty && selectedActorGenders.isEmpty
    }
    
    public init() {}
}
