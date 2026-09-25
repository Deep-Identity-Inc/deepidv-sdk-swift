// DeepIDVCore › Models

/// The kind of identity document being scanned.
///
/// `public` so clients can pick a type for the capture flows. `Sendable` so it
/// can cross concurrency boundaries (camera thread → ML actor → main actor)
/// without warnings under Swift 6 strict concurrency. The `String` raw type
/// gives every case a stable identity for SwiftUI pickers/`ForEach`; the
/// on-the-wire value is deliberately *separate* (`wireValue`) since the API uses
/// snake_case strings (`national_id`, `drivers_license`) that differ from these
/// idiomatic Swift names. `CaseIterable` lets the picker enumerate the choices.
public enum DocumentType: String, Sendable, Equatable, CaseIterable {
    case passport
    case idCard  // wire: "national_id"
    case driversLicense  // wire: "drivers_license"
    case auto  // wire: "auto" — headless `scanDocument` only

    /// On-the-wire value sent to `/v1/document/scan` and `/v1/identity/verify`.
    ///
    /// Kept `internal`: only the Core services serialize it. The `String` raw
    /// value (the case name) is *not* the wire value, so the two never alias.
    var wireValue: String {
        switch self {
        case .passport: return "passport"
        case .idCard: return "national_id"
        case .driversLicense: return "drivers_license"
        case .auto: return "auto"
        }
    }

    /// Whether the guided capture flow shoots one side or two.
    ///
    /// `public` because the capture views (in the `DeepIDV` module) branch on it
    /// to decide front-only vs. front+back capture. Passports carry
    /// everything on the data page, so they are front-only; everything else is
    /// two-sided. `.auto` has no deterministic answer — it is rejected by the
    /// picker and only reachable on the headless method, so it falls into
    /// the `.frontAndBack` default here without being exercised by capture.
    public var captureMode: CaptureMode {
        self == .passport ? .frontOnly : .frontAndBack
    }
}

/// How many sides the guided flow captures for a given `DocumentType`.
public enum CaptureMode: Sendable, Equatable {
    case frontOnly
    case frontAndBack
}
