import SwiftUI

enum PassANoteLinks {
    static let privacyPolicy = URL(string: "https://github.com/AidenJBarger/passanote/blob/main/PRIVACY_POLICY.md")!
}

// MARK: - Feature catalog

struct PassANoteFeature: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let details: [String]
}

enum PassANoteFeatureList {
    static let items: [PassANoteFeature] = [
        PassANoteFeature(icon: "lock.fill", text: "Securely message people nearby", details: []),
        PassANoteFeature(icon: "photo.on.rectangle.angled", text: "Share images and files", details: []),
        PassANoteFeature(icon: "clock.arrow.circlepath", text: "Messages disappear when you close the app", details: []),
        PassANoteFeature(
            icon: "at",
            text: "@mention people in the room",
            details: ["Get notified when someone mentions you"]
        ),
        PassANoteFeature(
            icon: "dot.radiowaves.left.and.right",
            text: "Completely offline",
            details: ["Uses Bluetooth", "More people, more range"]
        ),
    ]
}

struct PassANoteFeatureRow: View {
    let feature: PassANoteFeature
    var largeStyle = false

    var body: some View {
        VStack(alignment: .leading, spacing: largeStyle ? 8 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: feature.icon)
                    .font(largeStyle ? Theme.metaFont.weight(.semibold) : .caption2.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: largeStyle ? 20 : 16, alignment: .center)

                Text(feature.text)
                    .font(largeStyle ? Theme.secondaryFont : Theme.metaFont)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(feature.details, id: \.self) { detail in
                Text(detail)
                    .font(largeStyle ? Theme.metaFont : .caption2)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.leading, largeStyle ? 30 : 26)
            }
        }
    }
}

// MARK: - Features

/// Full feature list from the empty-room guide, laid out like other list screens.
struct FeaturesView: View {
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(PassANoteFeatureList.items) { feature in
                        PassANoteFeatureRow(feature: feature, largeStyle: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                .padding(.horizontal, Theme.screenHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
        .paperCanvas()
        .tint(Theme.note)
        .navigationTitle("Features")
        .navigationBarTitleDisplayMode(.inline)
    }
}

