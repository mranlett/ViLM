import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/ContentView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

var offset = 0
var linesCopy = lines
for (i, line) in linesCopy.enumerated() {
    if line.contains("ActorGridView(") {
        var endIdx = i
        while !linesCopy[endIdx].contains(")") { endIdx += 1 }
        let j = endIdx - 1
        if linesCopy[j].contains("libraryURL: selectedLibraryURL") {
            lines.insert(contentsOf: [
                "                            pendingFilter: $pendingActorFilter,",
                "                            pendingSort: $pendingActorSort,",
                "                            pendingSortAscending: $pendingActorSortAscending,"
            ], at: j + offset + 1)
            lines[j + offset] = lines[j + offset] + ","
            offset += 3
        }
    }
    
    if line.contains("AssetsGridView(") {
        var endIdx = i
        while !linesCopy[endIdx].contains(")") { endIdx += 1 }
        let j = endIdx - 1
        if linesCopy[j].contains("filteredAssetContext: $filteredAssetContext") {
            lines.insert(contentsOf: [
                "                            pendingFilter: $pendingAssetFilter,",
                "                            pendingSort: $pendingAssetSort,",
                "                            pendingSortAscending: $pendingAssetSortAscending,"
            ], at: j + offset + 1)
            lines[j + offset] = lines[j + offset] + ","
            offset += 3
        }
    }
}

if let idx = lines.lastIndex(where: { $0.contains("filteredAssetContext: $filteredAssetContext") }) {
    if lines[idx-1].contains("refreshID:") {
        lines.insert(contentsOf: [
            "            pendingFilter: .constant(nil),",
            "            pendingSort: .constant(nil),",
            "            pendingSortAscending: .constant(nil)"
        ], at: idx + 1)
        lines[idx] = lines[idx] + ","
    }
}

for i in 0..<lines.count {
    if lines[i].trimmingCharacters(in: .whitespaces).hasSuffix(",") {
        if i+1 < lines.count && lines[i+1].trimmingCharacters(in: .whitespaces).hasPrefix(")") {
            lines[i] = String(lines[i].dropLast())
        }
    }
}

try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
