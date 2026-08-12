import Foundation

/// One recognised utterance from the ASR sidecar.
public struct ASRSegment: Codable, Equatable, Sendable {
    /// С какой дорожки эта реплика.
    ///
    /// Отвечает на вопрос, который иначе пришлось бы угадывать по энергии: на
    /// микрофонной дорожке после снятия эха говорит владелец, на системной —
    /// все остальные. Диаризация нужна только второй.
    public enum Stem: String, Codable, Sendable {
        case microphone
        case system
    }

    public var start: Float
    public var end: Float
    public var text: String
    /// `nil` — реплика из микса: так пишет запасной путь и так лежат чекпойнты,
    /// записанные прежними сборками. Поле опциональное именно поэтому: чекпойнт
    /// с диска обязан читаться, а не роняться на неизвестном ключе.
    public var stem: Stem?

    public init(start: Float, end: Float, text: String, stem: Stem? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.stem = stem
    }
}

/// Одно распознанное слово со своим временем.
///
/// Нужно там, где эхо и своя речь приезжают в одном сегменте: снять чужие слова
/// можно только зная, когда каждое сказано (`StemAssembly.withoutEcho`).
/// Не `Codable` намеренно — слова живут в памяти на время прохода ASR и в
/// чекпойнт не едут: там лежит уже собранная лента, а слова весили бы как второй
/// транскрипт в файле индекса.
public struct ASRWord: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    /// Середина слова. Сравнивать начала бессмысленно: одно и то же слово на
    /// двух дорожках получает границы, разъезжающиеся на доли секунды.
    public var middle: Double { (start + end) / 2 }

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Reading what the two outside services actually said.
///
/// Transport stays in `GigasttClient` / `RecapService`; only the *interpretation*
/// lives here, because that is where the expensive failures have been. Every
/// case below cost a real meeting or a real hour:
///
/// - a 43-minute call came back **413** and the transcript was silently lost;
/// - a reasoning model spent the whole context window in its `thinking`
///   channel and returned empty `content` — 484 s for nothing;
/// - metadata JSON came back unquoted and took the meeting's topics with it.
///
/// None of these could be reproduced without an actual sidecar, an actual
/// model, and an actual long meeting. As pure functions over bytes they are
/// fixtures that run in microseconds.
public enum BoundaryResponses {}

// MARK: - ASR sidecar

extension BoundaryResponses {

    public enum ASRFailure: Error, Equatable, Sendable {
        /// The audio exceeded the sidecar's body or duration cap. The fix is
        /// chunking, not retrying — so this must stay distinguishable.
        case tooLarge(status: Int)
        /// The sidecar answered with its own error envelope.
        case rejected(String)
        case badStatus(Int, body: String)
        /// Parsed fine, but there is nothing to show for it.
        case empty
        case malformed
    }

    public struct ASRTranscription: Equatable, Sendable {
        public let segments: [ASRSegment]
        public let rawText: String
        /// Каждое слово со своим временем, если сайдкар их прислал.
        ///
        /// Нужны там, где эхо и своя речь приезжают в одном сегменте
        /// (`StemAssembly.withoutEcho`): без времени слова эхо не отличить от
        /// своей речи внутри реплики. Пусто — сборка обходится построчным
        /// правилом, а не падает.
        public let words: [ASRWord]

        public init(segments: [ASRSegment], rawText: String, words: [ASRWord] = []) {
            self.segments = segments
            self.rawText = rawText
            self.words = words
        }
    }

    /// Interpret an ASR response. `status` is the HTTP code, `data` the body.
    public static func readASR(status: Int, data: Data) -> Result<ASRTranscription, ASRFailure> {
        guard (200..<300).contains(status) else {
            // 413 has a specific remedy (chunk the file); everything else does not.
            if status == 413 { return .failure(.tooLarge(status: status)) }
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
               let message = envelope.error ?? envelope.code {
                return .failure(.rejected(message))
            }
            return .failure(.badStatus(status, body: String(decoding: data, as: UTF8.self)))
        }

        guard let decoded = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .failure(.malformed)
        }
        if let error = decoded.error { return .failure(.rejected(error)) }

        let segments = extractSegments(decoded)
        guard !segments.isEmpty else { return .failure(.empty) }
        let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawText = (text?.isEmpty == false)
            ? text!
            : segments.map(\.text).joined(separator: " ")
        return .success(ASRTranscription(
            segments: segments, rawText: rawText, words: extractWords(decoded)
        ))
    }

    /// Three shapes in the wild, in order of preference: segments, words, or a
    /// bare string. Older gigastt builds return the later ones.
    private static func extractSegments(_ decoded: Envelope) -> [ASRSegment] {
        if let segments = decoded.segments, !segments.isEmpty {
            return segments
                .map {
                    ASRSegment(
                        start: Float($0.start),
                        end: Float($0.end),
                        text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .filter { !$0.text.isEmpty }
        }
        if let words = decoded.words, !words.isEmpty {
            let text = (decoded.text ?? words.compactMap(\.word).joined(separator: " "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                ASRSegment(
                    start: Float(words.compactMap(\.start).first ?? 0),
                    end: Float(words.compactMap(\.end).last ?? decoded.duration ?? 0),
                    text: text
                )
            ]
        }
        if let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return [ASRSegment(start: 0, end: Float(decoded.duration ?? 0), text: text)]
        }
        return []
    }

    /// Слова с таймингами: сначала те, что лежат внутри сегментов, иначе плоский
    /// список верхнего уровня. Слово без времени пропускается — для вопроса «в
    /// это же мгновение» оно бесполезно, а притворяться, что оно в нуле, значит
    /// объявить эхом начало встречи.
    private static func extractWords(_ decoded: Envelope) -> [ASRWord] {
        let nested = (decoded.segments ?? []).flatMap { $0.words ?? [] }
        let source = nested.isEmpty ? (decoded.words ?? []) : nested
        return source.compactMap { word in
            guard let text = word.word?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, let start = word.start, let end = word.end else { return nil }
            return ASRWord(start: start, end: max(start, end), text: text)
        }
    }

    public struct Envelope: Decodable {
        public let text: String?
        public let duration: Double?
        public let confidence: Float?
        public let segments: [Segment]?
        public let words: [Word]?
        public let error: String?
        public let code: String?

        public struct Segment: Decodable {
            public let start: Double
            public let end: Double
            public let text: String
            public let words: [Word]?
        }

        public struct Word: Decodable {
            public let word: String?
            public let start: Double?
            public let end: Double?
        }
    }
}

// MARK: - Summary model

extension BoundaryResponses {

    public enum ChatFailure: Error, Equatable, Sendable {
        /// Reasoning model put everything in `thinking` and answered nothing.
        /// A retry with the same settings would burn the same minutes again.
        case reasonedItselfEmpty(thinkingCharacters: Int)
        /// Answered, but with nothing in it.
        case empty
        /// Not the JSON shape we expect — a proxy page, a truncated body.
        case malformed
    }

    /// Pull the assistant's reply out of an Ollama/OpenAI-style chat response.
    public static func readChatReply(data: Data) -> Result<String, ChatFailure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            return .failure(.malformed)
        }
        let content = (message["content"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty else { return .success(content) }

        if let thinking = message["thinking"] as? String, !thinking.isEmpty {
            return .failure(.reasonedItselfEmpty(thinkingCharacters: thinking.count))
        }
        return .failure(.empty)
    }
}
