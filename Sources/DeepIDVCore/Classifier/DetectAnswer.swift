// DeepIDVCore › Classifier

/// One answer from the document classifier for one frame.
package struct DetectAnswer: Sendable, Equatable, Decodable {
    /// The card's bounding box in the pixels of the image that was sent.
    package struct Box: Sendable, Equatable, Decodable {
        /// `[x0, y0, x1, y1]`.
        package var xyxy: [Double]
        package var score: Double?
    }

    /// One ranked guess at the document class. On the wire it is a pair:
    /// `["class_id", 0.81]`.
    package struct Candidate: Sendable, Equatable, Decodable {
        package var id: String
        package var confidence: Double

        package init(id: String, confidence: Double) {
            self.id = id
            self.confidence = confidence
        }

        package init(from decoder: any Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            id = try pair.decode(String.self)
            confidence = try pair.decode(Double.self)
        }
    }

    /// The classifier's view of which document this is.
    package struct DocumentTypeGuess: Sendable, Equatable, Decodable {
        /// The class the classifier names, or `nil` when it isn't sure enough to.
        package var id: String?
        package var confidence: Double
        /// Up to three guesses, best first. Present even when `id` is `nil`.
        package var top3: [Candidate]

        package enum CodingKeys: String, CodingKey {
            case id, confidence, top3
        }

        package init(id: String?, confidence: Double, top3: [Candidate] = []) {
            self.id = id
            self.confidence = confidence
            self.top3 = top3
        }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
            top3 = try container.decodeIfPresent([Candidate].self, forKey: .top3) ?? []
        }
    }

    /// Whether a card is in the frame at all.
    package var present: Bool
    package var box: Box?
    package var documentType: DocumentTypeGuess?
    package var modelVersion: String?

    package enum CodingKeys: String, CodingKey {
        case present, box
        case documentType = "document_type"
        case modelVersion = "model_version"
    }

    package init(
        present: Bool, box: Box? = nil, documentType: DocumentTypeGuess? = nil,
        modelVersion: String? = nil
    ) {
        self.present = present
        self.box = box
        self.documentType = documentType
        self.modelVersion = modelVersion
    }

    /// The best guess, if any.
    package var top: Candidate? { documentType?.top3.first }
}

/// What came back for one frame: an answer, or the HTTP status of a failed call.
package enum DetectOutcome: Sendable, Equatable {
    case answer(DetectAnswer)
    /// A failed call. `status` is `0` for a network error or timeout.
    case failure(status: Int)

    package var answer: DetectAnswer? {
        if case .answer(let answer) = self { return answer }
        return nil
    }
}
