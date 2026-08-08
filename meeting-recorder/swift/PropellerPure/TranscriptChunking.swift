import Foundation

/// Как разрезать транскрипт, который не помещается в окно модели.
///
/// Без этого встреча не укорачивается, а **обрывается**: Ollama выбрасывает
/// начало разговора и отдаёт уверенный конспект встречи, которую видела
/// наполовину. Замер по архиву — 8 транскриптов из 54 переполняют самое большое
/// окно, и это восемь самых содержательных встреч. Часовой «Обед» доходил до
/// модели на 45% и всё равно получал «Ход обсуждения» с первой минуты.
///
/// Замер нарезки (`tools/recap-lab`, qwen3.5:4b): тот же «Обед» целиком — 4
/// решения и ни одной задачи; нарезанный по 13 000 символов — 13 решений и 5
/// задач. Разница не в формулировках, а в том, что модели наконец показали
/// вторую половину встречи.
public enum TranscriptChunking {

    /// Символов на фрагмент.
    ///
    /// Заметно ниже окна, и это не осторожность: качество извлечения падает
    /// задолго до предела. Замерено на тех же двух длинных встречах — фрагменты
    /// по 26 000 дали 6 решений и 2, фрагменты по 13 000 — 13 и 6. Окно — это
    /// сколько модель *удержит*, а не сколько она разберёт.
    ///
    /// Побочный выигрыш — память: фрагмент такого размера всегда укладывается в
    /// окно 16384, а оно стоит 3,6 ГБ против 4,3 ГБ у 32768 (замерено через
    /// `ollama ps`). Нарезанная встреча грузит машину меньше, чем целая.
    public static let charactersPerChunk = 13_000

    /// Реплика начинается с `**Имя** · 12:34` — так пишет `MarkdownWriter`.
    private static let turnPattern = "(?m)^(?=\\*\\*[^*]+\\*\\*\\s*·\\s*\\d)"

    /// Нужно ли резать: тот же вопрос, что задаёт `OllamaContext`, но заданный
    /// до вызова, а не в логе после него.
    public static func needed(promptCharacters: Int) -> Bool {
        OllamaContext.exceedsLargestWindow(promptCharacters: promptCharacters)
    }

    /// Разрезать по границам реплик, никогда внутри одной.
    ///
    /// Разрез посреди реплики стоит фрагменту имени говорящего и таймкода, и
    /// извлечение приписывает фразу тому, кто заговорил следующим.
    ///
    /// Шапка (дата, участники, календарь) достаётся первому фрагменту: дальше
    /// она не нужна, а место занимает.
    public static func split(
        _ transcript: String,
        charactersPerChunk limit: Int = charactersPerChunk
    ) -> [String] {
        let (header, body) = splitHeader(transcript)
        let turns = turnsOf(body)
        guard !turns.isEmpty else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [transcript]
        }

        var chunks: [String] = []
        var current = ""
        for turn in turns {
            if !current.isEmpty, current.count + turn.count > limit {
                chunks.append(current)
                current = turn
            } else {
                current += turn
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        if !chunks.isEmpty, !header.isEmpty {
            chunks[0] = header + chunks[0]
        }
        return chunks
    }

    // MARK: -

    /// Всё до `## Transcript` — шапка; сам заголовок остаётся с ней.
    private static func splitHeader(_ transcript: String) -> (header: String, body: String) {
        guard let range = transcript.range(of: "## Transcript") else { return ("", transcript) }
        return (String(transcript[transcript.startIndex..<range.upperBound]),
                String(transcript[range.upperBound...]))
    }

    private static func turnsOf(_ body: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: turnPattern) else { return [body] }
        let full = NSRange(body.startIndex..., in: body)
        var starts: [String.Index] = []
        regex.enumerateMatches(in: body, range: full) { match, _, _ in
            if let match, let index = Range(match.range, in: body)?.lowerBound {
                starts.append(index)
            }
        }
        guard !starts.isEmpty else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [body]
        }

        var turns: [String] = []
        // Всё до первой реплики (пустые строки после заголовка) прилипает к ней,
        // чтобы не потеряться и не стать отдельным фрагментом.
        var previous = body.startIndex
        for start in starts.dropFirst() {
            turns.append(String(body[previous..<start]))
            previous = start
        }
        turns.append(String(body[previous...]))
        return turns
    }
}
