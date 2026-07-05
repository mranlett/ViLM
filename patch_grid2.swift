import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/AssetGridView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

var output: [String] = []
var skip = false
var i = 0
while i < lines.count {
    let line = lines[i]
    if line.contains(".onChange(of: sidebarSelection)") {
        skip = true
    } else if skip && line.trimmingCharacters(in: .whitespaces) == "}" && i < lines.count - 1 && lines[i+1].contains(".onAppear {") {
        skip = true
    } else if skip && line.trimmingCharacters(in: .whitespaces) == "}" && i < lines.count - 1 && lines[i+1].contains(".onChange(of: pendingFilter)") {
        skip = false
        i += 1
        continue
    }
    
    if line.contains("private func loadSmartCollection(id: String)") {
        skip = true
    } else if skip && line.contains("print(\"Failed to load smart collection") {
        // Skip next two lines (} and })
        i += 2
        skip = false
        i += 1
        continue
    }

    if line.contains("fetchSmartCollections") {
        output.append(line.replacingOccurrences(of: "fetchSmartCollections", with: "fetchAllSmartCollections"))
        i += 1
        continue
    }
    
    if !skip {
        output.append(line)
    }
    i += 1
}

try output.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
