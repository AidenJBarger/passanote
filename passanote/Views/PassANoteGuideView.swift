import SwiftUI

/// Quiet onboarding copy for an empty room — the live peer status lives in
/// the navigation bar above the feed.
struct PassANoteGuideView: View {
    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(PassANoteFeatureList.items) { feature in
                    PassANoteFeatureRow(feature: feature)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
