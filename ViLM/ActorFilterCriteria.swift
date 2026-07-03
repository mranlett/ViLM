import Foundation

struct ActorFilterCriteria: Equatable, Codable {
    enum Logic: String, CaseIterable, Equatable, Codable { case and = "AND", or = "OR" }

    enum SortOption: String, CaseIterable, Codable { case name = "Name", age = "Age", videoCount = "Video Count" }

    var showMissingPhotosOnly: Bool = false
    var showMissingGenderOnly: Bool = false
    
    var selectedGenders: Set<String> = []
    var hairColor: String = ""
    var country: String = ""
    
    var tagsLogic: Logic = .and
    var selectedTags: Set<String> = []
    
    var minVideos: Int? = nil
    var maxVideos: Int? = nil
    var minAge: Int? = nil
    var maxAge: Int? = nil
    
    var sortBy: SortOption = .name
    var sortDescending: Bool = false
    
    var isEmpty: Bool {
        !showMissingPhotosOnly && !showMissingGenderOnly && selectedGenders.isEmpty && hairColor.isEmpty && country.isEmpty && selectedTags.isEmpty && minVideos == nil && maxVideos == nil && minAge == nil && maxAge == nil
    }
    
    public init() {}
}
