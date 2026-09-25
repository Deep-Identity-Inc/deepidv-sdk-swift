# Changelog

All notable changes to the deepidv iOS SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/compare/1.0.2...HEAD
[1.0.2]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/Deep-Identity-Inc/deepidv-sdk-swift/tree/1.0.0
