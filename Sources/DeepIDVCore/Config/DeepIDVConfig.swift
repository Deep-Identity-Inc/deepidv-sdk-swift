// DeepIDVCore › Config

import Foundation

/// Which camera the document-capture step opens.
public enum DocumentCamera: String, Sendable, Equatable {
    /// The rear camera (default) — the user points the device at the document.
    case back
    /// The front camera — for fixed kiosks / stands where the user holds the
    /// document up to the screen. Stills are captured un-mirrored so OCR sees
    /// the document as printed.
    case front
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
    /// Camera used by the document-capture views. Defaults to `.back`.
    public var documentCamera: DocumentCamera
    /// Whether the document-capture views show the short framing-tips intro
    /// before opening the camera. Defaults to `true`; kiosks that give their
    /// own instructions can turn it off to go straight to the viewfinder.
    public var showsDocumentCaptureIntro: Bool

    public init(
        apiKey: String,
        baseURL: URL? = nil,
        timeout: TimeInterval? = nil,
        maxRetries: Int? = nil,
        initialRetryDelay: TimeInterval? = nil,
        uploadTimeout: TimeInterval? = nil,
        documentCamera: DocumentCamera = .back,
        showsDocumentCaptureIntro: Bool = true
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.timeout = timeout ?? Self.defaultTimeout
        self.maxRetries = maxRetries ?? Self.defaultMaxRetries
        self.initialRetryDelay = initialRetryDelay ?? Self.defaultInitialRetryDelay
        self.uploadTimeout = uploadTimeout ?? Self.defaultUploadTimeout
        self.documentCamera = documentCamera
        self.showsDocumentCaptureIntro = showsDocumentCaptureIntro
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
