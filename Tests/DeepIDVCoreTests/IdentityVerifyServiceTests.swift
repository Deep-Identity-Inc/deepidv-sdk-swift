import Foundation
import Testing

@testable import DeepIDVCore

// MARK: - Test helpers

private let testKey = "sk_live_secret_abcd1234"

/// Minimal valid magic-byte samples for the two supported formats.
private let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

private let neverTimeout: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}

private func makeResponse(
    url: String, status: Int, headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

private func presignJSON(_ uploads: [(uploadUrl: String, fileKey: String)]) -> Data {
    let items =
        uploads
        .map { #"{"uploadUrl":"\#($0.uploadUrl)","fileKey":"\#($0.fileKey)"}"# }
        .joined(separator: ",")
    return Data(#"{"uploads":[\#(items)]}"#.utf8)
}

private func presignFileCount(_ request: URLRequest) -> Int {
    guard let body = request.httpBody,
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let files = json["files"] as? [[String: Any]]
    else { return 0 }
    return files.count
}

/// Decodes a request body to `[String: String]` for shape assertions.
private func jsonBody(_ request: URLRequest?) -> [String: String] {
    guard let body = request?.httpBody,
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: String]
    else { return [:] }
    return json
}

/// A full verify body for decode assertions (nested objects, 0–100 scales).
private let fullVerifyBody = Data(
    """
    {
      "verified": true,
      "document": {
        "documentType": "passport",
        "fullName": "Ada Lovelace", "firstName": "Ada", "lastName": "Lovelace",
        "dateOfBirth": "1815-12-10", "gender": "F", "nationality": "GB",
        "documentNumber": "P1234567", "expirationDate": "2030-01-01",
        "issuingCountry": "GB", "address": "12 Analytical Engine Way",
        "confidence": 88.5
      },
      "faceDetection": { "faceDetected": true, "confidence": 99.1 },
      "faceMatch": { "isMatch": true, "confidence": 96.0, "threshold": 80.0 },
      "overallConfidence": 94.2
    }
    """.utf8)

/// Wires an `IdentityVerifyService` to a single routing stub: presign echoes one
/// upload per file (`key0`, `key1`, …), S3 PUTs reply 200, and
/// `/v1/identity/verify` defers to `verify`. One stub records everything.
private func makeService(
    maxRetries: Int = 0,
    verify: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> (service: IdentityVerifyService, stub: HTTPTransportStub) {
    let config = DeepIDVConfig(apiKey: testKey, timeout: 30, maxRetries: maxRetries)
    let stub = HTTPTransportStub { request in
        let url = request.url!
        switch url.path {
        case "/v1/upload/presign":
            let uploads = (0..<presignFileCount(request)).map {
                (uploadUrl: "https://s3.example.com/put/\($0)", fileKey: "key\($0)")
            }
            return (presignJSON(uploads), makeResponse(url: url.absoluteString, status: 200))
        case "/v1/identity/verify":
            return try await verify(request)
        default:
            return (Data(), makeResponse(url: url.absoluteString, status: 200))
        }
    }
    let service = IdentityVerifyService(
        config: config, transport: stub, retrySleep: noSleep, timeoutSleep: neverTimeout)
    return (service, stub)
}

private func verifyOK(
    _ body: Data
) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
    { request in (body, makeResponse(url: request.url!.absoluteString, status: 200)) }
}

// MARK: - Request shape (document front + back + selfie)

@Test func verifyUploadsAllThreeImagesAndExcludesBackFromBody() async throws {
    let (service, stub) = makeService(verify: verifyOK(fullVerifyBody))

    let result = try await service.verify(
        documentFront: .data(jpegData), documentBack: .data(pngData), selfie: .data(jpegData),
        type: .driversLicense)

    let requests = await stub.recorder.requests
    let presign = requests.first { $0.url?.path == "/v1/upload/presign" }
    let verify = requests.first { $0.url?.path == "/v1/identity/verify" }
    let puts = requests.filter { $0.url?.host == "s3.example.com" }

    // All three images presigned + PUT, in input order (front, back, selfie).
    #expect(presignFileCount(try #require(presign)) == 3)
    #expect(puts.count == 3)

    // Only the document front + selfie reach /verify; the back is excluded.
    let verifyBody = jsonBody(verify)
    #expect(verifyBody["documentImage"] == "key0")  // front
    #expect(verifyBody["faceImage"] == "key2")  // selfie (last input)
    #expect(verifyBody["documentType"] == "drivers_license")
    let verifyRaw = String(data: (try #require(verify)).httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(!verifyRaw.contains("key1"))  // back key never sent to /verify

    // All three keys injected on the result, back included.
    #expect(result.documentFrontKey == "key0")
    #expect(result.documentBackKey == "key1")
    #expect(result.selfieKey == "key2")
}

// MARK: - Request shape (no back)

@Test func verifyWithoutBackUploadsTwoImagesAndKeysSelfieLast() async throws {
    let (service, stub) = makeService(verify: verifyOK(fullVerifyBody))

    // No back, default type → "auto".
    let result = try await service.verify(
        documentFront: .data(jpegData), selfie: .data(pngData))

    let requests = await stub.recorder.requests
    let presign = requests.first { $0.url?.path == "/v1/upload/presign" }
    let verify = requests.first { $0.url?.path == "/v1/identity/verify" }
    let puts = requests.filter { $0.url?.host == "s3.example.com" }

    #expect(presignFileCount(try #require(presign)) == 2)  // front + selfie only
    #expect(puts.count == 2)

    let verifyBody = jsonBody(verify)
    #expect(verifyBody["documentImage"] == "key0")  // front
    #expect(verifyBody["faceImage"] == "key1")  // selfie is the last (and only other) input
    #expect(verifyBody["documentType"] == "auto")

    #expect(result.documentFrontKey == "key0")
    #expect(result.documentBackKey == nil)  // no back captured
    #expect(result.selfieKey == "key1")
}

// MARK: - Wire → result decoding through the service

@Test func verifyDecodesNestedBodyIntoResult() async throws {
    let (service, _) = makeService(verify: verifyOK(fullVerifyBody))

    let result = try await service.verify(
        documentFront: .data(jpegData), documentBack: .data(pngData), selfie: .data(jpegData),
        type: .passport)

    #expect(result.verified == true)
    #expect(result.document.fullName == "Ada Lovelace")
    #expect(result.document.address == "12 Analytical Engine Way")
    #expect(result.document.confidence == 88.5)  // 0–100 scale
    #expect(result.faceDetection.faceDetected == true)
    #expect(result.faceDetection.confidence == 99.1)
    #expect(result.faceMatch.isMatch == true)
    #expect(result.faceMatch.confidence == 96.0)
    #expect(result.faceMatch.threshold == 80.0)
    #expect(result.overallConfidence == 94.2)
}

// MARK: - Error propagation

@Test func verifyPropagatesValidationError() async {
    let (service, _) = makeService { request in
        (Data(), makeResponse(url: request.url!.absoluteString, status: 400))
    }
    do {
        _ = try await service.verify(documentFront: .data(jpegData), selfie: .data(pngData))
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func verifyPropagatesAuthenticationError() async {
    let (service, _) = makeService { request in
        (Data(), makeResponse(url: request.url!.absoluteString, status: 401))
    }
    do {
        _ = try await service.verify(documentFront: .data(jpegData), selfie: .data(pngData))
        Issue.record("expected an authentication error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .authentication)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func verifyPropagatesRateLimitError() async {
    let (service, _) = makeService { request in
        (Data(), makeResponse(url: request.url!.absoluteString, status: 429))
    }
    do {
        _ = try await service.verify(documentFront: .data(jpegData), selfie: .data(pngData))
        Issue.record("expected a rate-limit error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .rateLimit)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func verifyPropagatesTimeoutError() async {
    let (service, _) = makeService { _ in throw URLError(.timedOut) }
    do {
        _ = try await service.verify(documentFront: .data(jpegData), selfie: .data(pngData))
        Issue.record("expected a timeout error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .timeout)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func verifyInvalidBase64FailsBeforeAnyNetworkIO() async {
    let (service, stub) = makeService(verify: verifyOK(fullVerifyBody))
    do {
        _ = try await service.verify(
            documentFront: .base64("not-valid-base64!!!"), selfie: .data(pngData))
        Issue.record("expected a validation error")
    } catch let error as DeepIDVError {
        #expect(error.kind == .validation)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
    let count = await stub.recorder.requests.count
    #expect(count == 0)  // bad input fails before presign
}
