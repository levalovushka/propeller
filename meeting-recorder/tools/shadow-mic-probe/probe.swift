import CoreAudio
import Darwin
import Foundation

/// # Теневой замер: сколько раз в неделю «браузер держит микрофон»
///
/// Отвечает на один вопрос, от которого зависит, имеет ли смысл автозапись по
/// звуку: **сколько ложных срабатываний увидит человек за неделю**. Ничего не
/// записывает, ничего не показывает, звук не трогает — только читает у Core
/// Audio, какие процессы держат вход и выход, и пишет эпизоды в журнал.
///
/// Разрешений не требует вовсе: `kAudioHardwarePropertyProcessObjectList` и
/// свойства процессов читаются без TCC (замерено 2026-08-07 из терминала, у
/// которого нет ни Screen Recording, ни Accessibility).
///
/// ## Что такое эпизод
///
/// Отрезок, пока один процесс держит **вход** (микрофон). Внутри считаются два
/// числа: сколько он держал вход и сколько при этом одновременно играл звук
/// (дуплекс). Дуплекс — и есть предполагаемый сигнал звонка; длительность
/// дуплекса решает, дожил ли бы эпизод до баннера.
///
/// Журнал намеренно шире будущего детектора: пишутся **все** процессы с
/// микрофоном, а не только браузеры. Иначе замер не покажет, кого в белый
/// список надо добавить и кого — убрать.
///
/// В журнал не попадает ничего, кроме имени процесса и времени: ни звука, ни
/// заголовков окон, ни адресов.

// MARK: - Чтение Core Audio

enum CA {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let result = value as String
        return result.isEmpty ? nil : result
    }

    static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value == 1
    }

    static func pid(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = -1
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, value > 0 else {
            return nil
        }
        return value
    }

    /// Имя исполняемого файла — единственное, чем опознаётся процесс без bundle id
    /// (`afplay`, хелперы без своего Info.plist).
    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Эпизод

struct Episode {
    let key: String
    let bundleID: String
    let name: String
    let startedAt: Date
    var lastInputAt: Date
    /// Опросов подряд, в которых процесс вход уже не держал. Три подряд (6 с) —
    /// эпизод закрыт: браузер отпускает устройство не мгновенно, и без этого
    /// зазора один звонок разваливался бы на десяток эпизодов.
    var missedPolls = 0
    var pollsWithInput = 0
    var pollsWithDuplex = 0
    /// Самая длинная непрерывная серия дуплекса — именно она решает, дожил ли
    /// бы эпизод до баннера. Сумма не годится: десять коротких вспышек не
    /// становятся разговором.
    var longestDuplexRun = 0
    var currentDuplexRun = 0
}

// MARK: - Журнал

final class Journal {
    private let handle: FileHandle
    private let formatter: ISO8601DateFormatter

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
    }

    func write(_ fields: [String: Any]) {
        var line = fields
        line["at"] = formatter.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        handle.write(Data((text + "\n").utf8))
        try? handle.synchronize()
    }

    func stamp(_ date: Date) -> String { formatter.string(from: date) }
}

// MARK: - Пробник

let pollInterval: TimeInterval = 2
let missesBeforeClose = 3
let heartbeatInterval: TimeInterval = 900  // 15 минут — из них отчёт считает покрытие
let progressInterval: TimeInterval = 60   // как часто идущий эпизод отчитывается

let arguments = CommandLine.arguments
let journalPath = arguments.first(where: { $0.hasPrefix("--journal=") })
    .map { String($0.dropFirst("--journal=".count)) }
    ?? NSString(string: "~/.meeting-recorder/shadow-mic.jsonl").expandingTildeInPath
/// Самопроверка конвейера без микрофона: эпизодом считается выход, а не вход,
/// так что `afplay` даёт полноценный эпизод. Для замера не используется.
let useOutputAsTrigger = arguments.contains("--debug-use-output")

let journal = try Journal(path: journalPath)
let ownPID = getpid()
let system = AudioObjectID(kAudioObjectSystemObject)

journal.write([
    "event": "probe-started",
    "pollSeconds": pollInterval,
    "trigger": useOutputAsTrigger ? "output" : "input",
])

