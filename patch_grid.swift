import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/AssetGridView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

var output: [String] = []
var skip = false
for i in 0..<lines.count {
    let line = lines[i]
    if line.contains(".onChange(of: sidebarSelection)") {
        skip = true
    } else if skip && line.trimmingCharacters(in: .whitespaces) == "}" && i < lines.count - 1 && lines[i+1].contains(".onAppear {") {
        // Just skipped onChange, now skip onAppear
        skip = true
        continue
    } else if skip && line.trimmingCharacters(in: .whitespaces) == "}" && i < lines.count - 1 && lines[i+1].contains(".onChange(of: pendingFilter)") {
        skip = false
        continue
    }
    
    if !skip {
        output.append(line)
    }
}

try output.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
