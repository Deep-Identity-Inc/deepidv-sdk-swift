// DeepIDVTests › Styling

import SwiftUI
import Testing

@testable import DeepIDV

@Test func anEmptyAppearanceKeepsTheBrandTheme() {
    #expect(Theme.deepidv.applying(DeepIDVAppearance()) == .deepidv)
}

@Test func theAppearanceLaysItsChoicesOverTheTheme() {
    let theme = Theme.deepidv.applying(
        .init(
            accentColor: .indigo, successColor: .mint, warningColor: .orange, errorColor: .pink,
            fontFamily: "Brand Sans", headingFontFamily: "Brand Display", cornerRadius: 6))
    #expect(theme.colors.primary == .indigo)
    #expect(theme.colors.success == .mint)
    #expect(theme.colors.warning == .orange)
    #expect(theme.colors.error == .pink)
    #expect(theme.typography.bodyFamily == "Brand Sans")
    #expect(theme.typography.buttonFamily == "Brand Sans")
    #expect(theme.typography.headingFamily == "Brand Display")
    #expect(theme.buttonRadius == 6)
    #expect(theme.cardRadius == 10)
    // Untouched: the greys.
    #expect(theme.colors.grey == Theme.deepidv.colors.grey)
}

@Test func squareButtonsMakeSquareCardsAndNoRadiusGoesNegative() {
    #expect(Theme.deepidv.applying(.init(cornerRadius: 0)).cardRadius == 0)
    #expect(Theme.deepidv.applying(.init(cornerRadius: -4)).buttonRadius == 0)
}

@Test func textOnAColorIsWhicheverOfBlackOrWhiteReadsBetter() {
    #expect(Color.prefersDarkText(on: Color(hex: "#FFD60A")))  // yellow
    #expect(Color.prefersDarkText(on: .white))
    #expect(!Color.prefersDarkText(on: Color(hex: "#0781DF")))  // the deepidv blue
    #expect(!Color.prefersDarkText(on: Color(hex: "#5856D6")))  // indigo
    #expect(!Color.prefersDarkText(on: Color(hex: "#1C252E")))
    #expect(!Color.prefersDarkText(on: .black))
}

@Test func onlyAColorTheHostSetsGetsItsTextRecolored() {
    // The brand default keeps white on every color, as designed.
    #expect(Theme.deepidv.colors.onWarning == .white)
    let theme = Theme.deepidv.applying(.init(accentColor: Color(hex: "#FFD60A")))
    #expect(theme.colors.onPrimary == .black)
    #expect(theme.colors.onSuccess == .white)
}
