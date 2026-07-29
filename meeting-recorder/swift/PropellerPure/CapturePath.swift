import Foundation

/// Каким способом снимается звук встречи.
///
/// # Почему путь один
///
/// Был второй — ScreenCaptureKit плюс `AVAudioRecorder`, — и он существовал
/// затем, чтобы первый мог не работать: на macOS до 14.4 тапов на процессы нет
/// вовсе. Удалён 2026-07-29 вместе с подъёмом минимума до 14.4. Причина не в
/// экономии строк: две ветки захвата — это две правды про то, как устроены
/// дорожки (у одной общие часы, у другой сдвиг и дрожание), и всё, что ниже по
/// конвейеру, вынуждено уметь обе.
///
/// Остался ровно один осмысленный отказ — mic-only, и он не деградация пути, а
/// состояние записи.
public enum CapturePath: String, Equatable, CaseIterable {
    /// Общие часы: агрегатное устройство с микрофоном и тапом внутри, одна
    /// IOProc, обе дорожки сэмпл в сэмпл. Разрешение «Запись экрана» не нужно.
    case processTap = "tap"
    /// Только микрофон. Не отказ: половина записи лучше, чем ничего, и человеку
    /// об этом говорят.
    case microphoneOnly = "mic"
}

/// Что известно про машину в момент старта записи.
public struct CaptureCapabilities: Equatable {

    /// Пользователь не выключил системный звук в настройках.
    public let wantsSystemAudio: Bool
    /// Путь общих часов **проверен на этой машине** прогревом. Не «поддерживает
    /// ли система» — минимум приложения и так 14.4, — а «дали ли нам
    /// разрешение»: спросить его нечем, только попробовать.
    public let sharedClockReady: Bool

    public init(wantsSystemAudio: Bool, sharedClockReady: Bool) {
        self.wantsSystemAudio = wantsSystemAudio
        self.sharedClockReady = sharedClockReady
    }
}

public enum CapturePathPolicy {

    /// Лестница путей: пробуем сверху вниз, пока какой-нибудь не поднимется.
    ///
    /// Список, а не один ответ, хотя ступеней осталось две: «поднимется» — это
    /// факт времени выполнения. Разрешение на захват звука спросить заранее
    /// нельзя (API нет: отказ выглядит как тишина), тап может не создаться,
    /// агрегат может не собраться.
    ///
    /// Последняя ступень всегда `microphoneOnly`: она не может не подняться, и
    /// без неё лестница кончалась бы отказом записывать вообще.
    public static func ladder(_ capabilities: CaptureCapabilities) -> [CapturePath] {
        guard capabilities.wantsSystemAudio, capabilities.sharedClockReady else {
            return [.microphoneOnly]
        }
        return [.processTap, .microphoneOnly]
    }

    /// Нужно ли захвату разрешение «Запись экрана». Никогда — и это отдельное
    /// утверждение, а не следствие удаления SCK: запись экрана в приложении
    /// осталась, но она нужна **детектору встреч** (заголовки окон), и путать
    /// эти два запроса нельзя. Человек, отказавший в записи экрана, теряет
    /// автозапуск в части платформ, но не собеседников в записи.
    public static func needsScreenRecording(_ path: CapturePath) -> Bool { false }
}

/// Смена аудио-устройства посреди записи.
///
/// # Почему это не «поймал уведомление — перезапустил»
///
/// Одно подключение AirPods роняет в систему несколько смен подряд: сначала
/// вход, потом выход, потом ещё раз выход, когда профиль устаканился. Каждый
/// перезапуск тапа и агрегата — это дыра в записи. Реагировать на каждое
/// уведомление означает нашинковать полсекунды звука в мелкую тишину именно в
/// тот момент, когда человек надевает наушники и начинает говорить.
///
/// Поэтому: смены копятся окном, перезапуск делается один, и только если
/// состояние действительно другое.
///
/// # Что сюда приходит
///
/// Не идентификатор одного устройства, а **подпись состояния**: вход, выход и
/// признак того, что устройство из состава агрегата ещё существует. Агрегат
/// держит и вход, и выход по UID, поэтому устареть его может заставить любое из
/// трёх.
///
/// Цена ошибки несимметрична, и это выбор, а не недосмотр: лишняя пересборка
/// вписывает в запись честную паузу в доли секунды, пропущенная — оставляет нас
/// писать устройство, которого уже нет, до самого конца встречи. Поэтому при
/// сомнении пересобираемся.
public struct DeviceChangeCoalescer {

