import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Test helpers

private let testKey = "sk_live_secret_abcd1234"

/// Minimal valid magic-byte samples for the two supported formats.
private let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

/// No-op backoff sleeper so retry tests never touch the wall clock.
private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

/// A "never fires" timeout sleeper: the stub transport always wins the race, so
/// the group cancels this immediately — no real waiting happens.
private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

private func makeResponse(
    url: String, status: Int, headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

/// Encodes a presign response body from `(uploadUrl, fileKey)` pairs.
private func presignJSON(_ uploads: [(uploadUrl: String, fileKey: String)]) -> Data {
    let items =
        uploads
        .map { #"{"uploadUrl":"\#($0.uploadUrl)","fileKey":"\#($0.fileKey)"}"# }
        .joined(separator: ",")
    return Data(#"{"uploads":[\#(items)]}"#.utf8)
}

/// Number of files described by a presign request body.
private func presignFileCount(_ request: URLRequest) -> Int {
    guard let body = request.httpBody,
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let files = json["files"] as? [[String: Any]]
    else { return 0 }
    return files.count
}

/// Decodes a request body to a `[String: String]` for shape assertions.
private func jsonBody(_ request: URLRequest?) -> [String: String] {
    guard let body = request?.httpBody,
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: String]
    else { return [:] }
    return json
}

/// A full scan body for decode assertions (address + mrz present, 0–1 confidence).
private let fullScanBody = Data(
    """
    {
      "documentType": "national_id",
      "fullName": "Ada Lovelace", "firstName": "Ada", "lastName": "Lovelace",
      "dateOfBirth": "1815-12-10", "gender": "F", "nationality": "GB",
      "documentNumber": "P1234567", "expirationDate": "2030-01-01",
      "issuingCountry": "GB", "address": "12 Analytical Engine Way",
      "mrzData": "P<GBRLOVELACE<<ADA<<<<<<<<<<<<<<<<<<<<<<<<<<",
      "rawFields": { "documentNumber": "P1234567", "gender": "F" },
      "confidence": 0.92
    }
    """.utf8)

/// A scan body with the optional `address`/`mrzData` absent.
private let minimalScanBody = Data(
    """
    {
      "documentType": "passport",
      "fullName": "Grace Hopper", "firstName": "Grace", "lastName": "Hopper",
      "dateOfBirth": "1906-12-09", "gender": "F", "nationality": "US",
      "documentNumber": "DL987", "expirationDate": "2028-06-01",
      "issuingCountry": "US", "rawFields": {}, "confidence": 0.5
    }
    """.utf8)

/// Wires a `DocumentScanService` to a single routing stub: `/v1/upload/presign`
/// echoes one upload per requested file (`key0`, `key1`, …), S3 PUTs reply 200,
/// and `/v1/document/scan` defers to `scan`. The one stub backs both the
/// `APIClient` and the `FileUploader` the service builds internally, so every
/// request is recorded in one place. Returns the service + the stub.
private func makeService(
    maxRetries: Int = 0,
    scan: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> (service: DocumentScanService, stub: HTTPTransportStub) {
    let config = DeepIDVConfig(apiKey: testKey, timeout: 30, maxRetries: maxRetries)
    let stub = HTTPTransportStub { request in
        let url = request.url!
        switch url.path {
        case "/v1/upload/presign":
            let uploads = (0..<presignFileCount(request)).map {
                (uploadUrl: "https://s3.example.com/put/\($0)", fileKey: "key\($0)")
            }
            return (presignJSON(uploads), makeResponse(url: url.absoluteString, status: 200))
        case "/v1/document/scan":
            return try await scan(request)
        default:
            // S3 PUTs (host s3.example.com) → 200 OK.
            return (Data(), makeResponse(url: url.absoluteString, status: 200))
        }
    }
    let service = DocumentScanService(
        config: config, transport: stub, retrySleep: noSleep, timeoutSleep: neverTimeout)
    return (service, stub)
}

/// A scan handler returning `body` with `200 OK`.
private func scanOK(
    _ body: Data
) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
    { request in (body, makeResponse(url: request.url!.absoluteString, status: 200)) }
}

// MARK: - Request shape (front + back)

@Test func scanUploadsBothImagesAndOCRsOnlyTheFront() async throws {
    let (service, stub) = makeService(scan: scanOK(fullScanBody))

    let result = try await service.scan(front: .data(jpegData), back: .data(pngData), type: .idCard)

    let requests = await stub.recorder.requests
    let presign = requests.first { $0.url?.path == "/v1/upload/presign" }
    let scan = requests.first { $0.url?.path == "/v1/document/scan" }
    let puts = requests.filter { $0.url?.host == "s3.example.com" }

    // Presign described both files, in input order, with detected content types.
    #expect(presignFileCount(try #require(presign)) == 2)
    let presignContentTypes = presignFiles(presign).map { $0["contentType"] as? String }
    #expect(presignContentTypes == ["image/jpeg", "image/png"])

    // Both images were PUT to S3...
    #expect(puts.count == 2)
    // ...but only the front key is OCR'd; the back key never reaches /scan.
    let scanBody = jsonBody(scan)
    #expect(scanBody["image"] == "key0")
    #expect(scanBody["documentType"] == "national_id")  // idCard → national_id wireValue
    let scanRaw = String(data: (try #require(scan)).httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(!scanRaw.contains("key1"))  // back key excluded from the scan body

    // Image keys injected in input order on the result.
    #expect(result.frontImageKey == "key0")
    #expect(result.backImageKey == "key1")
}

// MARK: - Request shape (front only / passport)

@Test func scanFrontOnlyLeavesBackKeyNilAndUploadsOneImage() async throws {
    let (service, stub) = makeService(scan: scanOK(minimalScanBody))

    let result = try await service.scan(front: .data(jpegData), type: .passport)

    let requests = await stub.recorder.requests
    let presign = requests.first { $0.url?.path == "/v1/upload/presign" }
    let scan = requests.first { $0.url?.path == "/v1/document/scan" }
    let puts = requests.filter { $0.url?.host == "s3.example.com" }

    #expect(presignFileCount(try #require(presign)) == 1)  // only the front was presigned
    #expect(puts.count == 1)  // only one S3 PUT
    #expect(jsonBody(scan)["documentType"] == "passport")
    #expect(jsonBody(scan)["image"] == "key0")
    #expect(result.frontImageKey == "key0")
    #expect(result.backImageKey == nil)  // front-only → no back key
}

// MARK: - documentType wireValue mapping

@Test func scanDefaultsToAutoDocumentType() async throws {
    let (service, stub) = makeService(scan: scanOK(minimalScanBody))

    _ = try await service.scan(front: .data(jpegData))  // type defaults to .auto

    let scan = await stub.recorder.requests.first { $0.url?.path == "/v1/document/scan" }
    #expect(jsonBody(scan)["documentType"] == "auto")
}

@Test func scanSendsDriversLicenseWireValue() async throws {
    let (service, stub) = makeService(scan: scanOK(minimalScanBody))

    _ = try await service.scan(front: .data(jpegData), type: .driversLicense)

    let scan = await stub.recorder.requests.first { $0.url?.path == "/v1/document/scan" }
    #expect(jsonBody(scan)["documentType"] == "drivers_license")
}

// MARK: - Wire → result decoding through the service

@Test func scanDecodesFullBodyIntoResult() async throws {
    let (service, _) = makeService(scan: scanOK(fullScanBody))

    let result = try await service.scan(front: .data(jpegData), back: .data(pngData), type: .idCard)

    #expect(result.documentType == "national_id")
    #expect(result.fullName == "Ada Lovelace")
    #expect(result.documentNumber == "P1234567")
    #expect(result.issuingCountry == "GB")
    #expect(result.address == "12 Analytical Engine Way")
    #expect(result.mrzData?.hasPrefix("P<GBR") == true)
    #expect(result.rawFields["documentNumber"] == "P1234567")
    #expect(result.confidence == 0.92)  // 0–1 scale preserved
}

@Test func scanDecodesOptionalFieldsAbsentAsNil() async throws {
    let (service, _) = makeService(scan: scanOK(minimalScanBody))

    let result = try await service.scan(front: .data(jpegData), type: .passport)

    #expect(result.address == nil)
    #expect(result.mrzData == nil)
    #expect(result.rawFields.isEmpty)
}

// MARK: - Error propagation

@Test func scanPropagatesValidationError() async {
    let (service, _) = makeService { request in
        (Data(), makeResponse(url: request.url!.absoluteString, status: 400))
    }
    do {
        _ = try await service.scan(front: .data(jpegData), type: .passport)
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func scanPropagatesAuthenticationError() async {
    let (service, _) = makeService { request in
        (Data(), makeResponse(url: request.url!.absoluteString, status: 401))
    }
    do {
        _ = try await service.scan(front: .data(jpegData), type: .passport)
        Issue.record("expected an authentication error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .authentication)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func scanPropagatesRateLimitError() async {
    let (service, _) = makeService { request in
        (Data(), makeResponse(url: request.url!.absoluteString, status: 429))
    }
    do {
        _ = try await service.scan(front: .data(jpegData), type: .passport)
        Issue.record("expected a rate-limit error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .rateLimit)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func scanPropagatesTimeoutError() async {
    // The scan endpoint surfaces a transport timeout; with neverTimeout the race
    // isn't involved — the thrown URLError maps to `.timeout` and propagates.
    let (service, _) = makeService { _ in throw URLError(.timedOut) }
    do {
        _ = try await service.scan(front: .data(jpegData), type: .passport)
        Issue.record("expected a timeout error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .timeout)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func scanInvalidBase64FailsBeforeAnyNetworkIO() async {
    let (service, stub) = makeService(scan: scanOK(minimalScanBody))
    do {
        _ = try await service.scan(front: .base64("not-valid-base64!!!"), type: .passport)
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
    // Bad input must fail before presign — no requests reach the transport.
    let count = await stub.recorder.requests.count
    #expect(count == 0)
}

// MARK: - Local decode helper

/// Decodes the `files` array out of a presign request body.
private func presignFiles(_ request: URLRequest?) -> [[String: Any]] {
    guard let body = request?.httpBody,
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let files = json["files"] as? [[String: Any]]
    else { return [] }
    return files
}
