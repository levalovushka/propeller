import XCTest
@testable import PropellerPure

/// Приложение доделывает начатое само — три места, где оно этого не делало.
///
/// Замер за 30 дней: 13 человек не получили **ни одного** конспекта, у 8 из них
/// локальная выдача стартовала (`Model.fetch ≥ 1`), упала (`Ollama.setup{fail}`,
/// причина `pull`) и ни разу не дошла до успеха. От контрольной группы, которая
/// упёрлась в то же самое и вылечилась, их отличала не причина отказа, а число
/// доведённых до конца попыток.
///
/// Названо по тому, что видел человек, а не по функции под тестом.

// MARK: - Д1. Приложение убивало собственную загрузку модели

final class EngineIdleStopTests: XCTestCase {

    func testПодЖивойЗагрузкойМоделиДвижокНеГаснет() {
        // Сценарий целиком: идёт пул на 3,4 ГБ (десятки минут), кончилась любая
        // фаза конвейера, `endPipelineWork` завёл гашение через 30 с. Через 30 с
        // `ollama serve` получал SIGTERM, стрим падал, лестница делала шаг.
        var use = EngineIdleStop()
        use.begin()
        XCTAssertEqual(
            use.whenTimerFires, .postpone,
            "движок не простаивает — на нём идёт выдача модели"
        )
    }

    func testЭтоПереносАНеОтмена() {
        // Отмена оставила бы 3,4 ГБ весов в памяти до конца дня — ровно тот
        // вред, ради которого таймер и заводили.
        var use = EngineIdleStop()
        use.begin()
        XCTAssertEqual(use.whenTimerFires, .postpone)
        use.end()
        XCTAssertEqual(use.whenTimerFires, .stop, "работа кончилась — модель обязана уйти из памяти")
    }

    func testБезРаботыГаснетСразу() {
        // Обычный случай: конвейер догнал архив, выдача не идёт.
        XCTAssertEqual(EngineIdleStop().whenTimerFires, .stop)
    }

    func testВтораяРаботаДержитДвижокПослеЗакрытияПервой() {
        // Саммари по прошлой встрече и выдача модели могут перекрываться;
        // конец первой — не повод гасить сервер под второй.
        var use = EngineIdleStop()
        use.begin()
        use.begin()
        use.end()
        XCTAssertEqual(use.whenTimerFires, .postpone, "одна работа ещё идёт")
        use.end()
        XCTAssertEqual(use.whenTimerFires, .stop)
    }
}

// MARK: - Д2. Попытка и занятость движка — один факт, а не два

final class ProvisioningAttemptBracketTests: XCTestCase {

    func testПокаИдётПопыткаГашениеВообщеНеЗаводится() {
        // Первая преграда, дешёвая: тот, кто заводит таймер (конец фазы
        // конвейера), про пул не знает ничего — он знает только, что **его**
        // работа кончилась, и раньше на этом основании гасил.
        XCTAssertFalse(EngineIdleStop.mayArm(provisioningInFlight: true))
        XCTAssertTrue(EngineIdleStop.mayArm(provisioningInFlight: false))
    }

    func testЛюбойВыходПопыткиВозвращаетПравоГасить() {
        // Выходов у попытки три — успех, отказ, отмена, — и незакрытая скобка
        // была бы тем же дефектом наоборот: 3,4 ГБ в памяти навсегда.
        for _ in 0..<3 {
            var use = EngineIdleStop()
            use.begin()
            use.end()
            XCTAssertEqual(use.whenTimerFires, .stop)
        }
    }

    func testЛишнееЗакрытиеНеОткрываетДорогуГашению() {
        // Уход счётчика в минус означал бы, что следующая выдача начинается с
        // уже разрешённым гашением — то есть дефект возвращается молча.
        var use = EngineIdleStop()
        use.end()
        use.end()
        XCTAssertEqual(use.users, 0)
        use.begin()
        XCTAssertEqual(use.whenTimerFires, .postpone)
    }
}

// MARK: - Д3. «Файл на диске» — это не «саммари возможно»

final class SummaryObligationTests: XCTestCase {

    private func readiness(
        modelInstalled: Bool = true,
        engineInstalled: Bool = true,
        lastServe: ModelProvisioning.EngineVerdict = .unknown
    ) -> ModelProvisioning.Readiness {
        .init(
            modelInstalled: modelInstalled,
            engineInstalled: engineInstalled,
            lastServe: lastServe
        )
    }

    func testВесаНаМестеАДвижкаНетОбязательствоВисит() {
        // Битая распаковка, слетевший `installed-version.txt`, поднятый пин
        // версии. Веса при этом лежат и врут, что всё на месте.
        XCTAssertEqual(
            ModelProvisioning.summaryPossible(readiness(engineInstalled: false)),
            .owed
        )
    }

    func testСерверНеВсталЗначитОбязательствоВисит() {
        // Тот самый тупик: обязательство снимали по весам, лестницу гасили,
        // монитор сети снимали — и чинить неподнимающийся сервер оставалось
        // некому, кроме `.blocked` в конвейере с потолком в полчаса.
        XCTAssertEqual(
            ModelProvisioning.summaryPossible(readiness(lastServe: .failed)),
            .owed
        )
    }

    func testСерверОтвечалЗначитЗакрыто() {
        // `adopt-if-present`: движок может быть и не наш (Ollama.app, Homebrew),
        // и файловые проверки про него не скажут ничего. Ответивший сервер —
        // единственный неопровержимый признак.
        XCTAssertEqual(
            ModelProvisioning.summaryPossible(readiness(engineInstalled: false, lastServe: .up)),
            .discharged
        )
    }

    func testБезВесовНеЗакрываетДажеЖивойСервер() {
        for verdict in ModelProvisioning.EngineVerdict.allCases {
            XCTAssertEqual(
                ModelProvisioning.summaryPossible(readiness(modelInstalled: false, lastServe: verdict)),
                .owed,
                "\(verdict)"
            )
        }
    }

    func testЗдоровыйЗапускНеПлатитЗаПроверку() {
        // Обычный случай сразу после выдачи: сервер в этом запуске никто не
        // просил. Ответ обязан быть «закрыто» без единого `ollama serve` —
        // иначе лекарство дороже болезни.
        XCTAssertEqual(ModelProvisioning.summaryPossible(readiness()), .discharged)
    }
}
