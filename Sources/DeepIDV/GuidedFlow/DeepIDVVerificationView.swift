// DeepIDV › GuidedFlow (UI)

import DeepIDVCore
import SwiftUI

/// The drop-in guided flow: a single view that runs the full identity-verify
/// path — document-type select → front/back capture → selfie → server-side
/// document OCR + face detect + face compare — and reports the aggregate
/// ``DeepIDVVerificationResult``.
///
/// Face liveness is not part of this flow: it runs against a workflow session,
/// so hosts that need it use ``DeepIDVWorkflowView``, which runs the
/// `ID_VERIFICATION` and `FACE_LIVENESS` steps in order.
///
/// With `igamingSessionID` supplied, an anti-cheat step (face dedup +
/// self-exclusion) runs between the selfie and verify, **reusing the captured
/// selfie** — no second capture. A `block` action ends the flow as
/// `.antiCheatBlocked`; every other verdict rides
/// ``DeepIDVVerificationResult/antiCheat`` for the host to act on.
///
/// This is the batteries-included counterpart to the composable per-step views
/// (``DocumentScannerView``, ``SelfieCaptureView``, ``DocumentTypePicker``) — a
/// host that doesn't want to assemble its own flow drops this in instead. The
/// camera surface is iOS-only. UIKit hosts wrap it in a `UIHostingController`.
public struct DeepIDVVerificationView: View {
    private let client: DeepIDVClient
    private let igamingSessionID: String?
    private let onResult: (Result<DeepIDVVerificationResult, DeepIDVError>) -> Void

    public init(
        client: DeepIDVClient,
        igamingSessionID: String? = nil,
        onResult: @escaping (Result<DeepIDVVerificationResult, DeepIDVError>) -> Void
    ) {
        self.client = client
        self.igamingSessionID = igamingSessionID
        self.onResult = onResult
    }

    public var body: some View {
        VerificationFlowView(
            client: client, igamingSessionID: igamingSessionID, onResult: onResult)
    }
}

/// The iOS step navigator for the drop-in flow: picker → document capture →
/// selfie → anti-cheat → verifying, driven by a ``VerificationFlowModel``.
/// Internal — hosts use ``DeepIDVVerificationView``.
struct VerificationFlowView: View {
    @StateObject private var model: VerificationFlowModel
    private let client: DeepIDVClient

    init(
        client: DeepIDVClient,
        igamingSessionID: String?,
        onResult: @escaping (Result<DeepIDVVerificationResult, DeepIDVError>) -> Void
    ) {
        self.client = client
        _model = StateObject(
            wrappedValue: VerificationFlowModel(
                antiCheat: igamingSessionID.map { sessionID in
                    { image in
                        try await client.checkAntiCheat(sessionID: sessionID, image: image)
                    }
                },
                verify: { front, back, selfie, type in
                    try await client.verifyIdentity(
                        documentFront: front, documentBack: back, selfie: selfie, type: type)
                },
                onResult: onResult))
    }

    var body: some View {
        switch model.step {
        case .selectType:
            DocumentTypePicker { model.selectType($0) }

        case .captureDocument:
            // Capture only — the raw images go to `verifyIdentity`, which does
            // the document OCR server-side (so no `scanDocument` call here).
            DocumentCaptureFlowView<(FileInput, FileInput?)>(
                documentType: model.documentType,
                cameraPosition: client.config.documentCamera.avPosition,
                showsIntro: client.config.showsDocumentCaptureIntro,
                complete: { front, back, _ in (front, back) },
                onResult: { result in
                    switch result {
                    case .success(let (front, back)):
                        model.documentCaptured(front: front, back: back)
                    case .failure(let error):
                        model.documentFailed(error)
                    }
                })

        case .captureSelfie:
            SelfieCaptureView { result in
                switch result {
                case .success(let selfie):
                    Task { await model.selfieCaptured(selfie) }
                case .failure(let error):
                    model.selfieFailed(error)
                }
            }

        case .antiCheat:
            // Reuses the captured selfie — no second capture; just progress
            // chrome while the dedup/self-exclusion check runs.
            FlowProgressView(text: "Checking your photo…")

        case .verifying:
            FlowProgressView(text: "Verifying your identity…")
        }
    }
}

/// The themed progress screen shared by the flow's two in-flight steps:
/// verify (`/v1/identity/verify`) and anti-cheat (`/v1/igaming/anti-cheat`,
/// which reuses the captured selfie, so there is nothing to show but
/// progress).
private struct FlowProgressView: View {
    @Environment(\.theme) private var theme

    let text: String

    var body: some View {
        VStack(spacing: theme.spacing.md) {
            ProgressView()
            Text(text)
                .font(theme.typography.body())
                .foregroundStyle(theme.colors.grey.s700)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.grey.s50)
    }
}

#Preview {
    let client = DeepIDVClient(apiKey: "sk_test")

    DeepIDVVerificationView(client: client) { result in
        switch result {
        case .success(let outcome):
            print(
                "verified: \(outcome.identity.verified) "
                    + "(\(outcome.identity.overallConfidence)), "
                    + "anti-cheat: \(String(describing: outcome.antiCheat))")
        case .failure(let error):
            print("verify failed: \(error)")
        }
    }
}
