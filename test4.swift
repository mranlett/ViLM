import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/AssetGridView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

var output: [String] = []
for line in lines {
    if line.contains("if !hasLoadedDefaults {") {
        output.append("            if let first = sidebarSelection.first, case .smartCollection(let id, _) = first {")
        output.append("                loadSmartCollection(id: id)")
        output.append("            }")
        output.append("            if let first = sidebarSelection.first, case .allAssets = first {")
        output.append("                filterCriteria = AssetFilterCriteria()")
        output.append("            }")
    }
    output.append(line)
}

try output.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
