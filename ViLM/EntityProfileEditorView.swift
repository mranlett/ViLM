import SwiftUI
import LibraryCore

struct EntityProfileEditorView: View {
    let libraryURL: URL?
    let entityId: String
    let initialProfile: EntityProfile?
    let onSave: (EntityProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var bio: String = ""
    @State private var photoUrl: String = ""
    @State private var homePage: String = ""
    
    init(libraryURL: URL?, entityId: String, profile: EntityProfile?, onSave: @escaping (EntityProfile) -> Void) {
        self.libraryURL = libraryURL
        self.entityId = entityId
        self.initialProfile = profile
        self.onSave = onSave
        _bio = State(initialValue: profile?.bio ?? "")
        _photoUrl = State(initialValue: profile?.photoUrl ?? "")
        _homePage = State(initialValue: profile?.homePage ?? "")
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Photo URL").font(.headline)) {
                    TextField("https://...", text: $photoUrl)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    
                    ProfileImageView(libraryURL: libraryURL, entityId: entityId, photoUrl: photoUrl.isEmpty ? nil : photoUrl) { image in
                        image.resizable().scaledToFit().frame(maxHeight: 150)
                    } placeholder: {
                        if !photoUrl.isEmpty {
                            ProgressView()
                        } else {
                            Image(systemName: "person.crop.square")
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 150)
                                .foregroundColor(.secondary.opacity(0.3))
                        }
                    }
                }
                
                Section(header: Text("Details").font(.headline)) {
                    TextField("Home Page URL", text: $homePage)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    
                    Text("Bio")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $bio)
                        .frame(minHeight: 100)
                }
            }
            .padding()
            .navigationTitle("Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let finalPhotoUrl = photoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !finalPhotoUrl.isEmpty {
                            downloadProfileImage(urlString: finalPhotoUrl)
                        }
                        
                        let profile = EntityProfile(
                            id: entityId,
                            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bio,
                            photoUrl: nil,

                            homePage: homePage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : homePage
                        )
                        onSave(profile)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }
    
    private func downloadProfileImage(urlString: String) {
        guard let url = URL(string: urlString), let libraryURL = libraryURL else { return }
        let safeId = entityId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        let fileURL = profilesDir.appendingPathComponent("\(safeId).jpg")
        
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true, attributes: nil)
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("Failed to forcefully download profile image for \(entityId): \(error)")
            }
        }
    }
}
