// DeepIDVCore › Upload

import Foundation

/// The accepted shapes of a file handed to the uploader.
///
/// An explicit enum — the SDK never guesses whether a `String` is a path,
/// raw base64, or a data URL. The caller states the shape and normalization is a
/// direct `switch` with no heuristics.
public enum FileInput: Sendable {
    /// Raw bytes, ready to upload as-is.
    case data(Data)
    /// A local file URL whose contents are read at upload time.
    case fileURL(URL)
    /// A base64 string — either raw base64 or a `data:<mime>;base64,…` data URL.
    case base64(String)
}

extension FileInput {
    /// Resolves the input to raw bytes.
    ///
    /// `.data` passes through, `.fileURL` is read from disk, and `.base64` has any
    /// `data:<mime>;base64,` prefix stripped before decoding. An unreadable file
    /// or undecodable base64 surfaces as a non-retryable `.validation` error —
    /// both are caller-input problems, caught before any network I/O.
    func normalizedData() throws -> Data {
        switch self {
        case .data(let data):
            return data
        case .fileURL(let url):
            do {
                return try Data(contentsOf: url)
            } catch {
                throw DeepIDVError.validation(
                    "Unable to read file at \(url.path).",
                    causeDescription: error.localizedDescription)
            }
        case .base64(let string):
            guard let data = Data(base64Encoded: Self.stripDataURLPrefix(string)) else {
                throw DeepIDVError.validation("Input is not valid base64-encoded data.")
            }
            return data
        }
    }

    /// Strips an optional `data:<mime>;base64,` prefix, returning the raw base64
    /// payload. A plain base64 string (no prefix) is returned unchanged.
    private static func stripDataURLPrefix(_ string: String) -> String {
        guard string.hasPrefix("data:"), let comma = string.firstIndex(of: ",") else {
            return string
        }
        return String(string[string.index(after: comma)...])
    }
}
