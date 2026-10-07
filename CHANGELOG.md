# Changelog

All notable changes to the deepidv iOS SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-10-06

Reverify flow api now accepts the applicants email.

### Changed

- **Breaking:** `makeReVerifyView(workflowID:onResult:)` is replaced by
  `makeReVerifyView(workflowID:email:onResult:)`, because the server now
  requires the applicant's email. You pass the email of a user in your
  organization who was verified on the workflow before; the view never asks
  the applicant for it. A blank email ends the flow with `.failure` (kind
  `.validation`).

### Added

- `ReVerifyResult.NotEligibleReason.userNotFound` and
  `.notPreviouslyVerified`: the email isn't a user in your organization, or
  that user has no verified session under the workflow to match against.

## [1.1.0] - 2026-10-05

Workflow failures are now typed end to end.

### Removed

- `failureReason: String?` on `StepSubmissionResult`, `WorkflowStepState` and
  `WorkflowRunResult.StepOutcome` (including the `failureReason:` parameter of
  their initializers). Use `failure: WorkflowFailure?` instead.
  `ConflictInfo.failureReason` is unchanged.

### Added

- `WorkflowFailure`: why a step attempt failed, with `code`, `category`,
  `userAction`, `isRetryable`, `slot` and `message`. Exposed as `failure` on
  `StepSubmissionResult`, `WorkflowStepState` and
  `WorkflowRunResult.StepOutcome`.
- `WorkflowSessionFailure`: why a run ended without reaching submission, with
  `code`, `stepID` and `failure`. Exposed as `sessionFailure` on
  `StepSubmissionResult`, `WorkflowExecutionState` and `WorkflowRunResult`.
- `WorkflowDocumentSlot`: the document a failure is about.
- `DeepIDVError.apiCode` and `APIErrorCode`: the server's machine-readable
  reason for refusing a request.
- `DeepIDVClient.resumeWorkflowSession(sessionID:)` and
  `DeepIDVWorkflowView(client:resumingSessionID:onResult:)`: continue an
  existing session from its current step. See
  [Resuming a session](README.md#resuming-a-session).

### Changed

- Every public enum with cases is now `@nonexhaustive`: `DeepIDVError.Kind`,
  `WorkflowStepStatus`, `SessionProgress`, `StepRequirements`,
  `FaceLivenessResult.Status`, `ChallengeType`, `DocumentType`, `CaptureMode`,
  `DocumentCamera`, `SessionUploadSlot`, `FileInput`, `IPCheckResult.Verdict`,
  `AntiCheatResult.Verdict`, `AntiCheatResult.Action`, `ReVerifyResult`,
  `ReVerifyResult.FailureReason` and `ReVerifyResult.NotEligibleReason`. A
  `switch` over one must end in `@unknown default` (an error in Swift 6 mode, a
  warning in Swift 5 mode).
- `DeepIDVWorkflowView` shows an error screen when a step ends the run with an
  error. `onResult(.failure)` now fires when the applicant closes that screen
  instead of immediately; cancellation still reports at once. Connectivity and
  server faults offer **Try again**, which continues from the current step.
- The ID verification retry is targeted: a selfie failure retakes only the
  selfie and reuses the uploaded documents, a document type the workflow
  doesn't accept returns to the type picker for that document, and an
  unreadable document is captured again with the same type.
- The workflow screens show the SDK's own text for every failure and error.
  Server strings (`WorkflowFailure.message`, `DeepIDVError.message`) are never
  displayed.
- The liveness retry screen in a workflow explains why the attempt failed,
  including a liveness ↔ ID mismatch.
- A liveness attempt whose frames didn't finish uploading
  (`APIErrorCode.livenessUploadIncomplete`) can be retried in place and doesn't
  end the step.
- `FaceLivenessResult.confidence` is `nil` on a failed workflow liveness
  attempt.

## [1.0.2] - 2026-09-25

### Added

- `SECURITY.md`: how to privately report a security vulnerability, by email to
  [privacy@deepidv.com](mailto:privacy@deepidv.com) or through GitHub's private
  vulnerability reporting.
- `CHANGELOG.md`: release notes for every version, linked from the README.
- CodeQL security scanning of the SDK source, built for the iOS Simulator.

## [1.0.1] - 2026-09-25

### Added

- Apple privacy manifest (`PrivacyInfo.xcprivacy`) declaring the data the SDK
  collects, so it appears in your app's privacy report. See
  [Privacy manifest](README.md#privacy-manifest).

## [1.0.0] - 2026-09-25

Initial public release.

### Added

- `DeepIDVClient` with `x-api-key` authentication, configurable timeouts,
  retries with exponential backoff, and presigned uploads.
- Headless identity APIs: `scanDocument` (OCR) and `verifyIdentity` (OCR, face
  detection, face match).
- Workflows: `DeepIDVWorkflowView` runs `ID_VERIFICATION` → `FACE_LIVENESS`
  workflows, plus `createWorkflowSession`, `startWorkflowSession`, and
  `fetchWorkflowState`.
- Drop-in `DeepIDVVerificationView` for guided identity verification.
- Composable views: `DocumentTypePicker`, `DocumentScannerView`,
  `SelfieCaptureView`, `CustomFaceLivenessView`, `AntiCheatCheckView`.
- Native face liveness, including headless `checkMovementLiveness`,
  `faceProbe`, and `makeMovementReplayRecorder`.
- Re-verification by face search: `makeReVerifyView`.
- iGaming checks: `checkAntiCheat`, `checkVPN`, `checkIPJurisdiction`, and
  `DeviceFingerprint`.
- Typed errors (`DeepIDVError`) and camera-permission handling with a Settings
  deep link.

[Unreleased]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/compare/1.1.0...HEAD
[1.1.0]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/compare/1.0.2...1.1.0
[1.0.2]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/tree/1.0.0
