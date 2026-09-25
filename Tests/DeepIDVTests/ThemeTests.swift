import SwiftUI
import Testing

// `@testable` (not the plain `import DeepIDV` the public-surface tests use):
// the theming types are deliberately `internal`, so reaching them
// requires testability.
@testable import DeepIDV

// MARK: - Hex parsing

@Test func testHexParsingSixDigits() {
    let c = rgbaComponents(hex: "#0781DF")  // 0x07, 0x81, 0xDF
    #expect(abs(c.red - 7.0 / 255) < 0.0001)
    #expect(abs(c.green - 129.0 / 255) < 0.0001)
    #expect(abs(c.blue - 223.0 / 255) < 0.0001)
    #expect(c.opacity == 1)
}

@Test func testHexParsingToleratesMissingHash() {
    let withHash = rgbaComponents(hex: "#22C55E")
    let without = rgbaComponents(hex: "22C55E")
    #expect(withHash.red == without.red)
    #expect(withHash.green == without.green)
    #expect(withHash.blue == without.blue)
    #expect(withHash.opacity == without.opacity)
}

@Test func testHexParsingEightDigitsCarriesAlpha() {
    let c = rgbaComponents(hex: "#00000080")  // black at 50% alpha
    #expect(c.red == 0)
    #expect(c.green == 0)
    #expect(c.blue == 0)
    #expect(abs(c.opacity - 128.0 / 255) < 0.0001)
}

@Test func testHexParsingMalformedFallsBackToOpaqueBlack() {
    let c = rgbaComponents(hex: "nope")
    #expect(c.red == 0)
    #expect(c.green == 0)
    #expect(c.blue == 0)
    #expect(c.opacity == 1)
}

// MARK: - Token defaults

@Test func testBrandColorTokensUseExpectedHexes() {
    let colors = Theme.deepidv.colors
    #expect(colors.primary == Color(hex: "#0781DF"))
    #expect(colors.secondary == Color(hex: "#8E33FF"))
    #expect(colors.success == Color(hex: "#22C55E"))
    #expect(colors.warning == Color(hex: "#FFAB00"))
    #expect(colors.error == Color(hex: "#FF5630"))
}

@Test func testGreyScaleEndpoints() {
    let grey = Theme.deepidv.colors.grey
    #expect(grey.s50 == Color(hex: "#FCFDFD"))
    #expect(grey.s900 == Color(hex: "#141A21"))
}

@Test func testSpacingScaleIsEightPointBased() {
    let spacing = Theme.deepidv.spacing
    #expect(spacing.xs == 4)
    #expect(spacing.sm == 8)
    #expect(spacing.md == 16)
    #expect(spacing.lg == 24)
    #expect(spacing.xl == 32)
}

@Test func testTypographyFamilies() {
    let typography = Theme.deepidv.typography
    #expect(typography.bodyFamily == "WF Visual Sans Variable")
    #expect(typography.headingFamily == "WF Visual Sans Variable")
    #expect(typography.buttonFamily == "Geist Variable")
}

// MARK: - Environment resolution

@Test func testEnvironmentThemeDefaultsToDeepIDV() {
    let environment = EnvironmentValues()
    #expect(environment.theme == .deepidv)
}

@Test func testEnvironmentThemeIsOverridable() {
    // The internal setter is the seam the whitelabel story will use. Overriding
    // the brand color must round-trip through the Environment.
    var environment = EnvironmentValues()
    var custom = Theme.deepidv
    custom.colors.primary = Color(hex: "#000000")
    environment.theme = custom
    #expect(environment.theme == custom)
    #expect(environment.theme != .deepidv)
}
