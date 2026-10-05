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
            return (retryTitle, "We couldn't complete this step. Please try again.")
        }
        switch failure.code {
        case .idFaceNotDetected:
            return (
                "We couldn't see the photo on your ID",
                "Make sure the photo on your ID is clearly visible, then try again."
            )
        case .idTextNotReadable:
            return (
                "We couldn't read your ID",
                "Place your ID on a flat surface in good light and avoid glare, then try again."
            )
        case .documentTypeNotAccepted:
            return ("This document isn't accepted", "Please use a different type of ID.")
        case .documentTypeUnrecognized, .documentTypeLowConfidence:
            return (
                "We couldn't recognise your ID",
                "Make sure you're using the document type you selected, capture the whole "
                    + "document in good light, then try again."
            )
        case .selfieFaceNotDetected:
            return (
                "We couldn't see your face",
                "Look straight at the camera in good light, then take your selfie again."
            )
        case .selfieMultipleFaces:
            return (
                "More than one face in your selfie",
                "Make sure only you are in the frame, then take your selfie again."
            )
        case .selfieIDFaceMismatch:
            return (
                "Your selfie doesn't match your ID",
                "Take a clear selfie of yourself, the person on the ID, and try again."
            )
        case .livenessIDMismatch:
            if step == .idVerification {
                return (
                    "Your ID doesn't match your face check",
                    "Please use your own ID and try again."
                )
            }
            return (
                "Your face check doesn't match your ID",
                "Please make sure you, the person on the ID, complete the face check."
            )
        case .livenessFailed:
            return (
                "We couldn't verify you",
                "Follow the on-screen prompts in good light, then try again."
            )
        default:
            break
        }

        switch failure.userAction {
        case .retakeDocument:
            return (retryTitle, "Please capture your ID again.")
        case .useDifferentDocument:
            return (retryTitle, "Please use a different type of ID.")
        case .retakeSelfie:
            return (retryTitle, "Please take your selfie again.")
        case .retryLiveness:
            return (retryTitle, "Please complete the face check again.")
        case .retryStep, .none:
            return (retryTitle, "We couldn't complete this step. Please try again.")
        }
    }

    /// Copy for a run that ended without reaching submission.
    static func sessionFailure(_ failure: WorkflowSessionFailure) -> Copy {
        switch failure.code {
        case .attemptsExhausted:
            return ("We couldn't verify your identity", "You've used all your attempts.")
        case .sessionExpired:
            return ("This verification has expired", "Please start again.")
        default:
            return ("We couldn't verify your identity", "This verification can't continue.")
        }
    }

    /// Copy for an SDK or API error. Checks the server's error code first,
    /// then falls back to the error kind. Whether the screen offers "Try
    /// again" is the model's decision, not made here.
    static func error(_ error: DeepIDVError) -> Copy {
        switch error.apiCode {
        case .sessionTerminal?:
            return ("Verification finished", "This verification is already finished.")
        case .sessionAlreadyStarted?:
            return ("Verification in progress", "This verification has already been started.")
        case .invalidMedia?, .invalidUploadKey?:
            return (errorTitle, "We couldn't use that photo. Please try again.")
        case .livenessUploadIncomplete?, .livenessNotStarted?, .livenessResultNotReady?:
            return (errorTitle, "Your check didn't go through. Please try again.")
        case .insufficientFunds?, .workflowInactive?, .unsupportedWorkflowSteps?:
            return (errorTitle, "Verification isn't available right now. Please contact support.")
        default:
            break
        }

        switch error.kind {
        case .network, .timeout:
            return (
                "Connection problem",
                "We couldn't reach the server. Check your connection and try again."
            )
        case .rateLimit, .serviceUnavailable, .api:
            return (errorTitle, "The service is busy right now. Please try again in a moment.")
        case .captureFailed:
            return (errorTitle, "We couldn't capture your photo. Please try again.")
        case .cameraPermissionDenied:
            return ("Camera access needed", "Allow camera access in Settings to continue.")
        case .authentication, .authorization, .insufficientFunds:
            return (errorTitle, "Verification isn't set up correctly. Please contact support.")
        case .validation:
            return (errorTitle, "Something went wrong. Please contact support.")
        case .notFound:
            return (errorTitle, "We couldn't find this verification. Please contact support.")
        case .conflict:
            return (errorTitle, "This verification can't continue from here.")
        case .cancelled, .antiCheatBlocked:
            return (errorTitle, "Something went wrong. Please try again.")
        }
    }

    private static let retryTitle = "Let's try that again"
    private static let errorTitle = "Something went wrong"
}
