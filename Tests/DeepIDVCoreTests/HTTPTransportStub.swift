import Foundation
import Testing

@testable import DeepIDVCore

/// Concurrency-safe recorder for mutating a collection
/// that records HTTP responses for later inspection.
///
/// Needed to record requests in a concurrency-safe manner
/// for the HTTPTransportStub specifically when mutating the
/// `requests` collection.
actor RequestRecorder {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

/// Testing stub for mocking HTTP transports in tests.
///
/// Uses a handler closure that can be customized by the
/// user for defining custom behaviour for each mocked request.
struct HTTPTransportStub: HTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let recorder = RequestRecorder()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await recorder.record(request)
        return try await handler(request)
    }
}
