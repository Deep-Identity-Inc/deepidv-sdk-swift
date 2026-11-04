import Foundation
import Testing

@testable import DeepIDVCore

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func confirmed(
    _ id: String = "gb_dvla_dl", source: TypeSource = .api, strength: TypeStrength = .strong,
    confidence: Double = 0.91, votes: Int = 4, rotation: Int = 0, modelVersion: String? = "m-test"
) -> ClassifierScanPolicy.Confirmed {
    ClassifierScanPolicy.Confirmed(
        id: id, confidence: confidence, kind: DocumentClassCatalog.kind(of: id),
        group: DocumentClassCatalog.group(of: id), source: source, strength: strength,
        top3: [
            .init(id: id, confidence: confidence), .init(id: "gb_dvla_dl_prov", confidence: 0.04),
            .init(id: "ca_on_dl", confidence: 0.01), .init(id: "us_ga_dl", confidence: 0.005),
        ],
        votes: votes, modelVersion: modelVersion, captureRotation: rotation)
}

private let uploads: [SessionUploadSlot: String] = [
    .idFront: "k/id_front.jpg", .idBack: "k/id_back.jpg", .selfieFront: "k/selfie_front.jpg",
]

@Suite struct CaptureClassificationEncodingTests {
    // MARK: Nothing else changes

    @Test func aSubmissionWithoutTheClassifierEncodesExactlyAsBefore() throws {
        let submission = IDVerificationSubmission(
            documentType: "drivers-license", secondaryDocumentType: "passport",
            uploads: uploads.merging([.secondaryIDFront: "k/secondary_id_front.jpg"]) { a, _ in a })
        // The 1.2.1 wire form, keys sorted.
        let golden =
            #"{"document_type":"drivers-license","secondary_document_type":"passport","#
            + #""uploads":{"id_back":"k/id_back.jpg","id_front":"k/id_front.jpg","#
            + #""secondary_id_front":"k/secondary_id_front.jpg","selfie_front":"k/selfie_front.jpg"}}"#
        #expect(try json(submission) == golden)
        #expect(!submission.hasClassifierFields)
        // Empty classifier fields change nothing either.
        let empty = submission.withClassifierFields(
            CaptureClassificationPayload(), extraFrames: [:])
        #expect(try json(empty) == golden)
        #expect(empty == submission)
    }

    // MARK: One tier

    @Test func aTierEncodesInSnakeCaseWithTheDiagnostics() throws {
        var log = FrameLog(startedAt: 10)
        let decision = ScanDecision(
            .classified, source: .api, strength: .strong,
            answer: DetectAnswer(
                present: true,
                documentType: .init(
                    id: "gb_dvla_dl", confidence: 0.9104,
                    top3: [
                        .init(id: "gb_dvla_dl", confidence: 0.9104),
                        .init(id: "gb_dvla_dl_prov", confidence: 0.04),
                    ])),
            doc: ScanDoc(id: "gb_dvla_dl", confidence: 0.9104))
        log.add(decision, at: 11.8404, rotation: 0, area: 0.62, edge: 0.0312)
        let tier = TierCaptureClassification(confirmed(), captureMode: .auto, frames: log.frames)
        let golden =
            #"{"capture_mode":"auto","capture_rotation":0,"confidence":0.91,"#
            + #""diagnostics":{"frames":[{"area":0.62,"conf":0.91,"decision":"classified","edge":0.031,"#
            + #""margin":0.87,"rot":0,"t":1840,"top1":"gb_dvla_dl"}],"orientation_mode":"none"},"#
            + #""document_type":"gb_dvla_dl","model_version":"m-test","#
            + #""top3":[["gb_dvla_dl",0.91],["gb_dvla_dl_prov",0.04],["ca_on_dl",0.01]],"#
            + #""trust":"api","votes":4}"#
        #expect(try json(tier) == golden)
    }

