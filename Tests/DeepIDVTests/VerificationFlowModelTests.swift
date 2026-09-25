import Foundation
import Testing

@testable import DeepIDV

// The drop-in orchestration, driven as a pure state machine (the camera
// sub-steps are tested separately): pick → document → selfie → (anti-cheat) →
// verifyIdentity → aggregate. The `verify` seam is a spy, so no transport is
// needed.

private func jpeg() -> FileInput { .data(Data([0xFF, 0xD8, 0xFF, 0xE0])) }

private func stubVerifyResult() -> IdentityVerifyResult {
    IdentityVerifyResult(
        verified: true,
        document: .init(
            documentType: "national_id", fullName: "Ada Lovelace", firstName: "Ada",
            lastName: "Lovelace", dateOfBirth: "1815-12-10", gender: "F", nationality: "GB",
            documentNumber: "X1", expirationDate: "2030-01-01", issuingCountry: "GB",
            address: nil, confidence: 95),
        faceDetection: .init(faceDetected: true, confidence: 99),
        faceMatch: .init(isMatch: true, confidence: 97, threshold: 80),
        overallConfidence: 96,
        documentFrontKey: "df", documentBackKey: nil, selfieKey: "sf")
}

private final class VerifySpy: @unchecked Sendable {
    var calls: [(front: FileInput, back: FileInput?, selfie: FileInput, type: DocumentType)] = []
    var result: IdentityVerifyResult
    var error: DeepIDVError?
    init(result: IdentityVerifyResult) { self.result = result }
    func verify(
        _ front: FileInput, _ back: FileInput?, _ selfie: FileInput, _ type: DocumentType
    ) async throws -> IdentityVerifyResult {
        calls.append((front, back, selfie, type))
        if let error { throw error }
        return result
    }
}

private final class ResultSpy: @unchecked Sendable {
    var result: Result<DeepIDVVerificationResult, DeepIDVError>?
    var value: DeepIDVVerificationResult? {
        if case .success(let value) = result { return value }
        return nil
    }
    var isSuccess: Bool {
        if case .success = result { return true }
        return false
    }
    var failureKind: DeepIDVError.Kind? {
        if case .failure(let error) = result { return error.kind }
        return nil
    }
}

@MainActor
private func makeFlow(
    verifySpy: VerifySpy,
    resultSpy: ResultSpy
) -> VerificationFlowModel {
    VerificationFlowModel(
        verify: { front, back, selfie, type in
            try await verifySpy.verify(front, back, selfie, type)
        },
        onResult: { resultSpy.result = $0 })
}

// MARK: - Happy path

@MainActor @Test func runsPickerDocumentSelfieThenVerify() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let resultSpy = ResultSpy()
    let flow = makeFlow(verifySpy: verifySpy, resultSpy: resultSpy)

    flow.selectType(.idCard)
    #expect(flow.step == .captureDocument)
    #expect(flow.documentType == .idCard)

    flow.documentCaptured(front: jpeg(), back: jpeg())
    #expect(flow.step == .captureSelfie)

    await flow.selfieCaptured(jpeg())

    #expect(verifySpy.calls.count == 1)
    #expect(verifySpy.calls.first?.type == .idCard)
    #expect(verifySpy.calls.first?.back != nil)  // card → back captured
    #expect(resultSpy.isSuccess)
    #expect(resultSpy.value?.identity.verified == true)
}

@MainActor @Test func passportIsFrontOnly() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let resultSpy = ResultSpy()
    let flow = makeFlow(verifySpy: verifySpy, resultSpy: resultSpy)

    flow.selectType(.passport)
    flow.documentCaptured(front: jpeg(), back: nil)
    await flow.selfieCaptured(jpeg())

    #expect(verifySpy.calls.count == 1)
    #expect(verifySpy.calls.first?.type == .passport)
    #expect(verifySpy.calls.first?.back == nil)
    #expect(resultSpy.isSuccess)
}

// MARK: - Failure & control paths

@MainActor @Test func aVerifyErrorPropagatesUnchanged() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    verifySpy.error = .rateLimit("slow down")
    let resultSpy = ResultSpy()
    let flow = makeFlow(verifySpy: verifySpy, resultSpy: resultSpy)

    flow.selectType(.idCard)
    flow.documentCaptured(front: jpeg(), back: jpeg())
    await flow.selfieCaptured(jpeg())

    #expect(verifySpy.calls.count == 1)
    #expect(resultSpy.failureKind == .rateLimit)
}

@MainActor @Test func aDocumentFailureEndsTheFlowWithoutVerifying() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let resultSpy = ResultSpy()
    let flow = makeFlow(verifySpy: verifySpy, resultSpy: resultSpy)

    flow.selectType(.idCard)
    flow.documentFailed(.captureFailed("camera died"))

    #expect(resultSpy.failureKind == .captureFailed)
    #expect(verifySpy.calls.isEmpty)
}

@MainActor @Test func aSelfieFailureEndsTheFlowWithoutVerifying() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let resultSpy = ResultSpy()
    let flow = makeFlow(verifySpy: verifySpy, resultSpy: resultSpy)

    flow.selectType(.idCard)
    flow.documentCaptured(front: jpeg(), back: jpeg())
    flow.selfieFailed(.captureFailed("no face"))

    #expect(resultSpy.failureKind == .captureFailed)
    #expect(verifySpy.calls.isEmpty)
}

