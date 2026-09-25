import Testing

@testable import DeepIDVCore

@Test func wireValueMapsEveryCaseToTheApiString() {
    #expect(DocumentType.passport.wireValue == "passport")
    #expect(DocumentType.idCard.wireValue == "national_id")
    #expect(DocumentType.driversLicense.wireValue == "drivers_license")
    #expect(DocumentType.auto.wireValue == "auto")
}

@Test func captureModeIsFrontOnlyForPassportAndFrontAndBackOtherwise() {
    #expect(DocumentType.passport.captureMode == .frontOnly)
    #expect(DocumentType.idCard.captureMode == .frontAndBack)
    #expect(DocumentType.driversLicense.captureMode == .frontAndBack)
}

@Test func allCasesIncludesAuto() {
    #expect(DocumentType.allCases.contains(.auto))
    #expect(DocumentType.allCases.count == 4)
}

@Test func pickerSubsetIsExactlyTheThreePickableTypes() {
    // The doc-type picker surfaces `allCases` minus `.auto`.
    let pickable = DocumentType.allCases.filter { $0 != .auto }
    #expect(pickable == [.passport, .idCard, .driversLicense])
}
