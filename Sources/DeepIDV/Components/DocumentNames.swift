// DeepIDV › Components

import DeepIDVCore

/// Document names on screen, in the current language.
enum DocumentNames {
    /// What the classifier recognised: "Ontario Driver's License", or in
    /// Spanish "Licencia de conducir (Ontario)". `nil` for an unknown class.
    static func label(of id: String) -> String? {
        switch DocumentClassCatalog.name(of: id) {
        case .special(let name)?: return L(name)
        case .regional(let region, let kind)?: return L("%1$@ %2$@", L(region), title(kind))
        case .kind(let kind)?: return title(kind)
        case nil: return nil
        }
    }

    /// A kind of document as a title: "Driver's License".
    static func title(_ kind: DocumentClassKind) -> String {
        switch kind {
        case .driversLicence: return L("Driver's License")
        case .idCard: return L("ID Card")
        case .healthCard: return L("Health Card")
        case .federal: return L("Government ID")
        case .passport: return L("Passport")
        }
    }
}
