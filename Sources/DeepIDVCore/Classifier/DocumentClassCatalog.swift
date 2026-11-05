// DeepIDVCore › Classifier

/// The broad kind of a classifier document class.
///
/// The capture screen names a recognised document by its region and kind
/// ("Ontario Driver's Licence"), built from the class id; see
/// `DocumentClassCatalog.label(of:)`.
package enum DocumentClassKind: String, Sendable, Equatable, CaseIterable {
    case driversLicence
    case idCard
    case healthCard
    /// Federal or special-purpose cards: citizenship, forces, firearms, PR, NEXUS.
    case federal
    case passport
}

/// A document group, as the capture picker and the classifier both name it.
///
/// The classifier's own groups are wider than the SDK's three pickable
/// `DocumentType`s; a class from a group the SDK never offers still matters,
/// because the classifier may name it while the user holds up the wrong card.
package enum DocumentGroup: String, Sendable, Equatable, CaseIterable {
    case driversLicence
    case passport
    case national
    case permanentResident
    case military
    case firearm
}

/// How much evidence it takes to block a health card.
package enum HealthPolicy: Sendable, Equatable {
    /// A driver's licence, an ID card or no known pick: a health card looks like
    /// one, so the classifier's vote counts. Blocked when the classifier names it
    /// or the vote is strong; a weak vote, or a health card merely leading the
    /// vote window, holds auto-capture.
    case strict
    /// Any other pick: only the classifier naming a health card blocks it, and
    /// health-card votes aren't counted.
    case apiOnly
}

