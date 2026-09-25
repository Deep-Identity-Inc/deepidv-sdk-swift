import Foundation

/// A protocol defining an HTTP transport mechanism.
///
/// Implementers of this protocol are responsible for sending HTTP
/// requests and returning the response.
///
/// Any implementation that satifies this protocol can be injected
/// into the APIClient instance for use.
///
/// `package` (not `internal`): `DeepIDVClient` lives in the sibling `DeepIDV`
/// module and holds the transport as its injectable seam, so the type must
/// be visible across the package. `package` keeps it hidden from external
/// clients — `@_exported import DeepIDVCore` only re-exports `public` symbols.
package protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// An implementation of `HTTPTransport` that uses `URLSession` for sending HTTP requests.
///
/// This transport sends requests using the shared `URLSession` and converts the response to `HTTPURLResponse`.
package struct URLSessionTransport: HTTPTransport {
    package init() {}

    package func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepIDVError.network("Server returned a non-HTTP response")
        }
        return (data, httpResponse)
    }
}
