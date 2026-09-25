import Foundation
import Testing

@testable import DeepIDVCore

@Test func configAppliesDefaultsWhenOnlyApiKeyGiven() {
    let config = DeepIDVConfig(apiKey: "sk_test")
    #expect(config.apiKey == "sk_test")
    #expect(config.baseURL == URL(string: "https://api.deepidv.com")!)
    // Second-equivalents of the TS DEFAULT_* millisecond values.
    #expect(config.timeout == 30)  // 30_000ms
    #expect(config.maxRetries == 3)
    #expect(config.initialRetryDelay == 0.5)  // 500ms
    #expect(config.uploadTimeout == 120)  // 120_000ms
    #expect(config.documentCamera == .back)
    #expect(config.showsDocumentCaptureIntro == true)
}

@Test func configDefaultsMatchStaticConstants() {
    let config = DeepIDVConfig(apiKey: "k")
    #expect(config.baseURL == DeepIDVConfig.defaultBaseURL)
    #expect(config.timeout == DeepIDVConfig.defaultTimeout)
    #expect(config.maxRetries == DeepIDVConfig.defaultMaxRetries)
    #expect(config.initialRetryDelay == DeepIDVConfig.defaultInitialRetryDelay)
    #expect(config.uploadTimeout == DeepIDVConfig.defaultUploadTimeout)
}

@Test func configOverridesAreRespected() {
    let url = URL(string: "https://example.test")!
    let config = DeepIDVConfig(
        apiKey: "k", baseURL: url, timeout: 5, maxRetries: 7,
        initialRetryDelay: 1.5, uploadTimeout: 99)
    #expect(config.baseURL == url)
    #expect(config.timeout == 5)
    #expect(config.maxRetries == 7)
    #expect(config.initialRetryDelay == 1.5)
    #expect(config.uploadTimeout == 99)
}

@Test func configIsEquatable() {
    #expect(DeepIDVConfig(apiKey: "k") == DeepIDVConfig(apiKey: "k"))
    #expect(DeepIDVConfig(apiKey: "k") != DeepIDVConfig(apiKey: "other"))
    #expect(DeepIDVConfig(apiKey: "k") != DeepIDVConfig(apiKey: "k", timeout: 1))
}