/// The classifier's document classes, mapped to their kind and group.
///
/// An id that isn't listed (a class added to the model after this table) maps to
/// `nil`. That is safe: an unknown id can't be confirmed by a vote, only by the
/// classifier naming it on consecutive frames, and it never flips the
/// upside-down check.
package enum DocumentClassCatalog {
    /// The classes of catalogue split `v20261021`. `no_id` is left out: it is not
    /// a document.
    package static let kinds: [String: DocumentClassKind] = [
        "ca_ab_dl": .driversLicence,
        "ca_ab_dl_2026": .driversLicence,
        "ca_ab_id": .idCard,
        "ca_bc_dl": .driversLicence,
        "ca_bc_dl_bcsc": .driversLicence,
        "ca_bc_id": .healthCard,
        "ca_citizenship_card": .federal,
        "ca_dnd_ndi10": .federal,
        "ca_dnd_ndi20": .federal,
        "ca_dnd_ndi21": .federal,
        "ca_dnd_ndi75": .federal,
        "ca_firearms_license_new": .federal,
        "ca_firearms_license_old": .federal,
        "ca_indian_status_card": .federal,
        "ca_mb_dl": .driversLicence,
        "ca_mb_hc": .healthCard,
        "ca_mb_id": .idCard,
        "ca_nexus_card": .federal,
        "ca_nfl_hc": .healthCard,
        "ca_ns_hc": .healthCard,
        "ca_ns_id": .idCard,
        "ca_on_dl": .driversLicence,
        "ca_on_hc": .healthCard,
        "ca_pei_hc": .healthCard,
        "ca_qc_dl": .driversLicence,
        "ca_qc_hc": .healthCard,
        "ca_sk_dl": .driversLicence,
        "ca_sk_hc": .healthCard,
        "gb_dvla_dl": .driversLicence,
        "gb_dvla_dl_prov": .driversLicence,
        "us_ak_dl": .driversLicence,
        "us_ar_dl": .driversLicence,
        "us_az_dl": .driversLicence,
        "us_ca_dl": .driversLicence,
        "us_co_dl": .driversLicence,
        "us_ct_dl": .driversLicence,
        "us_dc_dl": .driversLicence,
        "us_de_dl": .driversLicence,
        "us_fl_dl": .driversLicence,
        "us_ga_dl": .driversLicence,
        "us_hi_dl": .driversLicence,
        "us_ia_dl": .driversLicence,
        "us_id_dl": .driversLicence,
        "us_il_dl": .driversLicence,
        "us_in_dl": .driversLicence,
        "us_ks_dl": .driversLicence,
        "us_ky_dl": .driversLicence,
        "us_la_dl": .driversLicence,
        "us_ma_dl": .driversLicence,
        "us_md_dl": .driversLicence,
        "us_me_dl": .driversLicence,
        "us_mi_dl": .driversLicence,
        "us_mn_dl": .driversLicence,
        "us_mo_dl": .driversLicence,
        "us_ms_dl": .driversLicence,
        "us_mt_dl": .driversLicence,
        "us_nc_dl": .driversLicence,
        "us_nd_dl": .driversLicence,
        "us_ne_dl": .driversLicence,
        "us_nh_dl": .driversLicence,
        "us_nj_dl": .driversLicence,
        "us_nm_dl": .driversLicence,
        "us_nv_dl": .driversLicence,
        "us_ny_dl": .driversLicence,
        "us_oh_dl": .driversLicence,
        "us_ok_dl": .driversLicence,
        "us_or_dl": .driversLicence,
        "us_pa_dl": .driversLicence,
        "us_pr_card": .federal,
        "us_ri_dl": .driversLicence,
        "us_sc_dl": .driversLicence,
        "us_sd_dl": .driversLicence,
        "us_tn_dl": .driversLicence,
        "us_tx_dl": .driversLicence,
        "us_ut_dl": .driversLicence,
        "us_va_dl": .driversLicence,
        "us_vt_dl": .driversLicence,
        "us_wa_dl": .driversLicence,
        "us_wi_dl": .driversLicence,
        "us_wv_dl": .driversLicence,
        "us_wy_dl": .driversLicence,
        "ca_passport": .passport,
        "us_passport_book": .passport,
    ]

    /// Ids outside `.driversLicence` and `.idCard` that still count as national ID.
    private static let nationalExtras: Set<String> = [
        "ca_citizenship_card",
        "ca_indian_status_card",
        "ca_nexus_card",
    ]

    package static func kind(of id: String) -> DocumentClassKind? {
        kinds[id]
    }

    /// The group a class belongs to, or `nil` for an unknown class. The first
    /// rule that matches wins, in the same order as the web capture.
    package static func group(of id: String) -> DocumentGroup? {
        guard let kind = kinds[id] else { return nil }
        if kind == .driversLicence { return .driversLicence }
        if id.contains("passport") { return .passport }
        if kind == .idCard || kind == .healthCard || nationalExtras.contains(id) {
            return .national
        }
        if id.contains("pr_card") { return .permanentResident }
        if id.hasPrefix("ca_dnd_") { return .military }
        if id.hasPrefix("ca_firearms_license") { return .firearm }
        return nil
    }

    /// Whether a class is a health card, which is never accepted as ID.
    package static func isHealthCard(_ id: String) -> Bool {
        kinds[id] == .healthCard
    }

    /// Whether the classifier naming `id` while `picked` was chosen is the ID card /
    /// driver's licence confusion, either way round. The two look alike and some
    /// licences have no class of their own, so it isn't worth telling the user
    /// they hold the wrong document.
    package static func isIDCardLicenceMixup(_ id: String, picked: DocumentGroup?) -> Bool {
        let kind = kinds[id]
        return (picked == .driversLicence && kind == .idCard)
            || (picked == .national && kind == .driversLicence)
    }

    /// The group a picked `DocumentType` scans as, or `nil` when there is none.
    package static func group(for documentType: DocumentType) -> DocumentGroup? {
        switch documentType {
        case .driversLicense: return .driversLicence
        case .idCard: return .national
        case .passport: return .passport
        case .auto: return nil
        }
    }

    /// The health-card policy for a picked `DocumentType`: strict for licences, ID
    /// cards and no pick; API-only for everything else.
    package static func healthPolicy(for documentType: DocumentType) -> HealthPolicy {
        switch documentType {
        case .driversLicense, .idCard, .auto: return .strict
        case .passport: return .apiOnly
        }
    }
}
