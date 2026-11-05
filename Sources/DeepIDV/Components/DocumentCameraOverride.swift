// DeepIDV › Components

import DeepIDVCore
import SwiftUI

private struct DocumentCameraKey: EnvironmentKey {
    static let defaultValue: DocumentCamera? = nil
}

extension EnvironmentValues {
    /// The camera a public view was asked to use for documents, over the
    /// client's ``DeepIDVConfig/documentCamera``; `nil` keeps the config's.
    var documentCameraOverride: DocumentCamera? {
        get { self[DocumentCameraKey.self] }
        set { self[DocumentCameraKey.self] = newValue }
    }
}
