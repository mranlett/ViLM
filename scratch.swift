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
    
    public init() {}
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reviewStatus = try container.decodeIfPresent(ReviewStatusFilter.self, forKey: .reviewStatus) ?? .all
        minRating = try container.decodeIfPresent(Int.self, forKey: .minRating)
        actorsLogic = try container.decodeIfPresent(Logic.self, forKey: .actorsLogic) ?? .and
        selectedActors = try container.decodeIfPresent(Set<String>.self, forKey: .selectedActors) ?? []
        tagsLogic = try container.decodeIfPresent(Logic.self, forKey: .tagsLogic) ?? .and
        selectedTags = try container.decodeIfPresent(Set<String>.self, forKey: .selectedTags) ?? []
        studiosLogic = try container.decodeIfPresent(Logic.self, forKey: .studiosLogic) ?? .and
        selectedStudios = try container.decodeIfPresent(Set<String>.self, forKey: .selectedStudios) ?? []
        actorTagsLogic = try container.decodeIfPresent(Logic.self, forKey: .actorTagsLogic) ?? .and
        selectedActorTags = try container.decodeIfPresent(Set<String>.self, forKey: .selectedActorTags) ?? []
        actorHairColorsLogic = try container.decodeIfPresent(Logic.self, forKey: .actorHairColorsLogic) ?? .or
        selectedActorHairColors = try container.decodeIfPresent(Set<String>.self, forKey: .selectedActorHairColors) ?? []
        actorGendersLogic = try container.decodeIfPresent(Logic.self, forKey: .actorGendersLogic) ?? .or
        selectedActorGenders = try container.decodeIfPresent(Set<String>.self, forKey: .selectedActorGenders) ?? []
        actorCountriesLogic = try container.decodeIfPresent(Logic.self, forKey: .actorCountriesLogic) ?? .or
        selectedActorCountries = try container.decodeIfPresent(Set<String>.self, forKey: .selectedActorCountries) ?? []
    }
}
let json = """
{"selectedStudios":[],"actorHairColorsLogic":"OR","actorsLogic":"AND","selectedActorGenders":[],"selectedActorHairColors":[],"selectedActorTags":[],"tagsLogic":"AND","actorGendersLogic":"OR","reviewStatus":"All","studiosLogic":"AND","selectedTags":["Test"],"actorTagsLogic":"AND","selectedActors":[]}
"""

let data = json.data(using: .utf8)!
do {
    let result = try JSONDecoder().decode(AssetFilterCriteria.self, from: data)
    print("Decoded success! \(result.selectedTags)")
} catch {
    print("Error: \(error)")
}
