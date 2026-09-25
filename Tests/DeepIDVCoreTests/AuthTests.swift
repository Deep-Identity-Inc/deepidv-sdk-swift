import Foundation
import Testing

@testable import DeepIDVCore

@Test func testHeadersWithBodyIncludesContentType() {
    let headersWithBody = buildHeaders(apiKey: "deepidv_api-key", hasBody: true)
    let apiKey = headersWithBody["x-api-key"]
    let acceptHeader = headersWithBody["Accept"]
    let contentTypeHeader = headersWithBody["Content-Type"]

    #expect(apiKey == "deepidv_api-key")
    #expect(acceptHeader == "application/json")
    #expect(contentTypeHeader == "application/json")
}

@Test func testHeadersWithoutBodyOmitsContentType() {
    let headers = buildHeaders(apiKey: "deepidv_api-key", hasBody: false)

    #expect(headers["x-api-key"] == "deepidv_api-key")
    #expect(headers["Accept"] == "application/json")
    #expect(headers["Content-Type"] == nil)
    #expect(headers.count == 2)
}

@Test func testHeadersDefaultsToNoBody() {
    // hasBody defaults to false, so Content-Type should be absent
    let headers = buildHeaders(apiKey: "deepidv_api-key")

    #expect(headers["Content-Type"] == nil)
    #expect(headers.count == 2)
}

@Test func testHeadersWithBodyHasThreeEntries() {
    let headers = buildHeaders(apiKey: "deepidv_api-key", hasBody: true)

    #expect(headers.count == 3)
}

@Test func testHeadersPreserveApiKeyVerbatim() {
    // The key is passed through untouched — no trimming or casing changes
    let rawKey = "  Deepidv_API-Key_123!@#  "
    let headers = buildHeaders(apiKey: rawKey, hasBody: true)

    #expect(headers["x-api-key"] == rawKey)
}

// MARK: - buildURL

// One case per slash combination — all four normalize to the same URL.
@Test(arguments: [
    ("https://api.deepidv.com", "v1/verify"),
    ("https://api.deepidv.com/", "v1/verify"),
    ("https://api.deepidv.com", "/v1/verify"),
    ("https://api.deepidv.com/", "/v1/verify"),
])
func testBuildURLNormalizesSlashes(base: String, path: String) {
    let url = buildURL(base: base, path: path)

    #expect(url.absoluteString == "https://api.deepidv.com/v1/verify")
}

@Test func testBuildURLPreservesMultipleSegments() {
    let url = buildURL(base: "https://api.deepidv.com", path: "v1/sessions/abc123")

    #expect(url.absoluteString == "https://api.deepidv.com/v1/sessions/abc123")
}

@Test func testBuildURLPreservesQueryString() {
    let url = buildURL(base: "https://api.deepidv.com", path: "v1/verify?limit=10&page=2")

    #expect(url.absoluteString == "https://api.deepidv.com/v1/verify?limit=10&page=2")
}

@Test func testBuildURLOnlyDropsASingleSlash() {
    let url = buildURL(base: "https://api.deepidv.com//", path: "//v1/verify")

    #expect(url.absoluteString == "https://api.deepidv.com///v1/verify")
}

@Test func testBuildURLWithEmptyPathTargetsBase() {
    let url = buildURL(base: "https://api.deepidv.com", path: "")

    #expect(url.absoluteString == "https://api.deepidv.com/")
}
