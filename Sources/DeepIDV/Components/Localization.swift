// DeepIDV › Components

import DeepIDVCore
import Foundation

/// The SDK's on-screen text in the user's language.
///
/// Every line the user reads goes through ``L(_:_:)``, keyed by its English
/// text, and is looked up in the SDK's own `Localizable.strings`. The language
/// is chosen here, not by iOS: a package's translations are otherwise used
/// only when the host app also lists that language, and an English-only app
/// would then always show English.
enum Localization {
    /// The language the screens use right now.
    static var language: DeepIDVLanguage { state.withLock { $0.language } }

    /// Picks the language: `chosen`, or else the first of the user's
    /// preferred languages the SDK has, or else English. Each public view calls
    /// this with its client's ``DeepIDVConfig/language`` when it is created.
    static func use(_ chosen: DeepIDVLanguage?) {
        let language = chosen ?? preferred(Locale.preferredLanguages)
        state.withLock { $0.language = language }
    }

    /// The first of `languages` (BCP 47 tags, most preferred first) the SDK
    /// has, or English.
    static func preferred(_ languages: [String]) -> DeepIDVLanguage {
        for tag in languages {
            let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let code, let language = DeepIDVLanguage(rawValue: code.lowercased()) {
                return language
            }
        }
        return .english
    }

    /// The text for `key` in `language`; the key itself when it has none.
    static func text(_ key: String, in language: DeepIDVLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    /// Every line of `language`'s table, for checking the tables agree.
    static func table(for language: DeepIDVLanguage) -> [String: String] {
        let bundle = bundle(for: language)
        guard let path = bundle.path(forResource: "Localizable", ofType: "strings"),
            let table = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return [:] }
        return table
    }

    private static func bundle(for language: DeepIDVLanguage) -> Bundle {
        state.withLock { state in
            if let bundle = state.bundles[language] { return bundle }
            let bundle =
                Bundle.module.path(forResource: language.rawValue, ofType: "lproj")
                .flatMap(Bundle.init(path:)) ?? .module
            state.bundles[language] = bundle
            return bundle
        }
    }

    private struct State {
        var language = Localization.preferred(Locale.preferredLanguages)
        var bundles: [DeepIDVLanguage: Bundle] = [:]
    }

    private static let state = Locked(State())
}

/// The on-screen text for `key`, its English wording, in the current
/// language. `%@` and `%d` in the key are filled from `arguments`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let language = Localization.language
    let text = Localization.text(key, in: language)
    guard !arguments.isEmpty else { return text }
    return String(format: text, locale: Locale(identifier: language.rawValue), arguments: arguments)
}

/// A value behind a lock, for state read from any thread.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
