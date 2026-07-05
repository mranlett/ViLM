import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/AssetGridView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

var output: [String] = []
for line in lines {
    output.append(line)
    if line.contains("var selectedActorGenders: Set<String> = []") {
        output.append("    var actorCountriesLogic: Logic = .or")
        output.append("    var selectedActorCountries: Set<String> = []")
    }
    
    if line.contains("case selectedActorGenders") {
        output.append("        case actorCountriesLogic")
        output.append("        case selectedActorCountries")
    }
    
    if line.contains("try container.encode(selectedActorGenders, forKey: .selectedActorGenders)") {
        output.append("        try container.encode(actorCountriesLogic, forKey: .actorCountriesLogic)")
        output.append("        try container.encode(selectedActorCountries, forKey: .selectedActorCountries)")
    }
    
    if line.contains("selectedActorGenders = try container.decodeIfPresent(Set<String>.self, forKey: .selectedActorGenders) ?? []") {
        output.append("        actorCountriesLogic = try container.decodeIfPresent(Logic.self, forKey: .actorCountriesLogic) ?? .or")
        output.append("        selectedActorCountries = try container.decodeIfPresent(Set<String>.self, forKey: .selectedActorCountries) ?? []")
    }
}

try output.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
