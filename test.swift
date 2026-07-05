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
    
    var actorTagsLogic: Logic = .and
    var selectedActorTags: Set<String> = []
    
    var actorHairColorsLogic: Logic = .or
    var selectedActorHairColors: Set<String> = []
    
    var actorGendersLogic: Logic = .or
    var selectedActorGenders: Set<String> = []
    var actorCountriesLogic: Logic = .or
    var selectedActorCountries: Set<String> = []
}
