import Foundation

enum NicknameInput {
    /// Strips emoji characters. Spline's Metal text renderer crashes on them.
    static func sanitized(_ string: String) -> String {
        String(string.filter { character in
            !character.unicodeScalars.contains { scalar in
                scalar.properties.isEmoji || scalar.properties.isEmojiPresentation
            }
        })
    }
}
