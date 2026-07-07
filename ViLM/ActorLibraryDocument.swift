import SwiftUI
import UniformTypeIdentifiers
import LibraryCore

extension UTType {
    // A plain JSON container (see ActorLibraryPackage.swift) — no custom UTI
    // declaration needed since we don't need Finder/Files integration beyond
    // "it's a file with this extension."
    static var actorLibraryPackage: UTType { .json }
}

struct ActorLibraryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.actorLibraryPackage] }

    var export: ActorLibraryExport

    init(export: ActorLibraryExport) {
        self.export = export
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.export = try JSONDecoder().decode(ActorLibraryExport.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(export)
        return .init(regularFileWithContents: data)
    }
}
