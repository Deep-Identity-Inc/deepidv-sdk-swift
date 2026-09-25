import Testing

@testable import DeepIDV

// MARK: - Pickable types

@Test func pickerOffersExactlyTheThreePickableTypes() {
    // The picker surfaces `allCases` minus `.auto` — capture must know the side
    // count up front, so `.auto` is headless-only.
    #expect(DocumentTypePicker.pickableTypes == [.passport, .idCard, .driversLicense])
    #expect(!DocumentTypePicker.pickableTypes.contains(.auto))
}

@Test func pickerTitlesAreHumanReadable() {
    #expect(DocumentTypePicker.title(for: .passport) == "Passport")
    #expect(DocumentTypePicker.title(for: .idCard) == "ID card")
    #expect(DocumentTypePicker.title(for: .driversLicense) == "Driver's license")
}

// MARK: - Instantiation smoke (theme resolves through the Environment)

@MainActor @Test func phase5ViewsInstantiate() {
    let client = DeepIDVClient(apiKey: "sk_test")
    _ = DocumentTypePicker { _ in }
    _ = CaptureOverlayView(
        instruction: "Scan the front of your document",
        guidance: .holdSteady, manualShutterVisible: true,
        isProcessing: false, permissionDenied: false)
    _ = DocumentScannerView(client: client, documentType: .passport) { _ in }
    #expect(DocumentTypePicker.pickableTypes.count == 3)
}
