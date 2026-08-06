import XCTest
@testable import PropellerPure

/// Что приложение говорит и где.
///
/// Тостов больше нет: всё, что приложение хотело сказать о встрече, говорит
/// строка этой встречи, а всё, что о записи, — строка, которая её начинает.
/// Правила и разбор каждого повода — `design/notifications.md`.
final class DeletedRowTests: XCTestCase {

    func testУдалённаяВстречаПоказываетЧтоЕёМожноВернуть() {
        // Отмена удаления была полосой, висевшей над списком. Теперь это вид
        // самой строки — той, которую удалили.
        let activity = SidebarRowMachine.activity(
            stage: .summarized, involvement: .idle, isTerminal: false,
            isDeletedUndoable: true
        )
        XCTAssertEqual(activity, .deletedUndoable)
        XCTAssertEqual(
            SidebarRowMachine.preview(activity: activity, phaseMessage: nil, topics: "темы"),
            "Удалена",
            "вместо тем — то, что с ней случилось"
        )
    }

    func testУдалениеПеребиваетЛюбоеДругоеСостояние() {
        // Записи уже нет в индексе: воркер над ней ничего не делает, и единственное,
        // ради чего строка ещё живёт, — секунды, в которые её можно вернуть.
        for stage in RecordingStage.allCases {
            let activity = SidebarRowMachine.activity(
                stage: stage,
                involvement: .working(.transcribing),
                isTerminal: true,
                isDeletedUndoable: true
            )
            XCTAssertEqual(activity, .deletedUndoable, "\(stage)")
        }
    }

    func testУдалённаяСтрокаНеБываетВыбранной() {
        // Иначе она рисуется как текущая ровно в тот момент, когда исчезает.
        let state = SidebarRowMachine.state(
            stage: .summarized, involvement: .idle, isTerminal: false,
            isSelected: true, isHovered: false, isDeletedUndoable: true
        )
        XCTAssertFalse(state.isSelected)
        XCTAssertEqual(state.activity, .deletedUndoable)
    }

    func testКаждыйВидСтрокиПопадаетНаДоску() {
        // Новый вид строки должен появиться в галерее сам, а не «когда вспомним».
        let drawn = Set(SidebarStateCatalog.meetingRows.map(\.state.activity))
        XCTAssertEqual(drawn, Set(SidebarRowActivity.allCases))
    }

    func testОбычнаяСтрокаНеЗнаетПроУдаление() {
        // Флаг по умолчанию выключен, иначе каждый вызывающий обязан о нём помнить.
        XCTAssertEqual(
            SidebarRowMachine.activity(stage: .recording, involvement: .idle, isTerminal: false),
            .recording
        )
    }
}

// MARK: - Пуши

final class PushPolicyTests: XCTestCase {

    private func context(
        isRecording: Bool = false,
        windowVisible: Bool = false,
        appActive: Bool = false,
        isAwaited: Bool = true,
        authorized: Bool = true,
        recapExpected: Bool = false
    ) -> PushPolicy.Context {
        .init(
            isRecording: isRecording,
            windowVisible: windowVisible,
            appActive: appActive,
            isAwaited: isAwaited,
            authorized: authorized,
            recapExpected: recapExpected
        )
    }

    func testЧеловекСмотритНаЭкранЗначитЕмуНеСообщают() {
        let seen = context(windowVisible: true, appActive: true)
        XCTAssertEqual(PushPolicy.surface(for: .meetingReady, in: seen), .none)
        XCTAssertEqual(PushPolicy.surface(for: .recordingAutoStopped, in: seen), .none)
        XCTAssertEqual(PushPolicy.surface(for: .micDenied, in: seen), .none,
                       "строка «Новая запись» уже говорит это в окне, которое перед человеком")
    }

    func testДогонАрхиваМолчит() {
        // Запуск, который должен двадцать саммари, не имеет права на двадцать
        // баннеров — это уже инвариант пайплайна, здесь он в одном месте.
        let catchUp = context(isAwaited: false)
        XCTAssertEqual(PushPolicy.surface(for: .meetingReady, in: catchUp), .none)
        XCTAssertEqual(PushPolicy.surface(for: .transcriptSaved, in: catchUp), .none)
    }

    func testОднаВстречаОдноГотово() {
        // Транскрипт молчит, пока впереди саммари, и говорит, когда саммари не
        // будет вообще.
        XCTAssertEqual(
            PushPolicy.surface(for: .transcriptSaved, in: context(recapExpected: true)),
            .none
        )
        XCTAssertEqual(
            PushPolicy.surface(for: .transcriptSaved, in: context(recapExpected: false)),
            .banner
        )
    }

    func testВоВремяЗаписиНичегоНеЗвучитКромеСамойЗаписи() {
        // Мы пишем звук в комнате: свой бип попадёт в транскрипт и прервёт
        // живого человека (R7).
        let during = context(isRecording: true)
        for kind in PushPolicy.Kind.allCases where kind != .recordingStarted {
            XCTAssertNotEqual(
                PushPolicy.surface(for: kind, in: during), .bannerWithSound,
                "\(kind) звучит во время записи"
            )
        }
        // Единственное исключение — сам старт: записи одна секунда, и аларм,
        // которого не слышно, не аларм.
        XCTAssertEqual(
            PushPolicy.surface(for: .recordingStarted, in: during),
            .bannerWithSound
        )
    }

    func testОтказМикрофонаПриЗакрытомОкнеДоходитДоЧеловека() {
        // Авто-запись падает, пока человек в Zoom. Состояние ждёт его в рельсе,
        // но узнать о нём он должен сейчас — иначе встреча не записалась молча.
        XCTAssertEqual(
            PushPolicy.surface(for: .micDenied, in: context(windowVisible: false)),
            .bannerWithSound
        )
    }

    func testБезРазрешенияНаУведомленияАлармИдётВОкно() {
        // «Не записывать» живёт в уведомлении: без уведомлений отказаться негде.
        let denied = context(authorized: false)
        XCTAssertEqual(PushPolicy.surface(for: .recordingStarted, in: denied), .window)
        XCTAssertEqual(PushPolicy.surface(for: .micDenied, in: denied), .window)
        // А хорошие новости в этом случае просто молчат.
        XCTAssertEqual(PushPolicy.surface(for: .meetingReady, in: denied), .none)
    }

    func testПоводовВсегоЧетыреИНиОдинИзНихНеПроСостояниеАрхива() {
        // Диск, разросшаяся библиотека и восстановленные записи уведомлений не
        // получают: делать по ним нечего, а последнее ещё и списывало наш сбой
        // на человека. Список поводов — это и есть весь бюджет.
        XCTAssertEqual(
            Set(PushPolicy.Kind.allCases.map(\.rawValue)),
            ["recordingStarted", "recordingAutoStopped", "transcriptSaved", "meetingReady", "micDenied"]
        )
    }

    func testБюджетШтатнойВстречиДваУведомления() {
        // Старт авто-записи и «готово» — всё (R4).
        let away = context()
        let normal: [PushPolicy.Kind] = [.recordingStarted, .transcriptSaved, .meetingReady]
        let audible = normal.filter {
            let surface = PushPolicy.surface(
                for: $0,
                in: $0 == .transcriptSaved ? context(recapExpected: true) : away
            )
            return surface != .none
        }
        XCTAssertEqual(audible, [.recordingStarted, .meetingReady])
    }
}
