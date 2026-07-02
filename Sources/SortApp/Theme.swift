import SwiftUI

/// Visual palette extracted from the design wireframe (warm-paper, Apple-Photos-native, D9).
/// Centralized so the rest of the app can adopt it as screens are restyled.
enum Theme {
    static let pageBg       = Color(hex: 0xFBFAF6)   // window content background
    static let cardBg       = Color(hex: 0xFFFFFF)
    static let cardBorder   = Color(hex: 0xE8E7E0)
    static let segmentTrack = Color(hex: 0xE7E6DF)   // neutral Sonoma segmented-control track
    static let separator    = Color(hex: 0xEDECEA)
    static let headerBg     = Color(hex: 0xF1F0EC)

    static let previewWarm  = Color(hex: 0xF4F3EE)
    static let previewWarm2 = Color(hex: 0xECEAE3)

    static let titleStrong  = Color(hex: 0x33332F)
    static let title        = Color(hex: 0x46453F)
    static let label        = Color(hex: 0x54534C)
    static let muted        = Color(hex: 0x9A998F)
    static let count        = Color(hex: 0xA9A89E)
    static let sectionLabel = Color(hex: 0xAEADA3)

    static let accent       = Color(hex: 0x0A84FF)   // iOS system blue
    static let silhouetteBg = Color(hex: 0xE0DFD6)
    static let silhouetteFg = Color(hex: 0xC7C6BD)
    static let placeholder  = Color(hex: 0xD4D3CA)
    static let iconStroke   = Color(hex: 0xC4C3BB)
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
