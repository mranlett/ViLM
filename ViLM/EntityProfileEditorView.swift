import SwiftUI
import LibraryCore
import CryptoKit

struct EntityProfileEditorView: View {
    let libraryURL: URL?
    let entityId: String
    let initialProfile: EntityProfile?
    let onSave: (EntityProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var bio: String = ""
    @State private var photoUrl: String = ""
    @State private var homePage: String = ""
    @State private var gender: String = ""
    @State private var hairColor: String = ""
    @State private var birthYearString: String = ""
    @State private var countryOfOrigin: String = ""
    
    @State private var tags: [String] = []
    @State private var galleryUrls: [String] = []
    @State private var newGalleryUrl: String = ""
    
    // Tag Entry State
    @State private var isShowingTagEntry = false
    @State private var newTagValue = ""
    @State private var editingTagValue: String? = nil
    
    enum Field: Hashable {
        case newGalleryUrl, homePage, gender, hairColor, birthYear, country, bio
    }
    @FocusState private var focusedField: Field?
    
    init(libraryURL: URL?, entityId: String, profile: EntityProfile?, onSave: @escaping (EntityProfile) -> Void) {
        self.libraryURL = libraryURL
        self.entityId = entityId
        self.initialProfile = profile
        self.onSave = onSave
        _bio = State(initialValue: profile?.bio ?? "")
        _photoUrl = State(initialValue: profile?.photoUrl ?? "")
        _homePage = State(initialValue: profile?.homePage ?? "")
        _gender = State(initialValue: profile?.gender ?? "")
        _hairColor = State(initialValue: profile?.hairColor ?? "")
        _birthYearString = State(initialValue: profile?.birthYear.map { String($0) } ?? "")
        _countryOfOrigin = State(initialValue: profile?.countryOfOrigin ?? "")
        _tags = State(initialValue: profile?.tags ?? [])
        _galleryUrls = State(initialValue: profile?.galleryUrls ?? [])
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Photo Gallery").font(.headline)) {
                    HStack {
                        TextField("https://...", text: $newGalleryUrl)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .focused($focusedField, equals: .newGalleryUrl)
                            .submitLabel(.done)
                            .onSubmit {
                                let url = newGalleryUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !url.isEmpty && !galleryUrls.contains(url) {
                                    galleryUrls.append(url)
                                    if photoUrl.isEmpty {
                                        photoUrl = url
                                    }
                                }
                                newGalleryUrl = ""
                                focusedField = .newGalleryUrl // keep focus
                            }
                        Button("Add") {
                            let url = newGalleryUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !url.isEmpty && !galleryUrls.contains(url) {
                                galleryUrls.append(url)
                                if photoUrl.isEmpty {
                                    photoUrl = url
                                }
                            }
                            newGalleryUrl = ""
                        }
                        .disabled(newGalleryUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    
                    if !galleryUrls.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(galleryUrls, id: \.self) { url in
                                    VStack {
                                        ProfileImageView(libraryURL: libraryURL, entityId: entityId, photoUrl: url, isGallery: url != photoUrl) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            ZStack {
                                                Rectangle().fill(Color.secondary.opacity(0.2))
                                                ProgressView()
                                            }
                                        }
                                        .frame(width: 100, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(photoUrl == url ? Color.accentColor : Color.clear, lineWidth: 3)
                                        )
                                        
                                        HStack {
                                            Button(action: {
                                                photoUrl = url
                                            }) {
                                                Image(systemName: photoUrl == url ? "star.fill" : "star")
                                                    .foregroundColor(photoUrl == url ? .yellow : .secondary)
                                            }
                                            .buttonStyle(.plain)
                                            
                                            Spacer()
                                            
                                            Button(action: {
                                                if let idx = galleryUrls.firstIndex(of: url) {
                                                    galleryUrls.remove(at: idx)
                                                }
                                                if photoUrl == url {
                                                    photoUrl = galleryUrls.first ?? ""
                                                }
                                            }) {
                                                Image(systemName: "trash")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .frame(width: 100)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
                
                Section(header: Text("Details").font(.headline)) {
                    TextField("Home Page URL", text: $homePage)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focusedField, equals: .homePage)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .gender }
                    
                    TextField("Gender", text: $gender)
                        .focused($focusedField, equals: .gender)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .hairColor }
                        
                    TextField("Hair Color", text: $hairColor)
                        .focused($focusedField, equals: .hairColor)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .birthYear }
                    
                    HStack {
                        Text("Birth Year")
                        Spacer()
                        TextField("YYYY", text: $birthYearString)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .birthYear)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .country }
                    }
                    
                    TextField("Country of Origin", text: $countryOfOrigin)
                        .focused($focusedField, equals: .country)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .bio }
                    
                    Text("Bio")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $bio)
                        .frame(minHeight: 100)
                        .focused($focusedField, equals: .bio)
                }
                
                Section(header: Text("Tags").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Button {
                                newTagValue = ""
                                editingTagValue = nil
                                isShowingTagEntry = true
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                        
                        if tags.isEmpty {
                            Text("No tags").font(.caption).foregroundColor(.secondary)
                        } else {
                            FlowLayout(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    TagBubble(
                                        label: tag,
                                        color: .blue,
                                        onPivot: nil,
                                        onEdit: {
                                            newTagValue = tag
                                            editingTagValue = tag
                                            isShowingTagEntry = true
                                        },
                                        onDelete: {
                                            if let idx = tags.firstIndex(of: tag) {
                                                tags.remove(at: idx)
                                            }
                                        },
                                        navRoute: nil
                                    )
                                }
                            }
                        }
                    }
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
                        
                        let profile = EntityProfile(
                            id: entityId,
                            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bio,
                            photoUrl: finalPhotoUrl.isEmpty ? nil : finalPhotoUrl,
                            homePage: homePage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : homePage,
                            gender: gender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : gender,
                            hairColor: hairColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hairColor,
                            birthYear: Int(birthYearString.trimmingCharacters(in: .whitespacesAndNewlines)),
                            countryOfOrigin: countryOfOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : countryOfOrigin,
                            tags: tags,
                            galleryUrls: galleryUrls
                        )
                        
                        if !finalPhotoUrl.isEmpty {
                            downloadProfileImage(urlString: finalPhotoUrl, isGallery: false)
                        }
                        for url in galleryUrls {
                            if url != finalPhotoUrl {
                                downloadProfileImage(urlString: url, isGallery: true)
                            }
                        }
                        
                        onSave(profile)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 650)
        .popover(isPresented: $isShowingTagEntry) {
            tagEntryPopover
        }
    }
    
    private var tagEntryPopover: some View {
        VStack(spacing: 12) {
            Text(editingTagValue == nil ? "Add Tag" : "Edit Tag")
                .font(.headline)
            TextField("Tag Name...", text: $newTagValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveTag() }

            Button("Save") { saveTag() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        #if os(macOS)
        .frame(width: 250, height: 120, alignment: .top)
        #else
        .frame(minWidth: 200, maxWidth: 300)
        #endif
    }
    
    private func saveTag() {
        let val = newTagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else {
            isShowingTagEntry = false
            return
        }
        let normalized = TagNormalizer.normalize(tagValue: val)
        
        if let editing = editingTagValue {
            if let idx = tags.firstIndex(of: editing) {
                tags[idx] = normalized
            }
        } else {
            if !tags.contains(normalized) {
                tags.append(normalized)
            }
        }
        tags.sort()
        isShowingTagEntry = false
    }
    
    private func downloadProfileImage(urlString: String, isGallery: Bool) {
        guard let url = URL(string: urlString), let libraryURL = libraryURL else { return }
        let safeId = entityId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        
        let fileName: String
        if isGallery {
            let hashData = SHA256.hash(data: Data(urlString.utf8))
            let hashString = hashData.compactMap { String(format: "%02x", $0) }.joined()
            fileName = "\(safeId)_\(hashString).jpg"
        } else {
            fileName = "\(safeId).jpg"
        }
        
        let fileURL = profilesDir.appendingPathComponent(fileName)
        
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
