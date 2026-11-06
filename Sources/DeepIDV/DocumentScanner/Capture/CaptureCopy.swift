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
    static var encryption: String { L("Protected by TripleLock® Encryption System") }
    /// The subtitle while the camera waits for a good frame.
    static var automatic: String { L("The photo will be taken automatically") }

    /// The title and subtitle for `stage`.
    static func lines(for stage: CaptureStage, in context: Context) -> CaptureCopy {
        let noun = noun(for: context.documentType)
        switch stage {
        case .findDocument:
            if context.isBack {
                return .init(title: L("Fill the frame with the back of your %@", noun), subtitle: automatic)
            }
            if context.documentType == .passport {
                return .init(title: L("Fill the frame with your passport photo page"), subtitle: automatic)
            }
            return .init(title: L("Fill the frame with your %@", noun), subtitle: automatic)
        case .adjust(.turnToLandscape):
            return .init(title: L("Turn your %@ sideways", noun), subtitle: L("Hold it so it's wider than it is tall"))
        case .adjust(.moveCloser):
            return .init(title: L("Move a little closer"), subtitle: L("Your %@ should fill the frame", noun))
        case .adjust(.fitInFrame):
            return .init(title: L("Fit the whole %@ in the frame", noun), subtitle: L("Keep all four corners in view"))
        case .adjust(.reduceGlare):
            return .init(title: L("Avoid the glare"), subtitle: L("Tilt it slightly away from the light"))
        case .checking:
            return .init(title: L("Checking your %@…", noun), subtitle: L("Hold it steady for a moment"))
        case .turnOver:
            return .init(title: L("Your %@ is upside down", noun), subtitle: L("Turn it the right way up"))
        case .wrongDocument(let kind):
            return .init(
                title: L("This looks like %@", CaptureStage.kindLabel(kind)),
                subtitle: L("Please use your %@ instead", noun))
        case .healthCard:
            return .init(title: L("Health cards can't be used"), subtitle: L("Please use a different ID"))
        case .holdStill:
            return .init(title: L("Hold still…"), subtitle: L("Taking the photo"))
        case .captured:
            if context.isFinalSide {
                return .init(title: L("All done!"), subtitle: L("Your %@ was captured", noun))
            }
            return .init(title: L("Front captured"), subtitle: nil)
        case .flip:
            return .init(title: L("Now show the back of your %@", noun), subtitle: L("Turn it over"))
        case .processing:
            return .init(title: L("Analyzing…"), subtitle: L("This only takes a moment"))
        }
    }

    /// The document in a sentence: "license", "ID card", "passport". Keyed
    /// apart from the picker's titles, which some languages capitalize.
    static func noun(for type: DocumentType) -> String {
        switch type {
        case .driversLicense: return L("noun.license")
        case .idCard: return L("noun.idCard")
        case .passport: return L("noun.passport")
        case .auto: return L("noun.id")
        }
    }
}
