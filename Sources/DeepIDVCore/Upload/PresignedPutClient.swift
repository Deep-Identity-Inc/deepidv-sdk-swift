// DeepIDVCore › Upload

import Foundation

/// Raw-transport S3 PUT + per-attempt timeout race shared by ``FileUploader``
/// and ``SessionUploader``.
///
/// Rules: no `x-api-key` on S3 (Content-Type only), `config.uploadTimeout`,
/// 403 → `.api("upload_url_expired")` non-retryable, 5xx retryable, other 4xx
/// → `.api("upload_error")`.
struct PresignedPutClient: Sendable {
    private let config: DeepIDVConfig
    private let transport: HTTPTransport
    private let retrySleep: @Sendable (TimeInterval) async throws -> Void
    private let timeoutSleep: @Sendable (TimeInterval) async throws -> Void

    init(
        config: DeepIDVConfig,
        transport: HTTPTransport,
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep,
        timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = APIClient
            .defaultSleep
    ) {
        self.config = config
        self.transport = transport
        self.retrySleep = retrySleep
        self.timeoutSleep = timeoutSleep
    }

    /// PUTs `data` to a presigned URL with retry. 5xx replies are retryable;
    /// a 403 (expired URL) or any other 4xx is not.
    func put(url: URL, data: Data, contentType: String) async throws {
        try await withRetry(
            maxRetries: config.maxRetries,
            initialDelay: config.initialRetryDelay,
            sleep: retrySleep
        ) {
            try await self.attemptPut(url: url, data: data, contentType: contentType)
        }
    }

    /// One S3 PUT attempt over the raw transport.
    private func attemptPut(url: URL, data: Data, contentType: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = config.uploadTimeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (_, response) = try await send(request, timeout: config.uploadTimeout)
        let status = response.statusCode
        if (200..<300).contains(status) { return }

        if status == 403 {
            throw DeepIDVError.api(
                "Presigned URL has expired or is invalid.", status: 403,
                code: "upload_url_expired")
        }
        throw DeepIDVError.api(
            "S3 upload failed: HTTP \(status)", status: status, code: "upload_error")
    }

    private enum RaceResult {
        case completed(Data, HTTPURLResponse)
        case timedOut
    }

    /// Races the transport PUT against a fresh `timeoutSleep(timeout)`.
    private func send(
        _ request: URLRequest, timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        try await withThrowingTaskGroup(of: RaceResult.self) { group in
            group.addTask { [transport] in
                do {
                    let (data, response) = try await transport.send(request)
                    return .completed(data, response)
                } catch let error as DeepIDVError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch let urlError as URLError where urlError.code == .timedOut {
                    throw DeepIDVError.timeout(
                        "Upload timed out", causeDescription: urlError.localizedDescription)
                } catch let urlError as URLError where urlError.code == .cancelled {
                    throw CancellationError()
                } catch {
                    throw DeepIDVError.network(
                        "S3 upload network error: \(error.localizedDescription)",
                        causeDescription: error.localizedDescription)
                }
            }
            group.addTask { [timeoutSleep] in
                try await timeoutSleep(timeout)
                return .timedOut
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DeepIDVError.timeout("Upload timed out after \(timeout)s")
            }
            switch first {
            case .completed(let data, let response):
                return (data, response)
            case .timedOut:
                throw DeepIDVError.timeout("Upload timed out after \(timeout)s")
            }
        }
    }
}
