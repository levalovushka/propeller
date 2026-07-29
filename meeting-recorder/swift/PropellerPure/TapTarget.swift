import Foundation

/// В какие процессы целится тап.
///
/// # Почему это не то же самое, что `CaptureScopePolicy`
///
/// `CaptureScopePolicy` отвечает на продуктовый вопрос — «звук какого
/// приложения мы вообще имеем право писать». Ответ у неё в bundle id, потому
/// что ScreenCaptureKit фильтруется приложениями.
///
/// Core Audio фильтруется **процессами**, и здесь всплывает то, что SCK делал
/// за нас молча: звук звонка издаёт не приложение с окном, а его хелпер
/// (`CptHost` у Zoom — замерено на живом звонке 2026-07-29). SCK отдавал
/// приложение вместе с хелперами; тапу их надо перечислить.
///
/// Поэтому здесь отдельное правило, и оно читает **ту же таблицу платформ**:
/// `bundleIDs` — само приложение, `callHelperProcesses` — процессы звонка. Плюс
/// одно правило сверх таблицы: хелперы обычно называются идентификатором
/// приложения с суффиксом (`us.zoom.xos.CptHost`), и такие ловятся префиксом,
/// не требуя новой строки в таблице на каждый релиз Zoom.
public struct AudioProcessCandidate: Equatable {

    /// `AudioObjectID` процесса в Core Audio.
    public let objectID: UInt32
    /// Bundle id, как его отдал `kAudioProcessPropertyBundleID`.
    public let bundleID: String?
    /// Имя исполняемого файла — по нему узнаются хелперы без своего bundle id.
    public let executableName: String?

    public init(objectID: UInt32, bundleID: String?, executableName: String?) {
        self.objectID = objectID
        self.bundleID = bundleID
        self.executableName = executableName
    }
}

public enum TapTarget: Equatable {
    /// Тап на эти процессы. Непустой всегда — пустой список это `.wholeMachine`.
    case processes([UInt32])
    /// Тап на всё, кроме нас самих. Наш собственный звук исключается не из
    /// вежливости: без этого запись слышала бы плеер, которым её же и слушают.
    case everythingExceptOurselves
}

public enum TapTargetPolicy {

    /// Во что целиться, зная идущий звонок и список звучащих процессов.
    ///
    /// - Parameter callInProgressOn: `MeetingSnapshot.platformID`. Нет звонка —
    ///   сужать не на что, и это не деградация: человек записывает что-то
    ///   другое, и записать надо именно это.
    public static func target(
        processes: [AudioProcessCandidate],
        callInProgressOn platformID: String?,
        platforms: [MeetingPlatform] = MeetingPlatform.all
    ) -> TapTarget {
        guard let platformID,
              let platform = platforms.first(where: { $0.id == platformID })
        else { return .everythingExceptOurselves }

        let matched = processes.filter { belongs($0, to: platform) }.map(\.objectID)
        // Звонок засекли, а звучащих процессов платформы нет: встреча в
        // браузере, либо приложение ещё не начало играть. Целиться не во что —
        // пишем машину, как и раньше в этом случае.
        return matched.isEmpty ? .everythingExceptOurselves : .processes(matched)
    }

    static func belongs(_ process: AudioProcessCandidate, to platform: MeetingPlatform) -> Bool {
        if let bundleID = process.bundleID?.lowercased(), !bundleID.isEmpty {
            if platform.bundleIDs.contains(bundleID) { return true }
            // `us.zoom.xos.CptHost` при `us.zoom.xos` в таблице. Точка
            // обязательна: без неё `ru.kontur.talkative` сошёл бы за Толк.
            if platform.bundleIDs.contains(where: { bundleID.hasPrefix($0 + ".") }) { return true }
        }
        if let name = process.executableName?.lowercased(), !name.isEmpty {
            if platform.callHelperProcesses.contains(name) { return true }
        }
        return false
    }
}
