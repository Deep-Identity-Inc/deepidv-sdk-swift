// DeepIDV › DocumentScanner › Capture

import AVFoundation

/// Camera authorization state, reduced to the three cases the flow branches on.
///
/// `restricted` (parental controls, MDM) folds into `denied` — both mean "we
/// can't use the camera and the user can't grant it from a system prompt," so the
/// flow treats them identically (surface `.cameraPermissionDenied`, offer the
/// Settings deep link).
enum CameraAuthorizationStatus: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
}

/// The camera-permission seam. Abstracted behind a protocol so the capture
/// coordinator's permission branch — grant, deny, and first-time prompt — is
/// testable without touching `AVCaptureDevice`.
protocol CameraAuthorizing: Sendable {
    /// The current authorization status.
    func authorizationStatus() -> CameraAuthorizationStatus
    /// Prompts for access when status is `notDetermined`; returns whether granted.
    func requestAccess() async -> Bool
}

/// The default authorizer for tests and previews: always authorized, so the
/// headless flow runs unobstructed.
struct AlwaysAuthorizedCamera: CameraAuthorizing {
    func authorizationStatus() -> CameraAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

/// The live iOS authorizer, backed by `AVCaptureDevice` video authorization.
struct SystemCameraAuthorizer: CameraAuthorizing {
    func authorizationStatus() -> CameraAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}
