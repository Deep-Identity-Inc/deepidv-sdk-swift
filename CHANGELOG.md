# Changelog

All notable changes to the deepidv iOS SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- ID card capture in workflow sessions uses deepidv's document classifier
  when it's available, and falls back to on-device checks otherwise. It
  recognizes the card, waits while a card is held upside down, and never
  auto-captures a health card (the shutter still works). Frames go to the
  same API host as the rest of the session.
  `DeepIDVConfig.usesDocumentClassifier` (default `true`) turns it off.
- Passports auto-capture: the photo page is captured once it has been in
  view and steady for 1.5 s, and the frame on screen is shaped like the
  photo page. A card the classifier names in the passport step ("This looks
  like a driver's license") is never auto-captured; the shutter still works.
- A card held sideways is asked to be turned to landscape.
- The document-capture screen is redesigned: one instruction at a time, a
  frame that changes color as the capture goes, the recognized document's
  name on the frame ("Ontario Driver's License"), a turn-it-over screen for
  documents with a back, a done screen, a tips sheet and VoiceOver
  announcements with haptics. Light and dark appearance follow the system.
- The selfie and face-liveness screens match it: a frosted surround with an
  oval, the instruction above, an oval that changes color as the face settles,
  a ring that fills through the liveness check, a heads-up before the screen
  flashes colors, and the selfie frozen with a tick once taken.
- Every wait, result and error screen shares one design, in light and dark:
  preparing, submitting (with the ID and selfie just taken), try again, errors,
  camera access, and the liveness result.
- A workflow run that is submitted ends on a short thank-you screen ("We've
  received your details"), which closes on its own after 3 s or when tapped,
  then reports the result. It looks the same whatever the decision, so it
  never tells the user whether they passed.
  `DeepIDVConfig.showsCompletionScreen` (default `true`) turns it off.
- The auto-capture "close enough" check follows the frame drawn on screen, so
  a card that fills the frame is always close enough.
- `DeepIDVWorkflowView`, `DeepIDVVerificationView` and `DocumentScannerView`
  take an optional `documentCamera:` that overrides
  `DeepIDVConfig.documentCamera` for that view.
- `.deepIDVAppearance(_:)` styles the SDK's screens with your brand: an
  accent color, success / warning / error colors, a font family (and one for
  titles), the corner radius of buttons and cards, and light or dark. Text on
  a color you set turns black or white, whichever reads. The document frame
  keeps its ID-card shape.
- The screens are in English, Spanish and French. They follow the device's
  language (the first of the user's preferred languages the SDK has, or
  English), or `DeepIDVConfig.language` (`.english`, `.spanish`, `.french`).
  The SDK picks the language itself, so it works even when the app only
  lists English.
- Document capture turns Center Stage off on iPads that have it, so the
  camera doesn't reframe the card while it is photographed. The app's own
  setting is restored afterwards.

### Changed

- **Behavior:** a workflow run's `sessionStatus` uses the same words as
  `GET /v1/sessions/{id}` and the webhooks: an automatic approval reads
  `.verified` (it was `AUTO_APPROVE`) and an automatic decline `.rejected`
  (it was `DECLINED`). Both are new `SessionStatus` constants.
- On-screen text uses US spelling ("license", "color"), except a document's
  official name ("UK Driving Licence").
- The re-verification view has a close button, during the face check and
  while it gets ready, which ends it with `.cancelled`. Hosts no longer
  need to add their own.
- The anti-cheat check's error screen shows our own wording instead of the
  server's message.
- **Behavior:** `DeepIDVConfig.documentCamera` now defaults to `.front`, for
  kiosks and tablets. Pass `.back` to keep the rear camera on a phone.
- **Behavior:** `DeepIDVConfig.showsDocumentCaptureIntro` now defaults to
  `false`. Pass `true` to keep the intro screen.
- **Behavior:** the submitting screen no longer offers Cancel while photos
  are being sent.
- The upside-down check runs beside the normal reads instead of before them,
  so it no longer slows down capturing a card held the right way up.
- The document-type picker is skipped when the workflow allows only one
  document type, and is redesigned as a list of tappable rows.
- An uploaded ID photo (front and back) is cut to the capture frame drawn on
  screen, with a small margin, instead of sending the whole camera view.
  Nothing outside the frame, such as the person holding the card, is sent.
  The cut keeps the camera's own pixels: nothing is enlarged or turned.

## [1.2.1] - 2026-10-13

- `WorkflowUser.phone` is now optional (`String?`), and `phone` defaults to
  `nil` in `WorkflowUser.init`, matching
  `POST /v1/workflows/{workflow_id}/sessions`. A `nil` phone is left out of
  the request body. Workflows with a phone verification step still need a
  phone. Code that reads `user.phone` now gets a `String?`.

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
