// DeepIDV › Styling

import Foundation
import SwiftUI

/// Parses a hex color string into sRGB components in `0...1`.
///
/// Accepts `"#RRGGBB"` / `"RRGGBB"` and `"#RRGGBBAA"` / `"RRGGBBAA"` (the leading
/// `#` is optional). Anything else resolves to opaque black so a malformed token
/// can never crash a host app.
func rgbaComponents(
    hex: String
) -> (red: Double, green: Double, blue: Double, opacity: Double) {
    let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    var value: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&value)

    switch cleaned.count {
    case 6:  // RRGGBB
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    case 8:  // RRGGBBAA
        return (
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            opacity: Double(value & 0xFF) / 255
        )
    default:
        return (red: 0, green: 0, blue: 0, opacity: 1)
    }
}

extension Color {
    /// Creates a `Color` from a hex string (see `rgbaComponents` for the accepted
    /// forms). Built in the `.sRGB` space so colors are stable across platforms.
    init(hex: String) {
        let c = rgbaComponents(hex: hex)
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.opacity)
    }
}

/// The semantic color tokens SDK views resolve from the theme.
///
/// Brand + status colors plus the full 10-step grey scale, mirroring the verify
/// app palette. Tokens are the only colors views may use — no inline literals.
struct ColorTokens: Sendable, Equatable {
    var primary: Color
    var secondary: Color
    var success: Color
    var warning: Color
    var error: Color
    var grey: GreyScale

    /// Neutral ramp, light (`s50`) to dark (`s900`).
    struct GreyScale: Sendable, Equatable {
        var s50: Color
        var s100: Color
        var s200: Color
        var s300: Color
        var s400: Color
        var s500: Color
        var s600: Color
        var s700: Color
        var s800: Color
        var s900: Color
    }
}

extension ColorTokens {
    /// The fixed deepidv brand palette.
    static let deepidv = ColorTokens(
        primary: Color(hex: "#0781DF"),
        secondary: Color(hex: "#8E33FF"),
        success: Color(hex: "#22C55E"),
        warning: Color(hex: "#FFAB00"),
        error: Color(hex: "#FF5630"),
        grey: GreyScale(
            s50: Color(hex: "#FCFDFD"),
            s100: Color(hex: "#F9FAFB"),
            s200: Color(hex: "#F4F6F8"),
            s300: Color(hex: "#DFE3E8"),
            s400: Color(hex: "#C4CDD5"),
            s500: Color(hex: "#919EAB"),
            s600: Color(hex: "#637381"),
            s700: Color(hex: "#454F5B"),
            s800: Color(hex: "#1C252E"),
            s900: Color(hex: "#141A21")
        )
    )
}
