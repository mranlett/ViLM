import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/ContentView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

let linesToFix = [75, 85, 105, 130, 150, 173, 183, 203, 736]
for lineNum in linesToFix {
    let idx = lineNum - 1
    if !lines[idx].hasSuffix(",") {
        lines[idx] = lines[idx] + ","
    }
}

try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
