import SwiftUI
import LibraryCore

struct BatchEntityProfileEditorView: View {
    let libraryURL: URL?
    let entityIds: [String]
    
    let onSave: ([EntityProfile]) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var newGender: String = ""
    @State private var newHairColor: String = ""
    @State private var newCountryOfOrigin: String = ""
    @State private var tagsToAdd: [String] = []
    
    // Tag Entry State
    @State private var isShowingTagEntry = false
    @State private var newTagValue = ""
    
    // Gender Entry State
    @State private var isShowingGenderSuggestions = false
    
    @State private var isSaving = false
    
    @State private var allUniqueTags: [String] = []
    @State private var allUniqueGenders: [String] = []
    
    private var filteredTagSuggestions: [String] {
        if newTagValue.isEmpty { return [] }
        return allUniqueTags.filter { $0.localizedCaseInsensitiveContains(newTagValue) && !tagsToAdd.contains($0) }.prefix(10).map { $0 }
    }
    
    private var filteredGenderSuggestions: [String] {
        if newGender.isEmpty { return allUniqueGenders }
        return allUniqueGenders.filter { $0.localizedCaseInsensitiveContains(newGender) }
    }
    
    var body: some View {
        Form {
                Section(header: Text("Batch Edit \(entityIds.count) Actors")) {
                    Text("These values will overwrite existing values. Leave blank to keep existing values.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading) {
                        TextField("New Gender", text: $newGender)
                            .onChange(of: newGender) { _, _ in isShowingGenderSuggestions = true }
                        
                        if isShowingGenderSuggestions && !filteredGenderSuggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(filteredGenderSuggestions, id: \.self) { suggestion in
                                        Button(action: {
                                            newGender = suggestion
                                            isShowingGenderSuggestions = false
                                        }) {
                                            Text(suggestion)
                                                .font(.caption)
                                                .padding(6)
                                                .background(Color.secondary.opacity(0.2))
                                                .cornerRadius(6)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    
                    TextField("New Hair Color", text: $newHairColor)
                    
                    TextField("New Country of Origin", text: $newCountryOfOrigin)
                        .onChange(of: newCountryOfOrigin) { _, newValue in
                            let flag = CountryFlagHelper.flagEmoji(for: newValue)
                            if !flag.isEmpty && !newValue.contains(flag) {
                                newCountryOfOrigin = "\(newValue.trimmingCharacters(in: .whitespaces)) \(flag)"
                            }
                        }
                }
                
                Section(header: Text("Add Tags")) {
                    Text("These tags will be appended to the existing tags for all selected actors.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Button {
                                newTagValue = ""
                                isShowingTagEntry = true
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                        
                        if tagsToAdd.isEmpty {
                            Text("No tags to add").font(.caption).foregroundColor(.secondary)
                        } else {
                            FlowLayout(spacing: 8) {
                                ForEach(tagsToAdd, id: \.self) { tag in
                                    TagBubble(
                                        label: tag,
                                        color: .blue,
                                        onPivot: nil,
                                        onEdit: nil,
                                        onDelete: {
                                            if let idx = tagsToAdd.firstIndex(of: tag) {
                                                tagsToAdd.remove(at: idx)
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
            .navigationTitle("Batch Edit Profiles")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save All") {
                        saveBatch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
            }
        .popover(isPresented: $isShowingTagEntry) {
            tagEntryPopover
        }
        .onAppear {
            guard let url = libraryURL else { return }
            do {
                let store = try LibraryStore(at: url)
                let profiles = try store.fetchAllEntityProfiles()
                let allTagsSet = Set(profiles.flatMap { $0.tags })
                allUniqueTags = Array(allTagsSet).sorted()
                
                let gendersSet = Set(profiles.compactMap { $0.gender }.flatMap { $0.components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                allUniqueGenders = Array(gendersSet).sorted()
            } catch {
                print("Failed to fetch unique tags/genders: \(error)")
            }
        }
    }
    
    private var tagEntryPopover: some View {
        VStack(spacing: 12) {
            Text("Add Tag")
                .font(.headline)
            TextField("Tag Name...", text: $newTagValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveTag() }
                
            if !filteredTagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(filteredTagSuggestions, id: \.self) { suggestion in
                            Button(action: {
                                newTagValue = suggestion
                                saveTag()
                            }) {
                                Text(suggestion)
                                    .font(.caption)
                                    .padding(6)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button("Save") { saveTag() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        #if os(macOS)
        .frame(width: 300, height: 160, alignment: .top)
        #else
        .frame(minWidth: 250, maxWidth: 350)
        #endif
    }
    
    private func saveTag() {
        let val = newTagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else {
            isShowingTagEntry = false
            return
        }
        let normalized = TagNormalizer.normalize(tagValue: val)
        if !tagsToAdd.contains(normalized) {
            tagsToAdd.append(normalized)
        }
        tagsToAdd.sort()
        isShowingTagEntry = false
    }
    
    private func saveBatch() {
        isSaving = true
        guard let url = libraryURL else { return }
        
        let finalGender = newGender.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalHair = newHairColor.trimmingCharacters(in: .whitespacesAndNewlines)
        var finalCountry = newCountryOfOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !finalCountry.isEmpty {
            let flag = CountryFlagHelper.flagEmoji(for: finalCountry)
            if !flag.isEmpty && !finalCountry.contains(flag) {
                finalCountry = "\(finalCountry) \(flag)"
            }
        }
        
        Task {
            do {
                let store = try LibraryStore(at: url)
                var updatedProfiles: [EntityProfile] = []
                
                for id in entityIds {
                    // "No profile row yet" and "the fetch failed" must be
                    // treated differently: creating a fresh profile is right
                    // for the former, but doing it after a failed fetch
                    // overwrites the actor's existing bio/photos/AKAs with a
                    // blank record. A throwing fetch aborts the whole batch
                    // (via the outer catch) instead of wiping anything.
                    var profile = try store.fetchEntityProfile(for: id) ?? EntityProfile(id: id)

                    if !finalGender.isEmpty { profile.gender = finalGender }
                    if !finalHair.isEmpty { profile.hairColor = finalHair }
                    if !finalCountry.isEmpty { profile.countryOfOrigin = finalCountry }
                    
                    for tag in tagsToAdd {
                        if !profile.tags.contains(tag) {
                            profile.tags.append(tag)
                        }
                    }
                    profile.tags.sort()
                    
                    try store.saveEntityProfile(profile)
                    updatedProfiles.append(profile)
                }
                
                await MainActor.run {
                    onSave(updatedProfiles)
                    dismiss()
                }
            } catch {
                print("Failed batch save: \(error)")
                AppErrorReporter.report("Couldn't save the actor profiles: \(error.localizedDescription)")
                await MainActor.run { isSaving = false }
            }
        }
    }
}
