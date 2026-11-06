// DeepIDVCore › Config

import Foundation

/// Which camera the document-capture step opens.
@nonexhaustive
public enum DocumentCamera: String, Sendable, Equatable {
    /// The rear camera — the user points the device at the document.
    case back
    /// The front camera (default) — for fixed kiosks / stands where the user holds the
    /// document up to the screen. Stills are captured un-mirrored so OCR sees
    /// the document as printed.
    case front
}

/// The language of the SDK's screens.
@nonexhaustive
public enum DeepIDVLanguage: String, Sendable, Equatable, CaseIterable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
}

/// Configuration for a DeepIDV client.
public struct DeepIDVConfig: Sendable, Equatable {
    /// API key sent as the `x-api-key` header on every request
    public var apiKey: String
    /// Base API URL. The trailing slash is normalized at URL-build
    public var baseURL: URL
    /// Per-attempt request timeout. Each retry attempt gets this full window
    public var timeout: TimeInterval
    /// Maximum retry attempts for 429 and 5xx responses (not counting the initial attempt)
    public var maxRetries: Int
    /// Delay before the first retry; the base for exponential backoff.
    public var initialRetryDelay: TimeInterval
    /// Per-attempt timeout for S3 uploads — separate from `timeout`.
    public var uploadTimeout: TimeInterval
    /// Camera used by the document-capture views. Defaults to `.front`, for
    /// kiosks and tablets where the user holds the ID up to the screen; use
    /// `.back` on a phone pointed at the ID.
    public var documentCamera: DocumentCamera
    /// Whether the document-capture views show the short framing-tips intro
    /// before opening the camera. Defaults to `false`: the camera screen gives
    /// its own instructions.
    public var showsDocumentCaptureIntro: Bool
    /// Whether ID card capture in workflow sessions uses deepidv's document
    /// classifier when it's available, to recognise the card, catch one held
    /// upside down and hold off on health cards. Defaults to `true`. With it off,
    /// or when the classifier isn't available, capture uses on-device checks only.
    public var usesDocumentClassifier: Bool
    /// Whether a workflow run that is submitted ends on a short thank-you
    /// screen before ``DeepIDVWorkflowView`` reports its result. The screen is
    /// the same whatever the decision, so it never tells the user whether
    /// they passed; your app gets the decision in the result. It closes on its
    /// own after a moment, or with its Done button. Defaults to `true`; turn it
    /// off to go straight back to your app.
    public var showsCompletionScreen: Bool
    /// The language of the SDK's screens. `nil` (the default) follows the
    /// device: the first of the user's preferred languages the SDK has, or
    /// English. Set it to match an app with its own language setting.
    public var language: DeepIDVLanguage?

    public init(
        apiKey: String,
        baseURL: URL? = nil,
        timeout: TimeInterval? = nil,
        maxRetries: Int? = nil,
        initialRetryDelay: TimeInterval? = nil,
        uploadTimeout: TimeInterval? = nil,
        documentCamera: DocumentCamera = .front,
        showsDocumentCaptureIntro: Bool = false,
        usesDocumentClassifier: Bool = true,
        showsCompletionScreen: Bool = true,
        language: DeepIDVLanguage? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.timeout = timeout ?? Self.defaultTimeout
        self.maxRetries = maxRetries ?? Self.defaultMaxRetries
        self.initialRetryDelay = initialRetryDelay ?? Self.defaultInitialRetryDelay
        self.uploadTimeout = uploadTimeout ?? Self.defaultUploadTimeout
        self.documentCamera = documentCamera
        self.showsDocumentCaptureIntro = showsDocumentCaptureIntro
        self.usesDocumentClassifier = usesDocumentClassifier
        self.showsCompletionScreen = showsCompletionScreen
        self.language = language
    }
}

extension DeepIDVConfig {
    /// Default API base URL
    public static let defaultBaseURL = URL(string: "https://api.deepidv.com")!
    /// Default per-attempt timeout of 30s
    public static let defaultTimeout: TimeInterval = 30
    /// Default maximum retry attempts
    public static let defaultMaxRetries = 3
    /// Default initial retry delay, 0.5s
    public static let defaultInitialRetryDelay: TimeInterval = 0.5
    /// Default upload timeout, 120s
    public static let defaultUploadTimeout: TimeInterval = 120
}
