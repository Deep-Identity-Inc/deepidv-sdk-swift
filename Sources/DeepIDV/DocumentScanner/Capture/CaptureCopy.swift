// DeepIDV › DocumentScanner › Capture

import DeepIDVCore
import Foundation

/// The words on the capture screen: a title and a subtitle for each stage,
/// worded for the document and side being captured.
///
/// Every line has a stable `key`, so a host can later replace any of them
/// without the screen changing shape.
struct CaptureCopy: Sendable, Hashable {
    var title: String
    var subtitle: String?

    /// What the screen is capturing, for the wording.
    struct Context: Sendable, Hashable {
        var documentType: DocumentType
        var isBack = false
        var isFinalSide = true
    }

    /// The fixed line under the frame.
    static let encryption = "Protected by TripleLock® Encryption System"
    /// The subtitle while the camera waits for a good frame.
    static let automatic = "The photo will be taken automatically"

    /// The title and subtitle for `stage`.
    static func lines(for stage: CaptureStage, in context: Context) -> CaptureCopy {
        let noun = noun(for: context.documentType)
        switch stage {
        case .findDocument:
            if context.isBack {
                return .init(title: "Fill the frame with the back of your \(noun)", subtitle: automatic)
            }
            if context.documentType == .passport {
                return .init(title: "Fill the frame with your passport photo page", subtitle: automatic)
            }
            return .init(title: "Fill the frame with your \(noun)", subtitle: automatic)
        case .adjust(.turnToLandscape):
            return .init(title: "Turn your \(noun) sideways", subtitle: "Hold it so it's wider than it is tall")
        case .adjust(.moveCloser):
            return .init(title: "Move a little closer", subtitle: "Your \(noun) should fill the frame")
        case .adjust(.fitInFrame):
            return .init(title: "Fit the whole \(noun) in the frame", subtitle: "Keep all four corners in view")
        case .adjust(.reduceGlare):
            return .init(title: "Avoid the glare", subtitle: "Tilt it slightly away from the light")
        case .checking:
            return .init(title: "Checking your \(noun)…", subtitle: "Hold it steady for a moment")
        case .turnOver:
            return .init(title: "Your \(noun) is upside down", subtitle: "Turn it the right way up")
        case .wrongDocument(let kind):
            return .init(
                title: "This looks like \(CaptureStage.kindLabel(kind))",
                subtitle: "Please use your \(noun) instead")
        case .healthCard:
            return .init(title: "Health cards can't be used", subtitle: "Please use a different ID")
        case .holdStill:
            return .init(title: "Hold still…", subtitle: "Taking the photo")
        case .captured:
            if context.isFinalSide {
                return .init(title: "All done!", subtitle: "Your \(noun) was captured")
            }
            return .init(title: "Front captured", subtitle: nil)
        case .flip:
            return .init(title: "Now show the back of your \(noun)", subtitle: "Turn it over")
        case .processing:
            return .init(title: "Analyzing…", subtitle: "This only takes a moment")
        }
    }

    /// The document in a sentence: "license", "ID card", "passport".
    static func noun(for type: DocumentType) -> String {
        switch type {
        case .driversLicense: return "license"
        case .idCard: return "ID card"
        case .passport: return "passport"
        case .auto: return "ID"
        }
    }
}
