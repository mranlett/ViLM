import SwiftUI
import LibraryCore

// MARK: - Circular Ring Chart
struct StatRingView: View {
    let percentage: Double
    let label: String
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                
                Circle()
                    .trim(from: 0, to: CGFloat(percentage))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                Text("\(Int(percentage * 100))%")
                    .font(.system(size: 17, weight: .bold))
            }
            .frame(width: 64, height: 64)
            
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(PlatformSystemBackground))
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
    }
}

// MARK: - Progress Bar Row
struct StatProgressBarRow: View {
    let title: String
    let value: Int
    let missing: Int
    let valueLabel: String
    let missingLabel: String
    var showChevron: Bool = true
    var barColor: Color = .green
    
    private var total: Int { value + missing }
    private var percentage: Double { total > 0 ? Double(value) / Double(total) : 0 }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundColor(Color.secondary.opacity(0.4))
                }
            }
            
            Text("\(value) \(valueLabel) · \(missing) \(missingLabel)")
                .font(.system(size: 12))
                .foregroundColor(.primary)
            
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    if value > 0 {
                        Rectangle()
                            .fill(barColor)
                            .frame(width: max(0, geometry.size.width * CGFloat(percentage) - 1))
                    }
                    if missing > 0 {
                        Rectangle()
                            .fill(barColor.opacity(0.2))
                            .frame(width: max(0, geometry.size.width * CGFloat(1 - percentage) - 1))
                    }
                }
                .cornerRadius(2)
            }
            .frame(height: 4)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Bar Chart Row (Top Actors/Tags)
struct StatBarChartRow: View {
    let index: Int?
    let title: String
    let count: Int
    let maxCount: Int
    var barColor: Color = .blue
    
    private var percentage: Double { maxCount > 0 ? Double(count) / Double(maxCount) : 0 }
    
    var body: some View {
        HStack(spacing: 12) {
            if let index = index {
                Text("\(index)")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .frame(width: 20, alignment: .leading)
            }
            
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            
            Spacer()
            
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    if count > 0 {
                        Rectangle()
                            .fill(barColor)
                            .frame(width: max(0, geometry.size.width * CGFloat(percentage) - 1))
                    }
                    if maxCount - count > 0 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: max(0, geometry.size.width * CGFloat(1 - percentage) - 1))
                    }
                }
                .cornerRadius(2)
            }
            .frame(width: 80, height: 4)
            
            Text("\(count)")
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Drill-Down Views
struct UntaggedFilmsView: View {
    let films: [Asset]
    var onSelect: ((Asset.ID) -> Void)?
    
    var body: some View {
        List {
            ForEach(films) { film in
                HStack {
                    Text(film.videoName ?? film.fileName)
                        .font(.system(size: 17))
                    Spacer()
                    Button("Add Tags") {
                        onSelect?(film.id)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(16)
                }
            }
        }
        .navigationTitle("Untagged Films")
    }
}

struct ActorsWithoutTagsView: View {
    let profiles: [EntityProfile]
    var onSelect: ((String) -> Void)?
    
    var body: some View {
        List {
            ForEach(profiles) { profile in
                // The selection handler expects a bare actor name; the stored
                // id carries an "actor:" prefix that must be stripped.
                let actorName = profile.id.hasPrefix("actor:") ? String(profile.id.dropFirst(6)) : profile.id
                HStack {
                    Text(actorName)
                        .font(.system(size: 17))
                    Spacer()
                    Button("Add Tags") {
                        onSelect?(actorName)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(16)
                }
            }
        }
        .navigationTitle("Actors Without Tags")
    }
}

struct ActorTagsUsageView: View {
    let tags: [String]
    
    var body: some View {
        List {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 17))
            }
        }
        .navigationTitle("Actor Tags")
    }
}
