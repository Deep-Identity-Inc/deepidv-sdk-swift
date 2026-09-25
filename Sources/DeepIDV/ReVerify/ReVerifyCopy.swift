// DeepIDV › ReVerify

import DeepIDVCore

/// Applicant-facing text for the re-verify view's `failed` phase — the only
/// on-screen error the view has.
///
/// Never reads `DeepIDVError.message`: outside the re-verification codes it is
/// whatever the server body carried (`"ServerError"`, `"InvalidBody"`, a
/// sandbox message), and a 401's includes the redacted API key. The host still
/// gets the untouched error through `onResult`.
enum ReVerifyCopy {
    /// Checks `code` first, then falls back to `kind`. Whether the screen offers
    /// "Try again" is the model's `canRetry`, not decided here.
    static func message(for error: DeepIDVError) -> String {
        if error.code == "liveness_not_started" {
            return "Your check didn't go through. Please try again."
        }
        switch error.kind {
        case .network, .timeout:
            return "We couldn't reach the server. Check your connection and try again."
        case .rateLimit, .serviceUnavailable, .api:
            return "The service is busy right now. Please try again in a moment."
        case .captureFailed:
            return "We couldn't capture your face. Please try again."
        case .cameraPermissionDenied:
            return "Allow camera access in Settings to continue."
        case .authentication:
            return "Re-verification isn't set up correctly. Please contact support."
        case .validation:
            return "Something went wrong. Please contact support."
        default:
            return "Something went wrong. Please try again."
        }
    }
}
