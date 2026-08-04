import XCTest
@testable import PropellerPure

/// Тупиков не бывает — `design/no-dead-ends.md` как тесты.
///
/// Названы по тому, что видел человек, а не по функции под тестом.

// MARK: - Э1. Транскрипт не заложник диаризации

final class StemSpeakerSplitTests: XCTestCase {

    func testБезДиаризацииРечьСМикрофонаЭтоВладелец() {
        // Единственное, что дорожки доказывают: пришедшее с микрофона — моё.
        XCTAssertEqual(
            SourceAwareSpeaker.stemsOnly(source: .microphone, ownerName: "Левон"),
            "Левон"
        )
    }

    func testВсёОстальноеЭтоСобеседникВЕдинственномЧисле() {
        // Сколько людей на той стороне — ровно то, чего без кластеризации знать
        // нельзя, поэтому «Speaker 1, 2, 3» было бы обещанием без основания.
        for source in [SourceAwareSpeaker.Source.system, .mixed, .unknown] {
            XCTAssertEqual(
                SourceAwareSpeaker.stemsOnly(source: source, ownerName: "Левон"),
                "Собеседник",
                "\(source)"
            )
        }
    }

    func testПересечениеРечиНеПриписываетсяВладельцу() {
        // «Все — это я» — та самая поломка, ради которой этот файл и существует:
        // если в обеих дорожках энергия, на той стороне точно кто-то говорит.
        XCTAssertNotEqual(
            SourceAwareSpeaker.stemsOnly(source: .mixed, ownerName: "Левон"),
            "Левон"
        )
    }

    func testБезИмениВОнбордингеВладелецНазываетсяЯ() {
        XCTAssertEqual(
            SourceAwareSpeaker.stemsOnly(source: .microphone, ownerName: "   "),
            "Я"
        )
    }

    func testСтарыеЗаписиСчитаютсяРазделённымиПоСпикерам() {
        // Поле появилось позже; всё, что расшифровано до него, кластеризовалось —
        // сборка без этого поля другого пути закончить расшифровку не имела.
        let old: SpeakerAttribution? = nil
        XCTAssertNil((old ?? .diarized).disclosure)
    }

    func testРазделениеПоДорожкамПризнаётсяВслух() {
        // Молчаливая деградация опаснее ошибки: карточка обязана сказать, чем
        // этот транскрипт отличается (§7).
        XCTAssertNotNil(SpeakerAttribution.stems.disclosure)
        XCTAssertNil(SpeakerAttribution.diarized.disclosure)
    }

    func testУКаждойАтрибуцииЕстьРешениеПроРаскрытие() {
        // Новый способ назвать спикеров обязан ответить, признаётся он или нет.
        for attribution in SpeakerAttribution.allCases {
            _ = attribution.disclosure
            XCTAssertFalse(attribution.rawValue.isEmpty)
        }
    }
}

// MARK: - Э2. Никто не сдаётся

final class NoGivingUpTests: XCTestCase {

    /// Единственный вид отказа, который не планирует следующую попытку, — тот, у
    /// которого нет входа. Новый вид, добавленный без этой мысли, покраснеет
    /// здесь, а не всплывёт тупиком у человека через месяц.
    func testРовноОдинВидОтказаНеПовторяется() {
        let hopeless = FailureKind.allCases.filter { !$0.isRetryable }
        XCTAssertEqual(hopeless, [.terminal])
    }

    /// Лестница обязана иметь потолок (батарейка) и не иметь конца (тупики).
    func testЛестницаИмеетПотолокНоНеИмеетКонца() {
        XCTAssertEqual(PipelineRetry.steps.last, 3600)
        XCTAssertEqual(PipelineRetry.steps, PipelineRetry.steps.sorted())
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for attempt in [1, 5, 50, 500] {
            XCTAssertNotNil(
                PipelineRetry.nextAttempt(
                    kind: .transient, attempt: attempt, phase: .summarizing, after: t0
                ),
                "попытка \(attempt)"
            )
        }
    }
}

// MARK: - Э3. LLM — часть установки

final class ModelProvisioningTests: XCTestCase {

    private func context(
        usesLocalModel: Bool = true,
        modelInstalled: Bool = false,
        busyWithAudio: Bool = false,
        downloadInFlight: Bool = false
    ) -> ModelProvisioning.Context {
        .init(
            usesLocalModel: usesLocalModel,
            modelInstalled: modelInstalled,
            busyWithAudio: busyWithAudio,
            downloadInFlight: downloadInFlight
        )
    }

    func testМоделиНетЗначитКачаемБезСпроса() {
        // Раньше не качалось ничего, пока человек не нажмёт «Скачать» на пятом
        // экране онбординга: приложение работало или не работало в зависимости
        // от того, понял ли он тот экран.
        XCTAssertEqual(ModelProvisioning.decide(context()), .fetch)
    }