var episodes: [String: Episode] = [:]
var lastHeartbeat = Date()
var lastProgress = Date()

/// Итоги эпизода — те же самые и для закрытого, и для идущего. Идущий пишется
/// раз в минуту: иначе журнал молчит про встречу, которая прямо сейчас идёт, и
/// теряет её целиком, если пробник убьют жёстко.
func report(_ episode: Episode, endedAt: Date, event: String) {
    // Опрос покрывает интервал до следующего, поэтому эпизод длиной в один
    // опрос — это `pollInterval`, а не ноль.
    let duration = endedAt.timeIntervalSince(episode.startedAt) + pollInterval
    journal.write([
        "event": event,
        "key": episode.key,
        "bundleID": episode.bundleID,
        "name": episode.name,
        "startedAt": journal.stamp(episode.startedAt),
        "durationSeconds": Int(duration.rounded()),
        "inputSeconds": Int(Double(episode.pollsWithInput) * pollInterval),
        "duplexSeconds": Int(Double(episode.pollsWithDuplex) * pollInterval),
        "longestDuplexSeconds": Int(Double(episode.longestDuplexRun) * pollInterval),
    ])
}

/// Остановка не может выйти прямо из обработчика: незакрытые эпизоды пропали бы
/// из журнала, а именно они — самые длинные, то есть самые интересные.
var stopRequested: sig_atomic_t = 0
signal(SIGINT) { _ in stopRequested = 1 }
signal(SIGTERM) { _ in stopRequested = 1 }

while true {
    if stopRequested != 0 {
        for episode in episodes.values {
            report(episode, endedAt: episode.lastInputAt, event: "episode")
        }
        journal.write(["event": "probe-stopped", "closedEpisodes": episodes.count])
        exit(0)
    }

    let now = Date()
    var seen = Set<String>()

    for object in CA.objectList(system, kAudioHardwarePropertyProcessObjectList) {
        guard let pid = CA.pid(object), pid != ownPID else { continue }
        let input = CA.flag(object, kAudioProcessPropertyIsRunningInput)
        let output = CA.flag(object, kAudioProcessPropertyIsRunningOutput)
        let triggered = useOutputAsTrigger ? output : input
        guard triggered else { continue }

        let bundleID = CA.string(object, kAudioProcessPropertyBundleID) ?? ""
        let name = CA.processName(pid) ?? ""
        // Ключ по личности процесса, а не по pid: Chromium перезапускает
        // audio service, и один разговор не должен становиться двумя эпизодами.
        let key = bundleID.isEmpty ? "name:\(name)" : "bundle:\(bundleID)"
        seen.insert(key)

        var episode = episodes[key] ?? {
            let fresh = Episode(
                key: key, bundleID: bundleID, name: name,
                startedAt: now, lastInputAt: now
            )
            journal.write(["event": "episode-open", "bundleID": bundleID, "name": name])
            return fresh
        }()

        episode.lastInputAt = now
        episode.missedPolls = 0
        episode.pollsWithInput += 1
        let duplex = useOutputAsTrigger ? true : (input && output)
        if duplex {
            episode.pollsWithDuplex += 1
            episode.currentDuplexRun += 1
            episode.longestDuplexRun = max(episode.longestDuplexRun, episode.currentDuplexRun)
        } else {
            episode.currentDuplexRun = 0
        }
        episodes[key] = episode
    }

    for (key, var episode) in episodes where !seen.contains(key) {
        episode.missedPolls += 1
        if episode.missedPolls >= missesBeforeClose {
            report(episode, endedAt: episode.lastInputAt, event: "episode")
            episodes[key] = nil
        } else {
            episodes[key] = episode
        }
    }

    if now.timeIntervalSince(lastProgress) >= progressInterval {
        for episode in episodes.values {
            report(episode, endedAt: episode.lastInputAt, event: "episode-progress")
        }
        lastProgress = now
    }

    // Без отметок живости «ноль ложных срабатываний» неотличимо от «пробник
    // умер во вторник».
    if now.timeIntervalSince(lastHeartbeat) >= heartbeatInterval {
        journal.write(["event": "heartbeat", "openEpisodes": episodes.count])
        lastHeartbeat = now
    }

    Thread.sleep(forTimeInterval: pollInterval)
}
