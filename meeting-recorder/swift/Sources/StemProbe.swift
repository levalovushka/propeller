import Foundation
import PropellerPure
import SpeakerMatchingCore

/// `--stem-probe <путь к миксу>`: прогнать настоящую расшифровку на готовой
/// записи и показать, что получилось.
///
/// Зачем отдельный режим, а не тест: `Sources/` — исполняемая цель, тестам она
/// не видна, поэтому весь путь «две дорожки → снятие эха → диаризация системного
/// стема → лента» иначе проверяется только глазами на живой встрече. Тот же
/// довод, по которому в релизном бинарнике живут `--tap-probe` и `--live-probe`:
/// проба должна ходить теми же путями и с теми же разрешениями, что продукт.
///
/// Ничего не пишет в архив. Читает аудио, кладёт отчёт рядом с остальными
/// пробами и выходит.
enum StemProbe {
    static let flag = "--stem-probe"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    private static var requestedPath: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static var reportURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Meeting Recorder/stem-probe.txt")
    }

    @MainActor
    static func run() async {
        guard let path = requestedPath else {
            NSLog("[StemProbe] нужен путь: --stem-probe <файл.wav>")
            return
        }
        let audioURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let stems = AudioSourceStemURLs.expectedSiblings(for: audioURL)
        var report = """
        Проба сборки из дорожек
        файл:      \(audioURL.path)
        микрофон:  \(stems.existingMicrophoneURL != nil ? "есть" : "НЕТ")
        системный: \(stems.existingSystemURL != nil ? "есть" : "НЕТ")

        """

        let started = Date()
        let service = TranscriptionService()
        do {
            let result = try await service.transcribe(
                audioURL: audioURL,
                progressCallback: { NSLog("[StemProbe] \($0)") }
            )
            let owner = Preferences.shared.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let byOwner = result.mergedSegments.filter { $0.speaker == owner || $0.speaker == SourceAwareSpeaker.defaultOwnerName }
            report += """
            строк:          \(result.mergedSegments.count)
            из них владелец: \(byOwner.count) (\(byOwner.reduce(0) { $0 + TranscriptAccuracy.words(in: $1.text).count }) слов)
            остальные:      \(result.mergedSegments.count - byOwner.count) (\(result.mergedSegments.filter { !byOwner.contains($0) }.reduce(0) { $0 + TranscriptAccuracy.words(in: $1.text).count }) слов)
            спикеры:        \(Set(result.mergedSegments.map(\.speaker)).sorted().joined(separator: ", "))
            принадлежность: \(result.attribution.rawValue)
            секунд:         \(Int(Date().timeIntervalSince(started)))

            \(result.transcript)
            """
        } catch {
            report += "ОШИБКА: \(error.localizedDescription)\n"
        }

        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        NSLog("[StemProbe] отчёт: \(reportURL.path)")
    }
}
