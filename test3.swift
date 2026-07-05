import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/AssetGridView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

var output: [String] = []
for line in lines {
    if line.contains("if first == .allAssets {") {
        output.append("                if case .smartCollection(let id, _) = first {")
        output.append("                    loadSmartCollection(id: id)")
        output.append("                } else if first == .allAssets {")
    } else if line.contains("// MARK: - Sub-Expressions (Helpers to fix compiler error)") {
        output.append(line)
        output.append("    private func loadSmartCollection(id: String) {")
        output.append("        if let url = libraryURL {")
        output.append("            let store = LibraryStore(baseURL: url)")
        output.append("            let smartCollections = store.fetchAllSmartCollections()")
        output.append("            if let sc = smartCollections.first(where: { $0.id == id }) {")
        output.append("                if let data = sc.filterCriteria.data(using: .utf8),")
        output.append("                   let criteria = try? JSONDecoder().decode(AssetFilterCriteria.self, from: data) {")
        output.append("                    self.filterCriteria = criteria")
        output.append("                }")
        output.append("                if let sortRaw = sc.sortOption, let sort = SortOption(rawValue: sortRaw) {")
        output.append("                    self.sortOption = sort")
        output.append("                }")
        output.append("                self.sortAscending = sc.sortAscending")
        output.append("            }")
        output.append("        }")
        output.append("    }")
        output.append("")
    } else {
        output.append(line)
    }
}

try output.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
