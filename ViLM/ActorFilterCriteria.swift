import Foundation

struct ActorFilterCriteria: Equatable {
    enum Logic: String, CaseIterable, Equatable { case and = "AND", or = "OR" }

    var showMissingPhotosOnly: Bool = false
    var gender: String = ""
    var hairColor: String = ""
    var country: String = ""
    
    var tagsLogic: Logic = .and
    var selectedTags: Set<String> = []
    
    var isEmpty: Bool {
        !showMissingPhotosOnly && gender.isEmpty && hairColor.isEmpty && country.isEmpty && selectedTags.isEmpty
    }
}
