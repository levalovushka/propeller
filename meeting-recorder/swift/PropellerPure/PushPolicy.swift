import Foundation

/// # Системные уведомления — одно место, где решается «слать или нет»
///
/// Правила и разбор каждого повода — `design/notifications.md`. Здесь их
/// исполняемая часть.
///
/// Внутри приложения ничего не «сообщается»: состояние живёт на том объекте, к
/// которому относится, — на строке встречи или на строке, которая начинает
/// запись. Системный баннер нужен только там, где ждать, пока человек откроет
/// окно, нельзя: он в звонке, и записи либо не будет, либо она уже идёт.
///
/// Раньше каждый повод решал за себя прямо в `AppState`, и получалось так:
/// «Заметка сохранена» звучала посреди встречи, «Запись остановлена» сообщала
/// человеку о его собственном нажатии, а «Сохранено: файл.md» и «Саммари
/// готово» приходили парой на одну встречу.
public enum PushPolicy {

    /// Поводы, которые вообще доходят до системного центра уведомлений.
    ///
    /// Чего здесь нет — того и не должно быть. «Заметка сохранена»
    /// подтверждается вспышкой в самом оверлее, а не баннером со звуком в
    /// комнате, где идёт запись. Мало места, разросшаяся библиотека и
    /// восстановленные после падения записи не уведомляют вообще: делать по ним
    /// нечего, а последнее ещё и объявляло человеку, что *его* записи
    /// прервались, о нашем же сбое.
    public enum Kind: String, CaseIterable, Sendable {
        /// Запись началась сама. Единственный настоящий аларм приложения.
        case recordingStarted
        /// Остановились сами: звонок кончился или упёрлись в потолок 8 часов.
        case recordingAutoStopped
        /// Транскрипт лёг на диск.
        case transcriptSaved
        /// Встреча дочитана до конца — есть саммари.
        case meetingReady
        /// Нет доступа к микрофону, а записать просили.
        case micDenied
    }

    /// Всё, что нужно знать о моменте. Ровно те поля, которые у `AppState`
    /// уже есть, — политика не заводит собственного состояния.
    public struct Context: Equatable, Sendable {
        public var isRecording: Bool
        /// Окно открыто **и** приложение впереди: человек и так это видит.
        public var windowVisible: Bool
        public var appActive: Bool
        /// Встреча этой сессии, а не догон архива.
        public var isAwaited: Bool
        /// Разрешение на уведомления выдано.
        public var authorized: Bool
        /// За транскриптом последует саммари, значит «готово» ещё впереди.
        public var recapExpected: Bool

        public init(
            isRecording: Bool,
            windowVisible: Bool,
            appActive: Bool,
            isAwaited: Bool,
            authorized: Bool,
            recapExpected: Bool
        ) {
            self.isRecording = isRecording
            self.windowVisible = windowVisible
            self.appActive = appActive
            self.isAwaited = isAwaited
            self.authorized = authorized
            self.recapExpected = recapExpected
        }
    }

    public enum Surface: Equatable, Sendable {
        /// Молчим. Либо человек уже смотрит на это, либо ему нечего делать.
        case none
        case banner
        case bannerWithSound

        /// Хвост телеметрии: считаем и отправленные, и придушенные.
        public var signalName: String {
            switch self {
            case .none:            return "silent"
            case .banner:          return "banner"
            case .bannerWithSound: return "sound"
            }
        }
    }

    /// Куда уходит повод в этом контексте.
    public static func surface(for kind: Kind, in ctx: Context) -> Surface {
        switch kind {
        case .recordingStarted:
            // Без разрешения на уведомления действия «Не записывать» негде
            // нажать — и это всё, что из этого следует: встреча пишется молча.
            //
            // Здесь стоял вывод окна на себя, и он был хуже проблемы, которую
            // решал: окно выходило вперёд ровно в ту секунду, когда человек
            // говорит в звонке. На одном экране это выглядит как захват экрана
            // посреди встречи; на двух — просто не замечается, поэтому и жило
            // так долго. Замерено телеметрией 2026-08-21: 122 таких вывода у
            // 8 человек за 45 дней, чаще, чем баннеров, — то есть у большинства
            // авто-записывающих уведомления не разрешены. Останов лежит в
            // меню-баре и достижим всегда, лишняя запись удаляется после
            // встречи; кража фокуса не отменяется никогда.
            guard ctx.authorized else { return .none }
            // Единственный повод, который звучит во время записи. Записи одна
            // секунда, а аларм, которого не слышно, — не аларм.
            return .bannerWithSound

        case .recordingAutoStopped:
            guard ctx.authorized else { return .none }
            return seen(ctx) ? .none : .banner

        case .transcriptSaved:
            // Склейка: пока впереди саммари, транскрипт — это шаг машины, а не
            // новость человека. Одна встреча — одно «готово».
            guard !ctx.recapExpected else { return .none }
            return ready(ctx)

        case .meetingReady:
            return ready(ctx)

        case .micDenied:
            // В окне это строка «Новая запись», и она никуда не денется.
            // Баннер — только когда окна перед человеком нет: авто-запись
            // падает, пока он в Zoom, и встреча иначе не запишется молча.
            guard !seen(ctx) else { return .none }
            // Без уведомлений сказать это негде, кроме самой строки «Новая
            // запись», — и она это говорит, пока разрешение не изменится
            // (`micAccessDenied`). Окно на себя не выводится ни для чего.
            guard ctx.authorized else { return .none }
            return ctx.isRecording ? .banner : .bannerWithSound
        }
    }

    /// «Готово» — только для встречи, которую ждут, и только если человек не
    /// смотрит на неё прямо сейчас. Догон архива молчит целиком.
    private static func ready(_ ctx: Context) -> Surface {
        guard ctx.authorized, ctx.isAwaited else { return .none }
        return seen(ctx) ? .none : .banner
    }

    /// Человек уже перед этим экраном — сообщать ему то, что он видит, незачем.
    private static func seen(_ ctx: Context) -> Bool {
        ctx.windowVisible && ctx.appActive
    }
}