@MainActor @Test func cancelMidFlowSurfacesCancelled() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let resultSpy = ResultSpy()
    let flow = makeFlow(verifySpy: verifySpy, resultSpy: resultSpy)

    flow.selectType(.idCard)
    flow.cancel()

    #expect(resultSpy.failureKind == .cancelled)
    #expect(verifySpy.calls.isEmpty)

    // Terminal — a later selfie does nothing.
    await flow.selfieCaptured(jpeg())
    #expect(verifySpy.calls.isEmpty)
}

// MARK: - Anti-cheat step (iGaming)

private final class AntiCheatSpy: @unchecked Sendable {
    var calls: [FileInput] = []
    var result = AntiCheatResult(verdict: .unique, action: .allow)
    var error: DeepIDVError?
    func check(_ image: FileInput) async throws -> AntiCheatResult {
        calls.append(image)
        if let error { throw error }
        return result
    }
}

@MainActor
private func makeIGamingFlow(
    verifySpy: VerifySpy,
    antiCheatSpy: AntiCheatSpy,
    resultSpy: ResultSpy
) -> VerificationFlowModel {
    VerificationFlowModel(
        antiCheat: { image in try await antiCheatSpy.check(image) },
        verify: { front, back, selfie, type in
            try await verifySpy.verify(front, back, selfie, type)
        },
        onResult: { resultSpy.result = $0 })
}

@MainActor @Test func antiCheatRunsBetweenSelfieAndVerifyAndRidesTheAggregate() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let antiCheatSpy = AntiCheatSpy()
    antiCheatSpy.result = AntiCheatResult(verdict: .duplicate, action: .flag)
    let resultSpy = ResultSpy()
    let flow = makeIGamingFlow(
        verifySpy: verifySpy, antiCheatSpy: antiCheatSpy, resultSpy: resultSpy)

    flow.selectType(.passport)
    flow.documentCaptured(front: jpeg(), back: nil)
    await flow.selfieCaptured(jpeg())

    // A flagged duplicate does NOT abort — the host reads it off the aggregate.
    #expect(antiCheatSpy.calls.count == 1)
    #expect(verifySpy.calls.count == 1)
    #expect(resultSpy.value?.antiCheat == AntiCheatResult(verdict: .duplicate, action: .flag))
}

@MainActor @Test func antiCheatReusesTheCapturedSelfieImage() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let antiCheatSpy = AntiCheatSpy()
    let resultSpy = ResultSpy()
    let flow = makeIGamingFlow(
        verifySpy: verifySpy, antiCheatSpy: antiCheatSpy, resultSpy: resultSpy)

    let selfie = FileInput.data(Data([0xAA, 0xBB]))
    flow.selectType(.passport)
    flow.documentCaptured(front: jpeg(), back: nil)
    await flow.selfieCaptured(selfie)

    if case .data(let sent) = antiCheatSpy.calls.first {
        #expect(sent == Data([0xAA, 0xBB]))
    } else {
        Issue.record("anti-cheat did not receive the captured selfie")
    }
}

@MainActor @Test func blockedAntiCheatEndsTheFlowWithoutVerify() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let antiCheatSpy = AntiCheatSpy()
    antiCheatSpy.result = AntiCheatResult(verdict: .duplicate, action: .block)
    let resultSpy = ResultSpy()
    let flow = makeIGamingFlow(
        verifySpy: verifySpy, antiCheatSpy: antiCheatSpy, resultSpy: resultSpy)

    flow.selectType(.passport)
    flow.documentCaptured(front: jpeg(), back: nil)
    await flow.selfieCaptured(jpeg())

    #expect(verifySpy.calls.isEmpty)
    #expect(resultSpy.failureKind == .antiCheatBlocked)
}

@MainActor @Test func antiCheatErrorEndsTheFlowLikeOtherSteps() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let antiCheatSpy = AntiCheatSpy()
    antiCheatSpy.error = .notFound("Session not found")
    let resultSpy = ResultSpy()
    let flow = makeIGamingFlow(
        verifySpy: verifySpy, antiCheatSpy: antiCheatSpy, resultSpy: resultSpy)

    flow.selectType(.passport)
    flow.documentCaptured(front: jpeg(), back: nil)
    await flow.selfieCaptured(jpeg())

    #expect(verifySpy.calls.isEmpty)
    #expect(resultSpy.failureKind == .notFound)
}

@MainActor @Test func flowWithoutAntiCheatOperationSkipsTheStepEntirely() async {
    let verifySpy = VerifySpy(result: stubVerifyResult())
    let resultSpy = ResultSpy()
    let flow = makeFlow(verifySpy: verifySpy, resultSpy: resultSpy)

    flow.selectType(.passport)
    flow.documentCaptured(front: jpeg(), back: nil)
    await flow.selfieCaptured(jpeg())

    #expect(resultSpy.isSuccess)
    #expect(resultSpy.value?.antiCheat == nil)
}
