// DeepIDVTests › Localization

import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

// These read the tables directly and never change the shared language, so
// they can run beside tests that expect English.

@Test func theDeviceLanguagePicksTheFirstOneWeHave() {
    #expect(Localization.preferred(["fr-CA", "en-US"]) == .french)
    #expect(Localization.preferred(["de-DE", "es-ES", "en"]) == .spanish)
    #expect(Localization.preferred(["es_MX"]) == .spanish)
    #expect(Localization.preferred(["de-DE", "ja-JP"]) == .english)
    #expect(Localization.preferred([]) == .english)
}

@Test func everyLanguageHasEveryLineWithTheSamePlaceholders() {
    let english = Localization.table(for: .english)
    #expect(english.count > 250)
    let placeholders = { (text: String) -> [String] in
        let regex = try! NSRegularExpression(pattern: "%(?:[0-9]\\$)?[@d]")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { (text as NSString).substring(with: $0.range).replacingOccurrences(of: "1$", with: "")
                .replacingOccurrences(of: "2$", with: "") }
            .sorted()
    }
    for language in [DeepIDVLanguage.spanish, .french] {
        let table = Localization.table(for: language)
        #expect(Set(table.keys) == Set(english.keys), "\(language)")
        for (key, text) in table {
            #expect(placeholders(text) == placeholders(key), "\(language): \(key)")
        }
    }
}

@Test func linesComeBackInTheirLanguage() {
    #expect(Localization.text("Try again", in: .english) == "Try again")
    #expect(Localization.text("Try again", in: .spanish) == "Reintentar")
    #expect(Localization.text("Try again", in: .french) == "Réessayer")
    let french = Localization.text("%d attempts left", in: .french)
    #expect(String(format: french, 3) == "Il vous reste 3 tentatives")
    // A region and a kind trade places where the language needs it.
    let spanish = Localization.text("%1$@ %2$@", in: .spanish)
    #expect(String(format: spanish, "Ontario", "Licencia de conducir") == "Licencia de conducir (Ontario)")
}

@Test func anUnknownLineFallsBackToItsEnglish() {
    #expect(Localization.text("Not a line we have", in: .french) == "Not a line we have")
}

@Test func theConfigCarriesTheLanguage() {
    #expect(DeepIDVConfig(apiKey: "k").language == nil)
    #expect(DeepIDVConfig(apiKey: "k", language: .french).language == .french)
}