    func testПропавшуюМодельПочинятТемЖеПутём() {
        // Первая выдача и починка — одно решение: пропавшая модель есть
        // пропавшая модель, независимо от причины.
        XCTAssertEqual(ModelProvisioning.decide(context(modelInstalled: false)), .fetch)
        XCTAssertEqual(ModelProvisioning.decide(context(modelInstalled: true)), .alreadyThere)
    }

    func testВоВремяЗаписиНеКачаем() {
        // Запись и загрузка делят диск и сеть, и запись важнее. Поводов вернуться
        // ещё много: каждый запуск и каждая остановка пайплайна.
        XCTAssertEqual(ModelProvisioning.decide(context(busyWithAudio: true)), .waitForQuiet)
    }

    func testСОблачнымКлючомТриСПоловинойГигабайтаНеТянем() {
        for provider in ["openai", "claude", "off"] {
            XCTAssertFalse(ModelProvisioning.usesLocalModel(providerRawValue: provider), provider)
            XCTAssertEqual(
                ModelProvisioning.decide(context(usesLocalModel: false)), .notOurs, provider
            )
        }
    }

    func testАвтоСчитаетсяЛокальным() {
        // `auto` без облачного ключа сваливается на локальную модель, а ключа у
        // большинства нет — иначе саммари не будет ни у кого из них.
        XCTAssertTrue(ModelProvisioning.usesLocalModel(providerRawValue: "auto"))
        XCTAssertTrue(ModelProvisioning.usesLocalModel(providerRawValue: "ollama"))
    }

    func testНезнакомыйПровайдерИзБудущейСборкиНеОставляетБезСаммари() {
        // Префы переживают откат версии. Качать «на всякий случай» дешевле, чем
        // молча остаться без модели.
        XCTAssertTrue(ModelProvisioning.usesLocalModel(providerRawValue: "gemini"))
    }

    func testДваЗапускаПодрядНеНачинаютДвеЗагрузки() {
        XCTAssertEqual(ModelProvisioning.decide(context(downloadInFlight: true)), .inFlight)
    }

    func testЗанятостьНеПеребиваетТогоЧтоМодельНаМесте() {
        // «Подождём» про модель, которая уже есть, — это ложь в телеметрии и
        // лишний вопрос к диску.
        XCTAssertEqual(
            ModelProvisioning.decide(context(modelInstalled: true, busyWithAudio: true)),
            .alreadyThere
        )
    }
}

// MARK: - Э4. Слишком большой кусок — это команда, а не отказ

final class ChunkDivisionTests: XCTestCase {

    func testНаСлишкомБольшойКусокОтвечаемДелением() {
        // 413 говорит, что арифметика чанкера не сошлась на этом файле, — а не
        // что встречу нельзя расшифровать.
        XCTAssertEqual(GigasttChunking.smallerChunk(after: 1200), 600)
        XCTAssertEqual(GigasttChunking.smallerChunk(after: 600), 300)
    }

    func testДелениеУпираетсяВПолИНеУходитВНоль() {
        // Ниже получаса секунд 413 — это уже не размер, а сломанный сайдкар:
        // им занимается лестница, а не деление.
        XCTAssertEqual(GigasttChunking.minChunkSeconds, 30)
        XCTAssertNil(GigasttChunking.smallerChunk(after: 45), "22 с — уже ниже пола")
        XCTAssertNil(GigasttChunking.smallerChunk(after: 30))
        XCTAssertNil(GigasttChunking.smallerChunk(after: 1))
    }

    func testЛюбаяДлинаСходитсяКПредставимомуКуску() {
        // Восьмичасовая встреча (потолок записи) обязана дойти до пола за
        // обозримое число делений, а не зациклиться.
        var seconds = 8 * 3600.0
        var divisions = 0
        while let smaller = GigasttChunking.smallerChunk(after: seconds) {
            seconds = smaller
            divisions += 1
            XCTAssertLessThan(divisions, 64, "деление обязано сходиться")
        }
        XCTAssertLessThan(seconds, GigasttChunking.minChunkSeconds * 2)
    }

    func testПоловинкиСклеиваютсяПоСмещениюОтНачалаКуска() {
        // Каждая половинка отдаёт времена от своего начала. Склейка с нулевым
        // смещением — та ошибка, из-за которой вторая половина встречи легла бы
        // поверх первой.
        let first = [GigasttChunking.Segment(start: 0, end: 5, text: "раз")]
        let second = [GigasttChunking.Segment(start: 0, end: 5, text: "два")]
        let merged = GigasttChunking.merge([(offset: 0, segments: first),
                                            (offset: 600, segments: second)])
        XCTAssertEqual(merged.map(\.start), [0, 600])
        XCTAssertEqual(merged.map(\.text), ["раз", "два"])
    }
}
