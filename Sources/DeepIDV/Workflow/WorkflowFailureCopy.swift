// DeepIDV › Workflow

import DeepIDVCore

/// Applicant-facing text for every failure and error the workflow views show.
///
/// Never reads `WorkflowFailure.message` or `DeepIDVError.message`: both are
/// developer strings — whatever the server body carried, and a 401's includes
/// the redacted API key. The host still gets the untouched values through
/// `onResult`.
enum WorkflowFailureCopy {
    typealias Copy = (title: String, body: String)

    /// Copy for a failed step attempt. Checks the failure's code first, then
    /// its suggested action, then falls back to a generic line. `step` picks
    /// between the two readings of a liveness ↔ ID mismatch, which can be
    /// reported on either step.
    static func failure(_ failure: WorkflowFailure?, step: WorkflowStepID) -> Copy {
        guard let failure else {
            return (retryTitle, L("We couldn't complete this step. Please try again."))
        }
        switch failure.code {
        case .idFaceNotDetected:
            return (
                L("We couldn't see the photo on your ID"),
                L("Make sure the photo on your ID is clearly visible, then try again.")
            )
        case .idTextNotReadable:
            return (
                L("We couldn't read your ID"),
                L("Place your ID on a flat surface in good light and avoid glare, then try again.")
            )
        case .documentTypeNotAccepted:
            return (L("This document isn't accepted"), L("Please use a different type of ID."))
        case .documentTypeUnrecognized, .documentTypeLowConfidence:
            return (
                L("We couldn't recognize your ID"),
                L(
                    "Make sure you're using the document type you selected, capture the whole document in good light, then try again."
                )
            )
        case .selfieFaceNotDetected:
            return (
                L("We couldn't see your face"),
                L("Look straight at the camera in good light, then take your selfie again.")
            )
        case .selfieMultipleFaces:
            return (
                L("More than one face in your selfie"),
                L("Make sure only you are in the frame, then take your selfie again.")
            )
        case .selfieIDFaceMismatch:
            return (
                L("Your selfie doesn't match your ID"),
                L("Take a clear selfie of yourself, the person on the ID, and try again.")
            )
        case .livenessIDMismatch:
            if step == .idVerification {
                return (
                    L("Your ID doesn't match your face check"),
                    L("Please use your own ID and try again.")
                )
            }
            return (
                L("Your face check doesn't match your ID"),
                L("Please make sure you, the person on the ID, complete the face check.")
            )
        case .livenessFailed:
            return (
                L("We couldn't verify you"),
                L("Follow the on-screen prompts in good light, then try again.")
            )
        default:
            break
        }

        switch failure.userAction {
        case .retakeDocument:
            return (retryTitle, L("Please capture your ID again."))
        case .useDifferentDocument:
            return (retryTitle, L("Please use a different type of ID."))
        case .retakeSelfie:
            return (retryTitle, L("Please take your selfie again."))
        case .retryLiveness:
            return (retryTitle, L("Please complete the face check again."))
        case .retryStep, .none:
            return (retryTitle, L("We couldn't complete this step. Please try again."))
        }
    }

    /// Copy for a run that ended without reaching submission.
    static func sessionFailure(_ failure: WorkflowSessionFailure) -> Copy {
        switch failure.code {
        case .attemptsExhausted:
            return (L("We couldn't verify your identity"), L("You've used all your attempts."))
        case .sessionExpired:
            return (L("This verification has expired"), L("Please start again."))
        default:
            return (L("We couldn't verify your identity"), L("This verification can't continue."))
        }
    }

    /// Copy for an SDK or API error. Checks the server's error code first,
    /// then falls back to the error kind. Whether the screen offers "Try
    /// again" is the model's decision, not made here.
    static func error(_ error: DeepIDVError) -> Copy {
        switch error.apiCode {
        case .sessionTerminal?:
            return (L("Verification finished"), L("This verification is already finished."))
        case .sessionAlreadyStarted?:
            return (L("Verification in progress"), L("This verification has already been started."))
        case .invalidMedia?, .invalidUploadKey?:
            return (errorTitle, L("We couldn't use that photo. Please try again."))
        case .livenessUploadIncomplete?, .livenessNotStarted?, .livenessResultNotReady?:
            return (errorTitle, L("Your check didn't go through. Please try again."))
        case .insufficientFunds?, .workflowInactive?, .unsupportedWorkflowSteps?:
            return (errorTitle, L("Verification isn't available right now. Please contact support."))
        default:
            break
        }

        switch error.kind {
        case .network, .timeout:
            return (
                L("Connection problem"),
                L("We couldn't reach the server. Check your connection and try again.")
            )
        case .rateLimit, .serviceUnavailable, .api:
            return (errorTitle, L("The service is busy right now. Please try again in a moment."))
        case .captureFailed:
            return (errorTitle, L("We couldn't capture your photo. Please try again."))
        case .cameraPermissionDenied:
            return (L("Camera access needed"), L("Allow camera access in Settings to continue."))
        case .authentication, .authorization, .insufficientFunds:
            return (errorTitle, L("Verification isn't set up correctly. Please contact support."))
        case .validation:
            return (errorTitle, L("Something went wrong. Please contact support."))
        case .notFound:
            return (errorTitle, L("We couldn't find this verification. Please contact support."))
        case .conflict:
            return (errorTitle, L("This verification can't continue from here."))
        case .cancelled, .antiCheatBlocked:
            return (errorTitle, L("Something went wrong. Please try again."))
        }
    }

    private static var retryTitle: String { L("Let's try that again") }
    private static var errorTitle: String { L("Something went wrong") }
}
