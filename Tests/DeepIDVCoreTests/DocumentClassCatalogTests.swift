import Foundation
import Testing

@testable import DeepIDVCore

@Suite struct DocumentClassCatalogTests {
    @Test func theCatalogueIsPinnedToItsSplit() {
        let kinds = DocumentClassCatalog.kinds
        #expect(kinds.count == 83)
        #expect(kinds.values.filter { $0 == .driversLicence }.count == 60)
        #expect(kinds.values.filter { $0 == .federal }.count == 10)
        #expect(kinds.values.filter { $0 == .healthCard }.count == 8)
        #expect(kinds.values.filter { $0 == .idCard }.count == 3)
        #expect(kinds.values.filter { $0 == .passport }.count == 2)
        #expect(kinds["no_id"] == nil)
    }

    @Test func anUnknownClassHasNoKindOrGroup() {
        #expect(DocumentClassCatalog.kind(of: "xx_new_dl") == nil)
        #expect(DocumentClassCatalog.group(of: "xx_new_dl") == nil)
        #expect(!DocumentClassCatalog.isHealthCard("xx_new_dl"))
    }

    @Test func classesFallIntoTheirGroups() {
        let expected: [String: DocumentGroup] = [
            "ca_on_dl": .driversLicence,
            "gb_dvla_dl": .driversLicence,
            "gb_dvla_dl_prov": .driversLicence,
            "us_tx_dl": .driversLicence,
            "ca_ab_id": .national,
            "ca_on_hc": .national,
            "ca_citizenship_card": .national,
            "ca_nexus_card": .national,
            "ca_indian_status_card": .national,
            "us_pr_card": .permanentResident,
            "ca_dnd_ndi20": .military,
            "ca_firearms_license_new": .firearm,
            "ca_passport": .passport,
            "us_passport_book": .passport,
        ]
        for (id, group) in expected {
            #expect(DocumentClassCatalog.group(of: id) == group, "\(id)")
        }
        // Every listed class has a group.
        #expect(DocumentClassCatalog.kinds.keys.allSatisfy { DocumentClassCatalog.group(of: $0) != nil })
    }

    @Test func healthCardsAreFlagged() {
        #expect(DocumentClassCatalog.isHealthCard("ca_on_hc"))
        #expect(DocumentClassCatalog.isHealthCard("ca_bc_id"), "the Services Card replaced the health card")
        #expect(!DocumentClassCatalog.isHealthCard("ca_bc_dl"))
        #expect(!DocumentClassCatalog.isHealthCard("ca_bc_dl_bcsc"))
        #expect(!DocumentClassCatalog.isHealthCard("ca_on_dl"))
    }

    @Test func theIDCardLicenceConfusionIsRecognisedBothWaysAndOnlyThatPair() {
        #expect(DocumentClassCatalog.isIDCardLicenceMixup("ca_ab_id", picked: .driversLicence))
        #expect(DocumentClassCatalog.isIDCardLicenceMixup("ca_on_dl", picked: .national))
        #expect(!DocumentClassCatalog.isIDCardLicenceMixup("ca_on_hc", picked: .driversLicence))
        #expect(!DocumentClassCatalog.isIDCardLicenceMixup("ca_ab_id", picked: .passport))
        #expect(!DocumentClassCatalog.isIDCardLicenceMixup("ca_on_dl", picked: nil))
    }

    @Test func pickedDocumentTypesMapToGroupsAndHealthPolicies() {
        #expect(DocumentClassCatalog.group(for: .driversLicense) == .driversLicence)
        #expect(DocumentClassCatalog.group(for: .idCard) == .national)
        #expect(DocumentClassCatalog.group(for: .passport) == .passport)
        #expect(DocumentClassCatalog.group(for: .auto) == nil)
        #expect(DocumentClassCatalog.healthPolicy(for: .driversLicense) == .strict)
        #expect(DocumentClassCatalog.healthPolicy(for: .idCard) == .strict)
        #expect(DocumentClassCatalog.healthPolicy(for: .auto) == .strict)
        #expect(DocumentClassCatalog.healthPolicy(for: .passport) == .apiOnly)
    }
}

@Suite struct DetectAnswerDecodingTests {
    private func decode(_ json: String) throws -> DetectAnswer {
        try JSONDecoder().decode(DetectAnswer.self, from: Data(json.utf8))
    }

    @Test func decodesAFullAnswer() throws {
        let answer = try decode(
            """
            {"present": true, "box": {"xyxy": [12, 34, 560, 380], "score": 0.97},
             "document_type": {"id": "ca_on_dl", "confidence": 0.81,
                               "top3": [["ca_on_dl", 0.81], ["ca_ab_dl", 0.07], ["us_ga_dl", 0.02]]},
             "model_version": "m-test"}
            """)
        #expect(answer.present)
        #expect(answer.box == .init(xyxy: [12, 34, 560, 380], score: 0.97))
        #expect(answer.documentType?.id == "ca_on_dl")
        #expect(answer.documentType?.confidence == 0.81)
        #expect(answer.documentType?.top3.map(\.id) == ["ca_on_dl", "ca_ab_dl", "us_ga_dl"])
        #expect(answer.top == .init(id: "ca_on_dl", confidence: 0.81))
        #expect(answer.modelVersion == "m-test")
    }

    @Test func decodesAnAnswerWithNoCard() throws {
        let answer = try decode(#"{"present": false, "box": null}"#)
        #expect(!answer.present)
        #expect(answer.box == nil)
        #expect(answer.documentType == nil)
        #expect(answer.top == nil)
    }

    @Test func decodesAnUnnamedTypeWithItsGuesses() throws {
        let answer = try decode(
            #"{"present": true, "document_type": {"id": null, "confidence": 0.31, "top3": [["us_tx_dl", 0.31]]}}"#)
        #expect(answer.documentType?.id == nil)
        #expect(answer.top?.id == "us_tx_dl")
    }
}
