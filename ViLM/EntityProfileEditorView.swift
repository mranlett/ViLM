import SwiftUI
import LibraryCore

struct EntityProfileEditorView: View {
    let entityId: String
    let initialProfile: EntityProfile?
    let onSave: (EntityProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var bio: String = ""
    @State private var photoUrl: String = ""
    @State private var homePage: String = ""
    
    init(entityId: String, profile: EntityProfile?, onSave: @escaping (EntityProfile) -> Void) {
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
                    
                    if let url = URL(string: photoUrl), !photoUrl.isEmpty {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit().frame(maxHeight: 150)
                        } placeholder: {
                            ProgressView()
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
                        let profile = EntityProfile(
                            id: entityId,
                            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bio,
                            photoUrl: photoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : photoUrl,
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
}
