// DeepIDV › Styling

import SwiftUI
import UIKit

/// Your brand on the SDK's screens: an accent color, status colors, fonts,
/// corner radius and light or dark appearance. Anything left `nil` keeps the
/// deepidv default.
///
/// Apply it to any SDK view; it reaches every screen that view shows:
///
/// ```swift
/// DeepIDVWorkflowView(client: client, sessionID: id) { result in … }
///     .deepIDVAppearance(.init(accentColor: .indigo, cornerRadius: 8))
/// ```
///
/// Fonts must be registered by your app (bundled and listed under
/// `UIAppFonts`); a family that isn't falls back to the system font. Text on
/// a colored background turns black or white, whichever reads better on it.
public struct DeepIDVAppearance: Sendable, Equatable {
    /// Buttons, progress, and the frame while a document or face lines up.
    public var accentColor: Color?
    /// Ticks, the frame once it is ready, and the liveness ring.
    public var successColor: Color?
    /// Something needs the user: the wrong document, an upside-down card.
    public var warningColor: Color?
    /// Something can't be used, such as a health card.
    public var errorColor: Color?
    /// The font family for all text, by its registered name.
    public var fontFamily: String?
    /// The font family for titles, over ``fontFamily``.
    public var headingFontFamily: String?
    /// The corner radius of buttons, in points; cards round a little more.
    /// `0` gives square corners. The document frame keeps its ID-card shape.
    public var cornerRadius: CGFloat?
    /// Light or dark for the screens outside the camera; `nil` follows the
    /// system. The camera screens are always dark.
    public var colorScheme: ColorScheme?

    public init(
        accentColor: Color? = nil,
        successColor: Color? = nil,
        warningColor: Color? = nil,
        errorColor: Color? = nil,
        fontFamily: String? = nil,
        headingFontFamily: String? = nil,
        cornerRadius: CGFloat? = nil,
        colorScheme: ColorScheme? = nil
    ) {
        self.accentColor = accentColor
        self.successColor = successColor
        self.warningColor = warningColor
        self.errorColor = errorColor
        self.fontFamily = fontFamily
        self.headingFontFamily = headingFontFamily
        self.cornerRadius = cornerRadius
        self.colorScheme = colorScheme
    }
}

extension View {
    /// Styles the SDK screens this view shows with your brand. See
    /// ``DeepIDVAppearance``.
    public func deepIDVAppearance(_ appearance: DeepIDVAppearance) -> some View {
        modifier(AppearanceModifier(appearance: appearance))
    }
}

private struct AppearanceModifier: ViewModifier {
    let appearance: DeepIDVAppearance

    func body(content: Content) -> some View {
        let themed = content.environment(\.theme, Theme.deepidv.applying(appearance))
        if let scheme = appearance.colorScheme {
            themed.environment(\.colorScheme, scheme)
        } else {
            themed
        }
    }
}

extension Theme {
    /// This theme with `appearance`'s choices over it.
    func applying(_ appearance: DeepIDVAppearance) -> Theme {
        var theme = self
        if let color = appearance.accentColor {
            theme.colors.primary = color
            theme.colors.onPrimary = color.readableText
        }
        if let color = appearance.successColor {
            theme.colors.success = color
            theme.colors.onSuccess = color.readableText
        }
        if let color = appearance.warningColor {
            theme.colors.warning = color
            theme.colors.onWarning = color.readableText
        }
        if let color = appearance.errorColor { theme.colors.error = color }
        if let family = appearance.fontFamily {
            theme.typography.bodyFamily = family
            theme.typography.headingFamily = family
            theme.typography.buttonFamily = family
        }
        if let family = appearance.headingFontFamily { theme.typography.headingFamily = family }
        if let radius = appearance.cornerRadius { theme.cornerRadius = max(0, radius) }
        return theme
    }
}

extension Color {
    /// White, or black on a color too light for white to read.
    var readableText: Color {
        Self.prefersDarkText(on: self) ? .black : .white
    }

    /// Whether text on `background` should be dark: white falls short of the
    /// 3:1 contrast bold text needs (WCAG), which is a relative luminance over
    /// 0.3. Mid-tone brand colors keep white text, as designers mostly choose.
    static func prefersDarkText(on background: Color) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(background).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return false
        }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        // White's contrast 1.05 / (L + 0.05) drops under 3 above L = 0.3.
        return luminance > 0.3
    }
}
