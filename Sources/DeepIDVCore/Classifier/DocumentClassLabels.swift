// DeepIDVCore › Classifier

/// The names the capture screen shows for a document the classifier recognised:
/// "Ontario Driver's Licence", "UK Driving Licence", "Texas Driver's License".
///
/// Built from the class id (`<country>_<region>_<kind>`), so a class added to the
/// model later still gets a sensible name from its region and kind.
extension DocumentClassCatalog {
    /// The display name of a class, or `nil` for an id with no known kind.
    package static func label(of id: String) -> String? {
        if let special = specialLabels[id] { return special }
        guard let kind = kinds[id] else { return nil }
        let parts = id.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return kindLabel(kind, country: nil) }
        let country = parts[0]
        let region = regionName(country: country, code: parts[1])
        let noun = kindLabel(kind, country: country)
        return region.map { "\($0) \(noun)" } ?? noun
    }

    /// The kind as a title: "Driver's Licence" (US: "Driver's License").
    package static func kindLabel(_ kind: DocumentClassKind, country: String? = nil) -> String {
        switch kind {
        case .driversLicence: return country == "us" ? "Driver's License" : "Driver's Licence"
        case .idCard: return "ID Card"
        case .healthCard: return "Health Card"
        case .federal: return "Government ID"
        case .passport: return "Passport"
        }
    }

    private static func regionName(country: String, code: String) -> String? {
        switch country {
        case "ca": return canadianRegions[code]
        case "us": return usRegions[code]
        case "gb": return "UK"
        default: return nil
        }
    }

    /// Classes whose name doesn't follow from their region and kind.
    private static let specialLabels: [String: String] = [
        "gb_dvla_dl": "UK Driving Licence",
        "gb_dvla_dl_prov": "UK Provisional Driving Licence",
        "ca_citizenship_card": "Canadian Citizenship Card",
        "ca_dnd_ndi10": "Canadian Forces ID",
        "ca_dnd_ndi20": "Canadian Forces ID",
        "ca_dnd_ndi21": "Canadian Forces ID",
        "ca_dnd_ndi75": "Canadian Forces ID",
        "ca_firearms_license_new": "Canadian Firearms Licence",
        "ca_firearms_license_old": "Canadian Firearms Licence",
        "ca_indian_status_card": "Status Card",
        "ca_nexus_card": "NEXUS Card",
        "us_pr_card": "US Permanent Resident Card",
        "ca_passport": "Canadian Passport",
        "us_passport_book": "US Passport",
    ]

    private static let canadianRegions: [String: String] = [
        "ab": "Alberta", "bc": "British Columbia", "mb": "Manitoba", "nb": "New Brunswick",
        "nl": "Newfoundland and Labrador", "nfl": "Newfoundland and Labrador",
        "ns": "Nova Scotia", "nt": "Northwest Territories", "nu": "Nunavut", "on": "Ontario",
        "pe": "Prince Edward Island", "pei": "Prince Edward Island", "qc": "Quebec",
        "sk": "Saskatchewan", "yt": "Yukon",
    ]

    private static let usRegions: [String: String] = [
        "al": "Alabama", "ak": "Alaska", "az": "Arizona", "ar": "Arkansas", "ca": "California",
        "co": "Colorado", "ct": "Connecticut", "de": "Delaware", "dc": "District of Columbia",
        "fl": "Florida", "ga": "Georgia", "hi": "Hawaii", "id": "Idaho", "il": "Illinois",
        "in": "Indiana", "ia": "Iowa", "ks": "Kansas", "ky": "Kentucky", "la": "Louisiana",
        "me": "Maine", "md": "Maryland", "ma": "Massachusetts", "mi": "Michigan",
        "mn": "Minnesota", "ms": "Mississippi", "mo": "Missouri", "mt": "Montana",
        "ne": "Nebraska", "nv": "Nevada", "nh": "New Hampshire", "nj": "New Jersey",
        "nm": "New Mexico", "ny": "New York", "nc": "North Carolina", "nd": "North Dakota",
        "oh": "Ohio", "ok": "Oklahoma", "or": "Oregon", "pa": "Pennsylvania",
        "ri": "Rhode Island", "sc": "South Carolina", "sd": "South Dakota", "tn": "Tennessee",
        "tx": "Texas", "ut": "Utah", "vt": "Vermont", "va": "Virginia", "wa": "Washington",
        "wv": "West Virginia", "wi": "Wisconsin", "wy": "Wyoming",
    ]
}
