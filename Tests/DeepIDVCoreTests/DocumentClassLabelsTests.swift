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
