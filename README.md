# deepidv iOS SDK

The iOS SDK for [deepidv](https://deepidv.com) identity verification — built
SwiftUI-first with a UIKit interop path. Capture an ID document and a selfie
on-device, run server-side OCR, face detection, and face matching, and run a
native **face-liveness** check — all with only an `x-api-key`.

- **Workflows** — run a server-defined verification workflow (ID verification →
  face liveness) from one view.
- **Drop-in and composable UI** — a guided identity-verification flow, or the
  individual capture steps to assemble your own.
- **Headless API** — `async` methods that take already-captured images.
- **Re-verification** — recognize a returning applicant by face.
- **iGaming checks** — anti-cheat face dedup, VPN detection, and IP
  jurisdiction.
- **No third-party dependencies** — Apple frameworks only.

## Requirements

- iOS 15+
- Xcode 26+ (Swift 6.2)
- A host **`NSCameraUsageDescription`** for the camera views (see
  [Camera & permissions](#camera--permissions))

The SDK is iOS-only; it doesn't build for macOS.

## Installation

Swift Package Manager. In Xcode: **File ▸ Add Package Dependencies…** and enter
the repository URL:

```
https://github.com/Deep-Identity-Inc/deepidv-sdk-swift
```

Or add it to a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Deep-Identity-Inc/deepidv-sdk-swift", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "DeepIDV", package: "deepidv-sdk-swift")]
    ),
]
```

The package exposes a single product, **`DeepIDV`**.

## Quick start

Configure a client with your `x-api-key`, then call one of the headless methods.
They take already-captured images — no camera involved.

```swift
import DeepIDV

let client = DeepIDVClient(apiKey: "sk_live_…")

// ID scan → OCR. Only the front is OCR'd; a back image (if given) is uploaded and
// its key returned, but not separately scanned. Passports are front-only.
let scan = try await client.scanDocument(
    front: .fileURL(frontImageURL),
    back: .fileURL(backImageURL),     // omit for passports / single-sided
    type: .driversLicense
)
print(scan.fullName, scan.documentNumber, scan.confidence)  // confidence is 0–1

// Identity verify → combined OCR + face detect + face compare.
let verify = try await client.verifyIdentity(
    documentFront: .data(frontJPEG),
    selfie: .data(selfieJPEG),
    type: .passport
)
print(verify.verified, verify.faceMatch.confidence)         // confidences are 0–100
```

A `FileInput` is `.data(Data)`, `.fileURL(URL)`, or `.base64(String)` (raw base64
or a `data:` URL). Images must be JPEG or PNG and ≤ 15 MiB; the SDK uploads each
through a presigned URL before calling the endpoint.

### Document types

`DocumentType` is `.passport`, `.idCard`, `.driversLicense`, or `.auto`. `.auto`
lets the server classify the document and is accepted **only** on the headless
`scanDocument` method — the capture views need an explicit type up front, because
the front-only (passport) vs. front-and-back (cards) capture rule must be known
before the camera starts.

### Configuration

`DeepIDVClient(apiKey:)` applies the defaults. For full control, pass a
`DeepIDVConfig`:

```swift
let config = DeepIDVConfig(
    apiKey: "sk_live_…",
    baseURL: URL(string: "https://api.deepidv.com")!,  // default
    timeout: 30,             // per-attempt seconds
    maxRetries: 3,           // 429 / 5xx
    initialRetryDelay: 0.5,  // backoff base, seconds
    uploadTimeout: 120,      // upload per-attempt seconds
    documentCamera: .back,   // .front for kiosks where the user holds the ID up to the screen
    showsDocumentCaptureIntro: true   // false to skip the framing-tips intro and open the camera directly
)
let client = DeepIDVClient(config: config)
```

The resolved configuration is readable on `client.config`.

## Camera & permissions

The capture views use the camera, so the **host app must declare
`NSCameraUsageDescription`** in its `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Used to scan your ID document and capture a selfie for verification.</string>
```

Before opening the camera, each view checks `AVCaptureDevice` authorization. If
access is **denied or restricted**, the view reports
`onResult(.failure(.cameraPermissionDenied))` **and** shows an in-view button that
deep-links to Settings. If the user **backs out**, the view reports
`onResult(.failure(.cancelled))` — distinct from a real failure, so you can tell
"user quit" apart from an error.

## Privacy manifest

The SDK ships an Apple privacy manifest (`PrivacyInfo.xcprivacy`), which Xcode
includes in your app's privacy report. It declares the data the SDK sends to
deepidv — all linked to the user, used for app functionality (identity
verification and fraud prevention), and never for tracking:

- **Photos or Videos** — ID document images, selfies, liveness frames, and the
  liveness replay clip.
- **Sensitive Info** — biometric use of face images (face match, liveness, face
  search).
- **Name, Email Address, Phone Number** — the `WorkflowUser` fields, when the SDK
  creates a workflow session.

The SDK uses none of Apple's required-reason APIs.

Two values are sent only when **your app** supplies them, so declare them in
your own manifest if you use them: the `deviceFingerprint` passed to
`checkAntiCheat` (Device ID — see [Device fingerprints](#device-fingerprints)) and
the `ipAddress` passed to `checkVPN` / `checkIPJurisdiction`.

## Workflows

`DeepIDVWorkflowView` runs a server-defined verification workflow — for example
**ID verification → face liveness** — step by step against one session. Supported steps are `ID_VERIFICATION` and
`FACE_LIVENESS`; a workflow containing any other step fails with `.validation`.

Let the view create the session:

```swift
DeepIDVWorkflowView(
    client: client,
    workflowID: "wf_…",
    user: WorkflowUser(
        email: "ada@example.com",
        firstName: "Ada",
        lastName: "Lovelace",
        phone: "+15555550100",       // E.164
        externalID: "your-user-id"   // optional
    )
) { result in
    switch result {
    case .success(let run):
        print(run.sessionStatus, run.steps.map(\.status))
    case .failure(let error):
        print("workflow error:", error)
    }
}
```

Or run a session your backend created
(`POST /v1/workflows/{workflow_id}/sessions`), passing the app only its id:

```swift
DeepIDVWorkflowView(client: client, sessionID: sessionID) { result in /* … */ }
```

- The result is a `WorkflowRunResult`: the session's `sessionStatus` and
  `sessionProgress`, plus each step's status, attempt count, and failure reason.
- A run that ends `FAILED` because a step's attempts ran out is still a
  completed run — it arrives on `.success`. `.failure` is reserved for errors
  (network, permission, cancellation, …).
- The final verification decision is made server-side after the run and isn't
  part of the result; read it from your backend.
- A session can only be run once: one that has already started, or is
  terminal, fails with `.conflict`.

The headless helpers `createWorkflowSession(workflowID:user:expiresInHours:)`,
`startWorkflowSession(sessionID:)`, and `fetchWorkflowState(sessionID:)` expose
the same session lifecycle without UI.

## Drop-in guided flow

`DeepIDVVerificationView` runs the whole identity verification in one view:
document-type select → guided front/back capture → selfie → `verifyIdentity`.
It returns `DeepIDVVerificationResult { identity, antiCheat? }`. It doesn't
include face liveness — for identity verification **plus** liveness, use
[`DeepIDVWorkflowView`](#workflows).

```swift
import DeepIDV
import SwiftUI

struct ContentView: View {
    let client = DeepIDVClient(apiKey: "sk_live_…")
    var body: some View {
        DeepIDVVerificationView(client: client) { result in
            switch result {
            case .success(let outcome):
                print("verified:", outcome.identity.verified)
            case .failure(let error):
                print("failed:", error)
            }
        }
    }
}
```

## Composable views

Assemble your own flow from the individual views, each taking a result
callback:

- **`DocumentTypePicker(onSelect:)`** — the document-type selection step
  (Passport / ID card / Driver's license).
- **`DocumentScannerView(client:documentType:onResult:)`** — guided document
  capture and OCR → `DocumentScanResult`.
- **`SelfieCaptureView(onResult:)`** — a front-camera selfie capture that
  returns the captured `FileInput` for you to pass to `verifyIdentity`.
- **`CustomFaceLivenessView(client:sessionID:onResult:)`** — the face-liveness
  check → `FaceLivenessResult` (see [Face liveness](#face-liveness)).
- **`AntiCheatCheckView(client:sessionID:deviceFingerprint:onResult:)`** — face
  capture plus the iGaming anti-cheat check (see [iGaming checks](#igaming-checks)).

Document capture is automatic; if it can't lock within a few seconds (glare, low
light, motion) a **manual shutter** appears so the user is never stuck. Two-sided
documents are captured front then back; passports are front-only.

### UIKit interop

Wrap any SDK view in a `UIHostingController`:

```swift
let vc = UIHostingController(
    rootView: DeepIDVVerificationView(client: client) { result in
        // handle the outcome
    }
)
navigationController?.pushViewController(vc, animated: true)
```

## Face liveness

The simplest way to run liveness is a [workflow](#workflows) with a
`FACE_LIVENESS` step.

To run the liveness step on its own, use `CustomFaceLivenessView` with a
workflow session your backend created. The SDK fetches the challenge, runs the
native capture on-device (face movement, optionally with a colored-light
sequence), uploads the frames, and returns the server-scored outcome:

```swift
CustomFaceLivenessView(client: client, sessionID: sessionID) { result in
    switch result {
    case .success(let liveness):
        // A completed-but-not-live check is a SUCCESS with passed == false,
        // not an error.
        print(liveness.status, liveness.confidence ?? 0, liveness.passed)
    case .failure(let error):
        // Camera permission, cancellation, capture, or network failure.
        print("liveness failed:", error)
    }
}
```

- **Pass/fail is computed server-side**: the challenge type and pass threshold
  live in the workflow step's configuration, and the SDK surfaces `passed`
  verbatim.
- No imagery ever comes back to the app — the result is exactly
  `{ status, confidence?, passed }`.
- `FACE_LIVENESS` must be the session's **current** step: the server runs
  workflow steps in order and rejects an out-of-order submission with
  `.conflict`.
- A not-live result offers **Try again** in the view.
- **Headless.** `client.checkMovementLiveness(sessionID:frames:clip:)` scores
  3–8 frames you captured yourself (movement challenge only). Use
  `client.faceProbe(_:)` on each camera frame to decide when to capture, and
  `client.makeMovementReplayRecorder()` to attach an optional replay clip.

## Re-verify with face search

`client.makeReVerifyView(workflowID:onResult:)` returns a view that
re-verifies a returning applicant. Presenting it creates the re-verification,
runs the liveness challenge, uploads the capture, and reports one result:

```swift
client.makeReVerifyView(workflowID: "wf_…") { result in
    switch result {
    case .success(.verified(let reVerificationID, let originalSessionID, let userID)):
        // The applicant is the user of `originalSessionID`.
        print("re-verified:", userID, originalSessionID, reVerificationID)
    case .success(.failed(let reason)):
        // Not re-verified — show your own copy for `reason`.
        print("not re-verified:", reason)
    case .failure(let error):
        // `.cancelled` means the view was dismissed before an outcome.
        print("re-verification error:", error.kind)
    }
}
```

- **Enrolment is automatic.** Every session approved on a workflow with
  re-verification enabled is enrolled after approval; nothing in the app
  registers faces. The applicant isn't identified up front — they're found by
  face among your organization's approved applicants on that workflow.
- **One sitting.** A failed match or liveness check starts a new challenge in
  place, with guidance and the remaining-attempts count. Network and capture
  errors offer **Try again** (re-running only the call that failed) and
  **Close**. There is no cancel control during capture: dismiss the view to
  cancel.

**Results.** `onResult` fires exactly once:

- `.success(.verified(reVerificationID:originalSessionID:userID:))` — matched to
  exactly one approved session in your organization under this workflow.
- `.success(.failed(reason:))`, with `reason`:
  - `.notReVerified` — the face was recognized, but it can't be re-verified for
    this workflow in your organization. Ends on the first occurrence.
  - `.attemptsExhausted` — the attempt budget is spent, usually because nobody
    was recognized. The server doesn't say why an attempt failed, so a
    recognized-but-ineligible applicant on the **final** allowed attempt (or
    the only one, when the workflow allows one) is also reported here.
  - `.notEligible(_)` — re-verification can't run at all; never fixable by the
    applicant:
    - `.notFound` — the workflow doesn't exist for this API key's organization,
      or re-verification isn't available to the organization;
    - `.disabled` — the workflow is inactive, or re-verification is off on it;
    - `.insufficientBalance` — the organization's balance can't cover the check;
    - `.notAuthorized` — this API key can't use re-verification (for example, a
      sandbox key).
  - `.expired` — the re-verification expired or had already ended before a
    decision. Present the view again to start a new one.
- `.failure(DeepIDVError)` — an error the applicant closed, or `.cancelled` when
  the view was dismissed before an outcome.

**The view renders nothing once `onResult` fires** — no confirmation or failure
screen, no Done button. Dismiss it and show your own result screen, including
your own copy for each failure reason. `DeepIDVError.message` is a developer
string (it can carry raw server text); don't show it to applicants as-is.

## iGaming checks

Anti-cheat (face dedup + self-exclusion), VPN/proxy/Tor detection, and IP
jurisdiction eligibility are workflow-gated checks against a **verification
session your backend already created** (on a workflow with the `anti-cheat` /
`vpn-detection` / `ip-jurisdiction` step) — the SDK only checks against a
session you supply.

### Headless

```swift
let antiCheat = try await client.checkAntiCheat(
    sessionID: sessionID, image: .fileURL(faceImageURL))
if antiCheat.isDuplicate {
    // this face (or its linked identity) is already known — your policy call
}

let vpn = try await client.checkVPN(sessionID: sessionID, ipAddress: publicIP)
let geo = try await client.checkIPJurisdiction(sessionID: sessionID, ipAddress: publicIP)
```

- **`checkAntiCheat(sessionID:image:deviceFingerprint:)`** — face dedup ("has
  this face already signed up?"), self-exclusion, and multi-accounting linkage;
  enrolls the face on first sight.
- **`checkVPN(sessionID:ipAddress:)`** — VPN / proxy / Tor detection.
- **`checkIPJurisdiction(sessionID:ipAddress:)`** — IP jurisdiction eligibility.

The two IP checks are **headless-only, by design**: they take the IP address as
input, and a phone can't reliably know its own public IP. Supply it from your
backend (or your own IP-resolution call).

### Composable — `AntiCheatCheckView`

`AntiCheatCheckView(client:sessionID:deviceFingerprint:onResult:)` captures a
face photo (with the same camera-permission handling as the other views) and
runs the anti-cheat check, reporting the typed `AntiCheatResult` through
`onResult`.

### Guided flow — `igamingSessionID`

Pass `igamingSessionID:` to `DeepIDVVerificationView` to run the anti-cheat
check between the **selfie** and **verify**. It **reuses the captured selfie** —
no second capture. A `block` action ends the flow as
`DeepIDVError.antiCheatBlocked` (the server has already marked the session
failed); every other verdict rides `DeepIDVVerificationResult.antiCheat` for you
to act on.

### Fail-soft semantics

Both check families are **fail-soft**: bad input, a terminal session, an
unconfigured workflow step, or an internal server error all come back as a
normal success — `verdict == .unavailable` with `action == .allow` — never a
thrown error. The only hard failure is a missing session (`.notFound`). Both
verdict enums decode tolerantly, so a value this SDK version doesn't know yet
folds into `.unknown(raw)` rather than failing.

### Device fingerprints

`checkAntiCheat`'s optional `deviceFingerprint` feeds the backend's
multi-account linkage. Pass the SDK's standardized helper:

```swift
let result = try await client.checkAntiCheat(
    sessionID: sessionID, image: image,
    deviceFingerprint: DeviceFingerprint.current())
```

`DeviceFingerprint.current()` is a random UUID minted once and persisted in
the keychain: stable across app reinstalls, per-device (a backup restored
onto new hardware mints a fresh value), no permissions, and not derived from
hardware or user data. It's a linkage *signal*, not security — a wiped device
starts fresh, and the backend weighs it alongside the face-dedup check. If
you adopt it, declare a collected device ID with the fraud-prevention purpose
in your app's privacy manifest. The SDK never attaches it automatically.

## Results & confidence scales

`scanDocument` returns a `DocumentScanResult` (OCR fields + the uploaded image
keys); `verifyIdentity` returns an `IdentityVerifyResult` (`verified`, the OCR
`document`, `faceDetection`, `faceMatch`, and `overallConfidence`, plus the image
keys). The liveness APIs return a `FaceLivenessResult` (`status`, optional
`confidence`, server-computed `passed`), and `DeepIDVVerificationView` returns a
`DeepIDVVerificationResult` — the `identity` result and the optional `antiCheat`
result (`nil` when the flow ran without an `igamingSessionID`).

`checkAntiCheat` returns an `AntiCheatResult` (`verdict` — `.duplicate` /
`.unique` / `.unavailable` / `.selfExclusion` / `.unknown(raw)` — plus the
policy `action`, with `isDuplicate` and `isBlocked` convenience flags).
`checkVPN` and `checkIPJurisdiction` both return an `IPCheckResult` (`verdict` —
`.hit` / `.clear` / `.unavailable` / `.unknown(raw)` — a raw `action` string,
free-form `evidence`, and an optional `escalation` when the workflow routes a
hit to manual handling instead of an outright block).

**Confidence scales differ by endpoint and are preserved as-is** (the SDK never
rescales): `DocumentScanResult.confidence` is **0–1**, while every confidence on
`IdentityVerifyResult` (document, face detection, face match, overall) and
`FaceLivenessResult.confidence` is **0–100**. Each field documents its scale
inline.

## Errors

Everything throwable is the single value type `DeepIDVError`, with a `Kind`
that can grow in future releases — include a `default:` arm when switching on
it:

- HTTP/transport: `.authentication`, `.authorization`, `.notFound`, `.validation`,
  `.insufficientFunds`, `.rateLimit`, `.serviceUnavailable`, `.api`, `.network`,
  `.timeout`, `.conflict`.
- Capture: `.cameraPermissionDenied`, `.cancelled`, `.captureFailed`.
- iGaming: `.antiCheatBlocked` — the guided flow's anti-cheat step returned
  `action == "block"`, ending the flow. Only the guided flow produces this; the
  headless `checkAntiCheat` surfaces a block as a normal `AntiCheatResult`.

429 and 5xx responses are retried with exponential backoff (`maxRetries`);
capture errors are never retried. API keys are redacted everywhere — the full
key is never logged or serialized.

## Theming

SDK views use the deepidv brand — colors, typography, and an 8-point spacing
scale — supplied through the SwiftUI environment. Custom theming isn't
supported yet. Brand fonts aren't bundled, so text renders in the system font.

## Development

The package is iOS-only, so build and test against an iOS simulator:

```sh
xcodebuild test -scheme DeepIDV \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

House style is enforced by
[`swift-format`](https://github.com/swiftlang/swift-format) using the repo
`.swift-format` config (100-column lines, 4-space indentation):

```sh
swift format --in-place --recursive Sources Tests
```

## License

The deepidv iOS SDK is available under the [MIT License](LICENSE).
