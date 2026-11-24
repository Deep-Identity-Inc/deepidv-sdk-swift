import Testing

@testable import DeepIDVCore

@Suite struct DocumentClassLabelsTests {
    @Test func aRegionalLicenceIsNamedByItsRegion() {
        #expect(DocumentClassCatalog.label(of: "ca_on_dl") == "Ontario Driver's License")
        #expect(DocumentClassCatalog.label(of: "ca_bc_dl_bcsc") == "British Columbia Driver's License")
        #expect(DocumentClassCatalog.label(of: "ca_ab_dl_2026") == "Alberta Driver's License")
    }

    @Test func aUSLicenseIsSpelledTheUSWay() {
        #expect(DocumentClassCatalog.label(of: "us_tx_dl") == "Texas Driver's License")
        #expect(DocumentClassCatalog.label(of: "us_dc_dl") == "District of Columbia Driver's License")
    }

    @Test func specialClassesHaveTheirOwnNames() {
        #expect(DocumentClassCatalog.label(of: "gb_dvla_dl") == "UK Driving Licence")
        #expect(DocumentClassCatalog.label(of: "gb_dvla_dl_prov") == "UK Provisional Driving Licence")
        #expect(DocumentClassCatalog.label(of: "ca_dnd_ndi20") == "Canadian Forces ID")
        #expect(DocumentClassCatalog.label(of: "us_passport_book") == "US Passport")
    }

    @Test func otherKindsTakeTheirRegionToo() {
        #expect(DocumentClassCatalog.label(of: "ca_on_hc") == "Ontario Health Card")
        #expect(DocumentClassCatalog.label(of: "ca_mb_id") == "Manitoba ID Card")
        #expect(DocumentClassCatalog.label(of: "ca_pei_hc") == "Prince Edward Island Health Card")
    }

    @Test func classifierV17ClassesAreNamed() {
        #expect(DocumentClassCatalog.label(of: "br_id") == "Brazil ID Card")
        #expect(DocumentClassCatalog.label(of: "ar_dl") == "Argentina Driver's License")
        #expect(DocumentClassCatalog.label(of: "do_id") == "Dominican Republic ID Card")
        #expect(DocumentClassCatalog.label(of: "sv_dl") == "El Salvador Driver's License")
        #expect(DocumentClassCatalog.label(of: "us_pr_dl") == "Puerto Rico Driver's License")
        #expect(DocumentClassCatalog.label(of: "gb_passport") == "UK Passport")
        #expect(DocumentClassCatalog.label(of: "us_passport_card") == "US Passport Card")
        #expect(DocumentClassCatalog.label(of: "ca_pr_card") == "Canadian Permanent Resident Card")
        #expect(DocumentClassCatalog.label(of: "ng_nin") == "Nigeria NIN Slip")
    }

    @Test func anUnlistedCountryIsNotNamedAfterItsCode() {
        #expect(DocumentClassCatalog.name(of: "zz_id") == nil, "no kind, no name")
    }

    @Test func everyKnownClassHasAName() {
        for id in DocumentClassCatalog.kinds.keys {
            let label = DocumentClassCatalog.label(of: id)
            #expect(label?.isEmpty == false, "\(id)")
            #expect(label?.contains("_") == false, "\(id)")
        }
    }

    @Test func anUnknownClassHasNoName() {
        #expect(DocumentClassCatalog.label(of: "xx_unknown_dl") == nil)
        #expect(DocumentClassCatalog.label(of: "no_id") == nil)
    }
}