    @Test func noFramesLeavesOutTheDiagnosticsAndAMissingVersionIsNull() throws {
        let tier = TierCaptureClassification(confirmed(modelVersion: nil), captureMode: .manual)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(tier)) as? [String: Any])
        #expect(object["diagnostics"] == nil)
        #expect(object["model_version"] is NSNull)
        #expect(object["capture_mode"] as? String == "manual")
    }

    @Test func trustFollowsSourceAndStrength() {
        #expect(CaptureTrust(source: .api, strength: .weak) == .api)
        #expect(CaptureTrust(source: .vote, strength: .strong) == .strongVote)
        #expect(CaptureTrust(source: .vote, strength: .margin) == .marginVote)
        #expect(CaptureTrust(source: .vote, strength: .weak) == .weakVote)
        #expect(CaptureTrust.allWireValues == ["api", "strong_vote", "margin_vote", "weak_vote"])
    }

    @Test func valuesAreClampedAndTop3Trimmed() {
        let tier = TierCaptureClassification(
            confirmed(confidence: 1.2, votes: 9, rotation: 180), captureMode: .auto)
        #expect(tier.confidence == 1)
        #expect(tier.votes == 5)
        #expect(tier.top3.count == 3)
        #expect(tier.captureRotation == 180)
    }

    // MARK: The frame log

    @Test func theFrameLogKeepsTheLastTwelveAnsweredFrames() {
        var log = FrameLog(startedAt: 0)
        let answered = ScanDecision(.identifying, answer: DetectAnswer(present: true))
        for i in 0..<15 { log.add(answered, at: Double(i) * 0.5, rotation: 0) }
        log.add(ScanDecision(.error), at: 9, rotation: 0)
        #expect(log.frames.count == FrameLog.capacity)
        #expect(log.frames.first?.t == 1500)
        #expect(log.frames.last?.t == 7000)
        #expect(
            log.frames.allSatisfy {
                $0.decision == "identifying" && $0.top1 == nil && $0.conf == nil
            })
    }

    @Test func probesAreLoggedWithoutOnDeviceMeasurements() throws {
        var log = FrameLog(startedAt: 0)
        log.addProbe(detectFrame("ca_on_dl", 0.87), at: 2, rotation: 180)
        log.addProbe(.failure(status: 503), at: 3, rotation: 180)
        #expect(log.frames.count == 1)
        let frame = try #require(log.frames.first)
        #expect(frame.decision == "wrong_way_probe")
        #expect(frame.rot == 180)
        #expect(frame.area == nil && frame.edge == nil)
        #expect(
            try json(frame)
                == #"{"area":null,"conf":0.87,"decision":"wrong_way_probe","edge":null,"margin":0.83,"rot":180,"t":2000,"top1":"ca_on_dl"}"#
        )
    }

    @Test func decisionNamesFitTheServerLimit() {
        let names = [ScanDecision.Key.error, .noID, .quality, .identifying, .classified].map(
            \.diagnosticName)
        #expect(names == ["error", "no_id", "quality", "identifying", "classified"])
        #expect((names + [FrameDiagnostic.probeDecision]).allSatisfy { $0.count <= 24 })
    }

    // MARK: The submission field

    @Test func aRetakeReplacesItsTierAndAnUnconfirmedFrontRemovesIt() {
        var payload = CaptureClassificationPayload()
        payload.recordFront(.primary, TierCaptureClassification(confirmed(), captureMode: .auto))
        payload.recordFront(
            .primary, TierCaptureClassification(confirmed(votes: 2), captureMode: .manual))
        #expect(payload.tiers[.primary]?.votes == 2)
        payload.recordFront(.primary, nil)
        #expect(payload.isEmpty)
    }

    @Test func onlyTiersWhoseFrontIsSubmittedAreSent() throws {
        var payload = CaptureClassificationPayload()
        payload.recordFront(.primary, TierCaptureClassification(confirmed(), captureMode: .auto))
        payload.recordFront(
            .secondary, TierCaptureClassification(confirmed("ca_on_dl"), captureMode: .auto))
        let sent = try #require(payload.sent(with: uploads))
        #expect(Array(sent.tiers.keys) == [.primary])
        #expect(payload.sent(with: [.selfieFront: "k"]) == nil)
    }

    @Test func theSubmissionCarriesTheClassificationAndExtrasBesideUploads() throws {
        var payload = CaptureClassificationPayload()
        payload.recordFront(.primary, TierCaptureClassification(confirmed(), captureMode: .auto))
        payload.recordFront(
            .secondary, TierCaptureClassification(confirmed("ca_on_dl"), captureMode: .auto))
        let submission = IDVerificationSubmission(documentType: "drivers-license", uploads: uploads)
            .withClassifierFields(
                payload,
                extraFrames: [
                    .idFront1: "k/x1.jpg", .idFront2: "k/x2.jpg", .secondaryIDFront1: "k/stale.jpg",
                ])
        #expect(submission.hasClassifierFields)

        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(submission))
                as? [String: Any])
        let classification = try #require(object["capture_classification"] as? [String: Any])
        #expect(Set(classification.keys) == ["primary"])
        #expect(
            (classification["primary"] as? [String: Any])?["document_type"] as? String
                == "gb_dvla_dl")
        #expect(
            object["extra_frame_uploads"] as? [String: String] == [
                "id_front_extra_1": "k/x1.jpg", "id_front_extra_2": "k/x2.jpg",
            ])
        let sentUploads = try #require(object["uploads"] as? [String: String])
        #expect(
            Set(sentUploads.keys) == ["id_front", "id_back", "selfie_front"],
            "extras never go in uploads")

        // The fallback for an older server drops both fields and nothing else.
        let plain = IDVerificationSubmission(documentType: "drivers-license", uploads: uploads)
        #expect(try json(submission.withoutClassifierFields) == json(plain))
    }

    @Test func extraFrameSlotsAreNamedPerTier() {
        #expect(ExtraFrameSlot(tier: .primary, number: 1) == .idFront1)
        #expect(ExtraFrameSlot(tier: .tertiary, number: 2) == .tertiaryIDFront2)
        #expect(ExtraFrameSlot(tier: .primary, number: 3) == nil)
        #expect(
            ExtraFrameSlot.allCases.map(\.rawValue) == [
                "id_front_extra_1", "id_front_extra_2", "secondary_id_front_extra_1",
                "secondary_id_front_extra_2", "tertiary_id_front_extra_1",
                "tertiary_id_front_extra_2",
            ])
        #expect(
            ExtraFrameSlot.allCases.allSatisfy { $0.rawValue.hasPrefix($0.tier.frontSlot.rawValue) }
        )
    }
}

extension CaptureTrust {
    fileprivate static var allWireValues: [String] {
        [CaptureTrust.api, .strongVote, .marginVote, .weakVote].map(\.rawValue)
    }
}
