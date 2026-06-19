import SwiftUI
import simd

/// Design tokens from the Figma file: paper-blue canvas, sticky-note blue,
/// and dark-teal ink on note surfaces.
enum Theme {
    static let paper = Color("PaperBackground")

    /// Spline scene background — matches `PaperBackground` light/dark assets.
    static func paperBackgroundSIMD(for colorScheme: ColorScheme) -> SIMD4<Float> {
        switch colorScheme {
        case .dark:
            SIMD4(16 / 255, 24 / 255, 32 / 255, 1)
        default:
            SIMD4(0.937, 0.961, 0.988, 1)
        }
    }
    static let note = Color("NoteBlue")
    static let ink = Color("InkPrimary")
    static let inkSecondary = Color("InkSecondary")
    static let bubbleGray = Color("BubbleGray")
    static let bubbleText = Color("BubbleText")

    /// Dark blue for incoming chat bubbles — paired with the light note-blue for outgoing.
    static let bubbleIncoming = Color(red: 20 / 255, green: 70 / 255, blue: 110 / 255)
    static let bubbleIncomingBorder = Color(red: 70 / 255, green: 140 / 255, blue: 190 / 255)

    /// Fixed dark teal for text sitting on the blue sticky note — the note
    /// stays blue in dark mode, so this must not adapt.
    static let inkOnNote = Color(red: 14 / 255, green: 57 / 255, blue: 73 / 255)
    /// Hairline border on "my" bubbles (#A4CDF2 in the design).
    static let noteBorder = Color(red: 164 / 255, green: 205 / 255, blue: 242 / 255)

    static func bubbleForeground(isMine: Bool) -> Color {
        .white
    }

    static let bubbleShadowY: CGFloat = 2
    static let bubbleShadowRadius: CGFloat = 6

    /// Chat bubble with the design's asymmetric corners — the tight 4pt
    /// corner anchors the bubble toward its sender.
    // MARK: - Typography

    /// Peer names in lists and section emphasis.
    static let nameFont: Font = .body.weight(.semibold)
    /// Preview lines, bubble copy, and empty states — matches the room feed.
    static let secondaryFont: Font = .subheadline
    /// Timestamps and inline meta.
    static let metaFont: Font = .caption
    /// Section labels on list screens.
    static let sectionFont: Font = .subheadline.weight(.semibold)
    /// Inline nav titles (DM thread header).
    static let navTitleFont: Font = .title3.weight(.semibold)

    /// Room-style horizontal inset for scrollable screens.
    static let screenHorizontalPadding: CGFloat = 20
    /// Vertical padding inside tappable list rows.
    static let listRowVerticalPadding: CGFloat = 16
    /// Space between primary and secondary lines in a row.
    static let listRowLineSpacing: CGFloat = 6

    static func bubbleShape(isMine: Bool) -> UnevenRoundedRectangle {
        if isMine {
            UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 32,
                                   bottomTrailingRadius: 4, topTrailingRadius: 32,
                                   style: .continuous)
        } else {
            UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 4,
                                   bottomTrailingRadius: 32, topTrailingRadius: 32,
                                   style: .continuous)
        }
    }
}

/// Bubble treatment: glowing note-blue for outgoing, dark blue with a
/// matching glow for incoming.
struct NoteBubble: ViewModifier {
    let isMine: Bool

    func body(content: Content) -> some View {
        let shape = Theme.bubbleShape(isMine: isMine)
        content
            .padding(16)
            .background {
                if isMine {
                    shape
                        .fill(Theme.note)
                        .overlay(shape.strokeBorder(Theme.noteBorder, lineWidth: 0.5))
                        .shadow(color: Theme.note.opacity(0.45), radius: Theme.bubbleShadowRadius, y: Theme.bubbleShadowY)
                } else {
                    shape
                        .fill(Theme.bubbleIncoming)
                        .overlay(shape.strokeBorder(Theme.bubbleIncomingBorder, lineWidth: 0.5))
                        .shadow(color: Theme.bubbleIncoming.opacity(0.45), radius: Theme.bubbleShadowRadius, y: Theme.bubbleShadowY)
                }
            }
    }
}

extension View {
    func noteBubble(isMine: Bool) -> some View {
        modifier(NoteBubble(isMine: isMine))
    }

    /// Liquid Glass chip for transient banners (reply, alerts).
    func glassBanner(cornerRadius: CGFloat = 18) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    func glassBannerCapsule() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }

    /// Rounded accent stroke, border, and shadow fitted to image bounds.
    func imageMessageStyle(isMine: Bool) -> some View {
        let shape = Theme.bubbleShape(isMine: isMine)
        return clipShape(shape)
            .overlay {
                shape.strokeBorder(isMine ? Theme.noteBorder : Theme.bubbleIncomingBorder, lineWidth: 2)
            }
            .shadow(
                color: isMine ? Theme.note.opacity(0.45) : Theme.bubbleIncoming.opacity(0.45),
                radius: Theme.bubbleShadowRadius,
                y: Theme.bubbleShadowY
            )
    }

    /// Paper canvas behind scrollable content; navigation bars pick up system glass.
    func paperCanvas() -> some View {
        background(Theme.paper.ignoresSafeArea())
    }
}

/// Keeps adjacent composer controls in one Liquid Glass sampling region.
struct GlassComposerRow<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing + 24) {
            HStack(spacing: spacing) {
                content()
            }
        }
    }
}
