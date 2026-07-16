// TagSuggester.swift
// Guesses candidate tags from a video's filename (delimiter splitting plus
// known-token matching) for the Video Details tag suggestions.

import Foundation

public struct TagSuggester {
    public static func suggestions(for fileName: String) -> [String] {
        // Strip the file extension
        let fileNameWithoutExtension = (fileName as NSString).deletingPathExtension
        
        // Split by " - "
        let dashComponents = fileNameWithoutExtension.components(separatedBy: " - ")
        
        var results: [String] = []
        
        for component in dashComponents {
            // Case-insensitive split by " and "
            // We can use a regex to split by " and " with spaces around it, ignoring case.
            // A simple approach without regex: replace " and " with a specific token, then split.
            // Or better, just use regex split.
            // Or better, just use regex split.

            // Let's use string replacement or regex.
            
            // For simplicity, lowercase comparison is hard without regex split.
            // Let's do regex split for " and " case insensitive.
            
            do {
                let regex = try NSRegularExpression(pattern: "(?i)\\s+and\\s+|,\\s*", options: [])
                let range = NSRange(location: 0, length: component.utf16.count)
                let replaced = regex.stringByReplacingMatches(in: component, options: [], range: range, withTemplate: "|||")
                
                let subComponents = replaced.components(separatedBy: "|||")
                for sub in subComponents {
                    let trimmed = sub.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        results.append(trimmed)
                    }
                }
            } catch {
                // Fallback
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    results.append(trimmed)
                }
            }
        }
        
        // Remove duplicates while preserving order
        var uniqueResults: [String] = []
        var seen: Set<String> = []
        for res in results {
            if !seen.contains(res) {
                seen.insert(res)
                uniqueResults.append(res)
            }
        }
        
        return uniqueResults
    }
}