    public enum Decision: Equatable {
        /// Ничего не изменилось по существу, либо ещё идёт окно ожидания.
        case ignore
        /// Пересобрать тап и агрегат.
        case restart
        /// Пересобирали слишком часто — дальше только портить запись.
        /// Продолжаем тем, что есть, и помечаем запись. Событие терминальное и
        /// приходит **один раз**: второй такой же ответ вызывающему нечего
        /// делать, а состояние «сдались» ему всё равно уже известно.
        case giveUp
    }

    /// Окно, внутри которого несколько уведомлений считаются одним событием.
    private let debounce: TimeInterval
    /// Потолок перезапусков за запись. Устройство, которое дёргается двадцать
    /// раз, сломано (или это виртуальная карта в цикле) — двадцать первый
    /// перезапуск ничего не починит.
    private let maxRestarts: Int

    /// Отложенная смена. Отдельный тип, а не пара опционалов: «ждём переезда на
    /// *никакое* устройство» (монитор выключили, гарнитуру выдернули) — это
    /// ровно тот случай, который надо ловить, и в паре `String?` он неотличим
    /// от «ничего не ждём».
    private struct Pending {
        let uid: String?
        let since: TimeInterval
    }

    private var boundDeviceUID: String?
    private var pending: Pending?
    private var restarts = 0
    private var gaveUp = false

    public init(boundDeviceUID: String?, debounce: TimeInterval = 1.5, maxRestarts: Int = 12) {
        self.boundDeviceUID = boundDeviceUID
        self.debounce = debounce
        self.maxRestarts = maxRestarts
    }

    public var restartCount: Int { restarts }
    public var currentDeviceUID: String? { boundDeviceUID }

    /// Пересборка прошла — теперь мы сидим вот на этом. Счётчик перезапусков не
    /// трогается: он про то, сколько раз запись уже платила за переключения.
    public mutating func rebind(to deviceUID: String?) {
        boundDeviceUID = deviceUID
        pending = nil
    }
    /// Перезапуски исчерпаны: запись доживает на том, что есть.
    public var hasGivenUp: Bool { gaveUp }

    /// Система сообщила, что устройство теперь `deviceUID`.
    public mutating func observe(deviceUID: String?, at now: TimeInterval) -> Decision {
        guard !gaveUp else { return .ignore }
        guard deviceUID != boundDeviceUID else {
            // Вернулись к тому, на чём и сидим — ждать больше нечего.
            pending = nil
            return .ignore
        }
        // Явное сравнение, а не `pending?.uid != deviceUID`: там сравнивались бы
        // `String??` с `String?`, и «ждём переезда в никуда» схлопывалось бы с
        // «ничего не ждём» — ровно тот случай, ради которого `Pending` и завели.
        let alreadyWaitingForThis = pending.map { $0.uid == deviceUID } ?? false
        if !alreadyWaitingForThis {
            pending = Pending(uid: deviceUID, since: now)
        }
        return .ignore
    }

    /// Истекло ли окно ожидания. Вызывается по таймеру: только здесь
    /// принимается решение перезапускать, и только один раз на серию.
    public mutating func settle(at now: TimeInterval) -> Decision {
        guard !gaveUp, let pending else { return .ignore }
        guard now - pending.since >= debounce else { return .ignore }
        self.pending = nil
        guard pending.uid != boundDeviceUID else { return .ignore }
        guard restarts < maxRestarts else {
            gaveUp = true
            return .giveUp
        }
        restarts += 1
        boundDeviceUID = pending.uid
        return .restart
    }
}
