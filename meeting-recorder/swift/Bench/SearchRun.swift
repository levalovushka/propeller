import Foundation
import PropellerPure

/// `swift run -c release Bench -- --search`
///
/// Цена поиска по архиву, и отдельно — цена того, как его звали из вьюхи.
///
/// Мерится на синтетическом архиве, а не на архиве владельца: замер обязан
/// повторяться на другой машине и не зависеть от того, сколько у человека встреч.
/// Масштаб взят с настоящего — 29 встреч, транскрипт около 24 тысяч знаков.
func runSearch(_ args: [String]) async throws {
    let meetings = intFlag(args, "--meetings") ?? 29
    let transcriptChars = intFlag(args, "--chars") ?? 24_000
    let repeats = intFlag(args, "--repeats") ?? 20

    print("Search harness — \(meetings) meetings, ~\(transcriptChars) chars each, \(repeats) repeats")

    let documents = synthesizeDocuments(count: meetings, transcriptChars: transcriptChars)
    let recapFiles = try writeRecapFiles(count: meetings)
    defer { try? FileManager.default.removeItem(at: recapFiles.directory) }

    // Запросы разной удачливости: редкое слово, частое, и то, чего нет вовсе —
    // ранний выход из поиска ускоряет только последний случай.
    let queries = ["биллинг", "и", "квартальный бюджет"]

    var pureSamples: [Double] = []
    for query in queries {
        let elapsed = measure(repeats: repeats) {
            _ = ArchiveSearch.run(query: query, over: documents)
        }
        pureSamples.append(elapsed)
        print(String(format: "  pure search «%@»: %.2f ms", query, elapsed))
    }

    // То, что происходило на каждое нажатие клавиши: `matchedRecordings` —
    // вычисляемое свойство, а `body` спрашивает её шесть-семь раз (три чипа
    // фильтра, `items`, `groupedItems`, дважды `items.count`), и каждый раз
    // читает файл конспекта на каждую встречу.
    let callsPerRender = 7
    let renderElapsed = measure(repeats: max(3, repeats / 4)) {
        for _ in 0..<callsPerRender {
            let withRecaps = documents.enumerated().map { index, document in
                ArchiveSearch.Document(
                    id: document.id, title: document.title, dateLabel: document.dateLabel,
                    bodies: document.bodies + [recapFiles.read(index)]
                )
            }
            _ = ArchiveSearch.run(query: "биллинг", over: withRecaps)
        }
    }
    print(String(format: "  one render the old way (%d calls × %d file reads): %.1f ms",
                 callsPerRender, meetings, renderElapsed))
    print(String(format: "  … which at 20 AppState publishes/second during a recording is %.0f ms/s of work",
                 renderElapsed * 20))

    // Рост: архив у человека только прибавляется.
    for scale in [100, 500] {
        let bigger = synthesizeDocuments(count: scale, transcriptChars: transcriptChars)
        let elapsed = measure(repeats: max(3, repeats / 4)) {
            _ = ArchiveSearch.run(query: "биллинг", over: bigger)
        }
        print(String(format: "  pure search over %d meetings: %.2f ms", scale, elapsed))
    }

    let latestURL = try writeMetrics(
        fixture: "synthetic-archive", audioDuration: 0, runs: repeats
    ) { metrics in
        metrics.ui_search_ms = sampleStat(pureSamples, tolerance: "+25%", direction: .lower)
        metrics.ui_search_render_ms = sampleStat([renderElapsed], tolerance: "+25%", direction: .lower)
    }
    print("Wrote \(latestURL.path)")
}

private func measure(repeats: Int, _ body: () -> Void) -> Double {
    // Один прогон на разогрев: первый вызов платит за ленивую инициализацию
    // ICU-таблиц сравнения строк, и это не то, что происходит на каждом нажатии.
    body()
    var samples: [Double] = []
    for _ in 0..<repeats {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }
    return percentile(samples.sorted(), 0.50)
}

private func synthesizeDocuments(count: Int, transcriptChars: Int) -> [ArchiveSearch.Document] {
    // Текст русский и с повторами, как настоящая расшифровка: длина строки в
    // юникоде решает больше, чем число документов.
    let vocabulary = [
        "мы", "обсудили", "миграцию", "базы", "и", "решили", "отложить", "до", "среды",
        "биллинг", "задевает", "оплату", "поэтому", "нужен", "отдельный", "прогон", "тестов",
        "дизайн", "просил", "не", "менять", "форму", "до", "пятницы", "иначе", "не", "успеют",
    ]
    return (0..<count).map { index in
        var transcript = ""
        var word = index
        while transcript.count < transcriptChars {
            transcript += vocabulary[word % vocabulary.count] + " "
            word += 1
        }
        return ArchiveSearch.Document(
            id: "m\(index)",
            title: "Встреча \(index)",
            dateLabel: "6 августа",
            bodies: [transcript, index % 5 == 0 ? "заметка про биллинг" : ""]
        )
    }
}

/// Файлы конспектов на диске — ровно то, что читалось в `body`.
private func writeRecapFiles(count: Int) throws -> (directory: URL, read: (Int) -> String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("propeller-search-bench-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let body = String(repeating: "решили отложить биллинг до пятницы. ", count: 120)
    var urls: [URL] = []
    for index in 0..<count {
        let url = directory.appendingPathComponent("recap-\(index).md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        urls.append(url)
    }
    return (directory, { index in (try? String(contentsOf: urls[index], encoding: .utf8)) ?? "" })
}
