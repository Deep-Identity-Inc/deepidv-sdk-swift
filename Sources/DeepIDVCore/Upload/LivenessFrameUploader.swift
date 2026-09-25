// DeepIDVCore › Upload

import Foundation

/// PUTs a custom-liveness capture (frames, timeline, optional replay clip) to
/// the presigned S3 URLs from an `upload-url` call. Shared by
/// ``CustomFaceLivenessService`` (workflow step) and `ReVerificationService`.
///
/// Uploads go through an injected `URLSession`, not `HTTPTransport`, so they
/// get none of the SDK's upload policy (no `uploadTimeout` race, no 5xx retry,
/// no `upload_url_expired` mapping) and a transport stub cannot see them.
package struct LivenessFrameUploader: Sendable {
    private let session: URLSession

    package init(session: URLSession = .shared) {
        self.session = session
    }

    /// Required PUTs (frames as `image/jpeg`, timeline as `application/json`)
    /// run in a task group; any non-2xx throws `.network`. The clip PUT
    /// (`video/mp4`) is detached and best-effort.
    package func upload(
        _ frames: [Data], timeline: Data, clip: Data?, to urls: LivenessUploadURLs
    ) async throws {
        let uploadSession = session
        func put(_ data: Data, to url: URL, contentType: String) async throws {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            let (_, response) = try await uploadSession.upload(for: request, from: data)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw DeepIDVError.network("Liveness frame upload failed")
            }
        }
        // Frames + timeline are required — the result is scored from them.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, frame) in frames.enumerated() where index < urls.frameUploadURLs.count {
                let url = urls.frameUploadURLs[index]
                group.addTask { try await put(frame, to: url, contentType: "image/jpeg") }
            }
            group.addTask {
                try await put(timeline, to: urls.timelineUploadURL, contentType: "application/json")
            }
            try await group.waitForAll()
        }
        // The replay clip is best-effort: fire-and-forget so it neither delays
        // the result fetch nor fails the attempt if it doesn't land (parity
        // with the web verify flow).
        if let clip, let clipURL = urls.clipUploadURL {
            let session = uploadSession
            Task.detached {
                var request = URLRequest(url: clipURL)
                request.httpMethod = "PUT"
                request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
                _ = try? await session.upload(for: request, from: clip)
            }
        }
    }
}
