import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

private let restartLimitText = "Your check didn't go through. Please try again."
private let connectionText = "We couldn't reach the server. Check your connection and try again."
private let busyText = "The service is busy right now. Please try again in a moment."
private let captureText = "We couldn't capture your face. Please try again."
private let cameraText = "Allow camera access in Settings to continue."
private let setupText = "Re-verification isn't set up correctly. Please contact support."
private let contactSupportText = "Something went wrong. Please contact support."
private let fallbackText = "Something went wrong. Please try again."

struct ReVerifyCopyTests {
    @Test func livenessNotStartedUsesTheRestartLimitRow() {
        let error = DeepIDVError(
            kind: .conflict, message: "No liveness check is in progress.", status: 409,
            code: "liveness_not_started")
        #expect(ReVerifyCopy.message(for: error) == restartLimitText)
    }

    /// `code` is checked before `kind`: the same code on a kind with its own
    /// row still gets the restart-limit text.
    @Test func codeWinsOverKind() {
        let error = DeepIDVError(
            kind: .network, message: "x", status: nil, code: "liveness_not_started")
        #expect(ReVerifyCopy.message(for: error) == restartLimitText)
    }

    @Test(arguments: [
        (DeepIDVError.network("offline"), connectionText),
        (.timeout("Request timed out after 60.0s"), connectionText),
        (.rateLimit("Too Many Requests"), busyText),
        (.serviceUnavailable("Service Unavailable"), busyText),
        (.api("Bad Gateway", status: 502), busyText),
        (.captureFailed("Liveness capture failed"), captureText),
        (.cameraPermissionDenied("Camera access is required."), cameraText),
        (.authentication("Unauthorized"), setupText),
        (.validation("InvalidBody"), contactSupportText),
        (.conflict("Conflict", info: nil), fallbackText),
        (.notFound("Not Found"), fallbackText),
        (.cancelled("cancelled"), fallbackText),
    ])
    func eachKindMapsToItsRow(error: DeepIDVError, expected: String) {
        #expect(ReVerifyCopy.message(for: error) == expected)
    }

    // MARK: No leak of `message`

    @Test func serverErrorBodyIsNotShown() {
        let error = DeepIDVError.api("ServerError", status: 500)
        let text = ReVerifyCopy.message(for: error)
        #expect(text == busyText)
        #expect(!text.contains("ServerError"))
    }

    @Test func invalidBodyIsNotShown() {
        let error = DeepIDVError.validation("InvalidBody")
        let text = ReVerifyCopy.message(for: error)
        #expect(text == contactSupportText)
        #expect(!text.contains("InvalidBody"))
    }

    @Test func redactedAPIKeyIsNotShown() {
        let error = DeepIDVError.authentication("Unauthorized (api key: sk_...abcd)")
        let text = ReVerifyCopy.message(for: error)
        #expect(text == setupText)
        #expect(!text.contains("sk_"))
    }
}
