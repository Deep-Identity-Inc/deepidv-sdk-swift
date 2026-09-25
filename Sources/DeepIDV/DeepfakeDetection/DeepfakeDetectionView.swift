// DeepIDV › DeepfakeDetection (UI)

import DeepIDVCore
import SwiftUI

/// Composable per-step view that runs deepfake detection.
///
/// Internal until the feature ships: the detection pipeline isn't implemented
/// yet, so the body is a themed placeholder and `onResult` is never invoked. Deepfake detection is a
/// synchronous, on-device check (no polling), so the real view reports its result
/// the moment it finishes; the `Void` payload is a placeholder until the detection
/// result model lands with the feature story. UIKit hosts wrap it in a
/// `UIHostingController`.
struct DeepfakeDetectionView: View {
    private let client: DeepIDVClient
    private let onResult: (Result<Void, DeepIDVError>) -> Void

    init(
        client: DeepIDVClient,
        onResult: @escaping (Result<Void, DeepIDVError>) -> Void
    ) {
        self.client = client
        self.onResult = onResult
    }

    var body: some View {
        PlaceholderStepView(title: "Deepfake Detection", subtitle: "Coming soon")
    }
}
