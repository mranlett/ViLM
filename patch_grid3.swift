import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/AssetGridView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

var output: [String] = []
for line in lines {
    output.append(line)
    if line.contains("if filterCriteria.selectedActorGenders.isDisjoint(with: allGendersInVideo) { return false }") {
        // We are inside the else block. The next two lines are } and }
    }
}

