// A host-app switch over an SDK enum that lists every case known today and has
// no `@unknown default`. It must NOT compile: the SDK's public enums can gain
// cases in a later release, and the compiler has to tell hosts to plan for it.
// `.github/checks/check-nonexhaustive.sh` type-checks this file and passes only when
// the compiler rejects the switch.

import DeepIDV

func describe(_ kind: DeepIDVError.Kind) -> String {
    switch kind {
    case .authentication: return "authentication"
    case .authorization: return "authorization"
    case .notFound: return "notFound"
    case .validation: return "validation"
    case .insufficientFunds: return "insufficientFunds"
    case .rateLimit: return "rateLimit"
    case .serviceUnavailable: return "serviceUnavailable"
    case .api: return "api"
    case .network: return "network"
    case .timeout: return "timeout"
    case .cameraPermissionDenied: return "cameraPermissionDenied"
    case .cancelled: return "cancelled"
    case .captureFailed: return "captureFailed"
    case .antiCheatBlocked: return "antiCheatBlocked"
    case .conflict: return "conflict"
    }
}
