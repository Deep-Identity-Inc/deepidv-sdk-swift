import Foundation

/// Builds the HTTP headers for a deepidv request
///
/// Always includes `x-api-key` and `Accept: application/json`
///
/// Adds `Content-Type: application/json` only when a request body is present
func buildHeaders(apiKey: String, hasBody: Bool = false) -> [String: String] {
    var headers = [
        "x-api-key": apiKey,
        "Accept": "application/json",
    ]
    if hasBody {
        headers["Content-Type"] = "application/json"
    }
    return headers
}

/// Constructs a full URL by joining a base URL and a path segment
///
/// Normalizes trailing slashes on the base and leading slashes on the path
/// so callers don't need to be careful about slash presence
func buildURL(base: String, path: String) -> URL {
    let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
    let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path

    let urlString = "\(cleanBase)/\(cleanPath)"
    guard let url = URL(string: urlString) else {
        fatalError("Invalid URL: \(urlString)")
    }

    return url
}
