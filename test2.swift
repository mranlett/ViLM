import Foundation

var url = URL(fileURLWithPath: "/Users/mattranlett/Development/ViLM/ViLM/ViLM/FilterBuilderView.swift")
var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)

var output: [String] = []
var inGroup = false
for line in lines {
    if line.contains("DisclosureGroup(\"Actor Countries\"") {
        inGroup = true
        output.append("// " + line)
    } else if inGroup {
        output.append("// " + line)
        if line.contains("}") && !line.contains("{") {
            inGroup = false
        }
    } else {
        output.append(line)
    }
}

try output.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
