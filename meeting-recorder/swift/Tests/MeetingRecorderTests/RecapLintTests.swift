import XCTest
@testable import PropellerPure

/// Названо по тому, что видит человек в готовом конспекте. Каждый случай ниже
/// пришёл из реального прогона по архиву — это то, что модель написала на самом
/// деле, а не то, что она могла бы написать.
final class RecapLintTests: XCTestCase {

    private func grounded(_ recap: String, transcript: String) -> String {
        RecapLint.grounded(recap, transcript: transcript).recap
    }

    private func kinds(_ recap: String, transcript: String = "") -> [RecapLint.Kind] {
        RecapLint.findings(recap: recap, transcript: transcript).map(\.kind)
    }

    /// Худшая из выдумок: срок, которого никто не называл. Через неделю его уже
    /// не отличить от настоящего.
    func testСрокКоторогоНеБылоНаВстрече() {
        let recap = "## Задачи\n- **Левон** — прислать доки к пятнице.\n"
        let transcript = "**Левон** · 00:10\nПришлю доки, как соберу.\n"
        XCTAssertEqual(kinds(recap, transcript: transcript), [.unspokenDeadline])
    }

    func testНазванныйСрокНеСчитаетсяВыдумкой() {
        let recap = "## Задачи\n- **Левон** — прислать доки к пятнице.\n"
        let transcript = "**Левон** · 00:10\nДавай к пятнице пришлю, успею.\n"
        XCTAssertEqual(kinds(recap, transcript: transcript), [])
    }

    func testОтветственныйПризрак() {
        let recap = """
        ## Задачи
        - **Система** — подготовить документы.
        - **Слава (или участник с ответственностью)** — собрать бриф.
        """
        XCTAssertEqual(kinds(recap).filter { $0 == .ghostOwner }.count, 2)
    }

    /// Появилось, когда редактору дали инструкции приказным тоном и он перенёс
    /// тон в документ: девять таких строк на восьми встречах.
    func testПовелительноеНаклонение() {
        let recap = """
        ## Решения
        - Используйте существующий стейтбук как фундамент.
        - **Левон** — проведите очистку кода.
        """
        XCTAssertEqual(kinds(recap).filter { $0 == .imperative }.count, 2)
    }

    /// Ловушка предыдущей проверки: обычные слова, кончающиеся так же.
    func testОбычныеСловаНеПутаютсяСПриказом() {
        let recap = "## Итог\n- Договорились о работе на сайте и в чате.\n"
        XCTAssertFalse(kinds(recap).contains(.imperative))
    }

    func testПассивИКанцелярит() {
        let recap = "## Решения\n- Было решено, что смета будет подготовлена в рамках проекта.\n"
        let found = kinds(recap)
        XCTAssertTrue(found.contains(.passive))
        XCTAssertTrue(found.contains(.clerical))
    }

    /// «Данные» — это data, обычное слово встречи про продукт; канцелярит —
    /// «данный вопрос». Правило, которое их путает, портит нормальный текст.
    func testДанныеЭтоНеКанцелярит() {
        XCTAssertFalse(kinds("- Договорились хранить данные в облаке.").contains(.clerical))
        XCTAssertTrue(kinds("- Договорились закрыть данный вопрос.").contains(.clerical))
    }

    func testДлинноеПредложение() {
        let long = "- " + Array(repeating: "слово", count: 30).joined(separator: " ") + "."
        XCTAssertEqual(kinds(long), [.longSentence])
        let short = "- " + Array(repeating: "слово", count: 10).joined(separator: " ") + "."
        XCTAssertEqual(kinds(short), [])
    }

    /// Заголовок документа и блок заметок пишет приложение, а не модель.
    /// Правя их, редактор переписывал бы заметки пользователя.
    func testСистемныеБлокиНеПроверяются() {
        let recap = """
        # Встреча — рекап

        ## Решения
        - Договорились начать в понедельник.

        ## Заметки

        Было решено всё в рамках данного проекта.
        """
        let transcript = "**Левон** · 00:01\nНачнём в понедельник.\n"
        XCTAssertEqual(kinds(recap, transcript: transcript), [])
    }

    /// Список обрезается — и обрезаться должны длинные предложения, а не
    /// выдуманный срок: он дороже.
    func testСамоеВажноеНеВыпадаетИзОбрезанногоСписка() {
        var findings = (0..<40).map { RecapLint.Finding(kind: .longSentence, text: "\(25 + $0) слов") }
        findings.append(RecapLint.Finding(kind: .unspokenDeadline, text: "к пятнице"))
        let notes = RecapLint.editorNotes(findings, limit: 5)
        XCTAssertTrue(notes.contains("к пятнице"), notes)
        XCTAssertEqual(notes.components(separatedBy: "\n- ").count - 1, 5)
    }

    /// Указания редактору не должны звучать как приказ: он копирует их тон в
    /// документ. Это тот же дефект, что проверка `.imperative` ловит на выходе.
    func testУказанияРедактору_ОписываютРезультатАНеПриказывают() {
        let notes = RecapLint.editorNotes([
            .init(kind: .unspokenDeadline, text: "к пятнице"),
            .init(kind: .passive, text: "было решено"),
        ])
        for forbidden in ["убери", "перепиши", "исправь каждое", "разбей"] {
            XCTAssertFalse(notes.lowercased().contains(forbidden), "приказ в указании: \(forbidden)")
        }
        XCTAssertTrue(notes.contains("в исправленном тексте"))
    }

    func testЧистыйКонспектНеДаётУказаний() {
        let recap = "## Решения\n- Договорились отказаться от диплинков.\n"
        XCTAssertEqual(kinds(recap), [])
        XCTAssertEqual(RecapLint.editorNotes([]), "")
    }

    /// Редактура однажды выбросила «Ход обсуждения» целиком, и страховка этого
    /// не заметила: она считала пункты, а секция состояла из абзацев.
    func testПропавшаяСекцияЭтоПотеряСодержания() {
        let before = RecapLint.shape(of: """
        ## Решения
        - Отказались от диплинков.

        ## Ход обсуждения
        [12:45] Спорили про хостинг и остановились на бесплатном.
        """)
        let after = RecapLint.shape(of: """
        ## Решения
        - Отказались от диплинков.
        """)
        XCTAssertEqual(after.lostContentComparedTo(before), "пропала секция «Ход обсуждения»")
    }

    func testПотеряТретиПунктов() {
        let before = RecapLint.Shape(sections: ["Решения"], bullets: 17)
        let after = RecapLint.Shape(sections: ["Решения"], bullets: 10)
        XCTAssertEqual(after.lostContentComparedTo(before), "пунктов стало 10 вместо 17")
    }

    /// Здоровая редактура ужимает список на пункт-другой — это не потеря, и
    /// откатывать её значит выбрасывать всю проделанную работу над формой.
    func testНебольшоеСокращениеНеСчитаетсяПотерей() {
        let before = RecapLint.Shape(sections: ["Итог", "Решения"], bullets: 17)
        let after = RecapLint.Shape(sections: ["Итог", "Решения"], bullets: 15)
        XCTAssertNil(after.lostContentComparedTo(before))
    }

    /// Побочный эффект правила «пассив → глагол с действующим лицом»: редактору
    /// велели найти подлежащее, и он его сочинил. Никаких «сторонников» на
    /// встрече двух человек не было.
    func testВыдуманноеДействующееЛицо() {
        let recap = """
        ## Решения
        - Сторонники согласились внедрить единую компонентную базу.
        - Команда дообучится по созданию иконок.
        """
        XCTAssertEqual(kinds(recap).filter { $0 == .inventedActor }.count, 2)
    }

    /// «Участники» само по себе — обычное слово, и правило не должно портить
    /// нормальную фразу ради красивой находки.
    func testОбычноеУпоминаниеУчастниковНеСчитаетсяВыдумкой() {
        XCTAssertFalse(kinds("- Ссылку получили все участники встречи.").contains(.inventedActor))
    }

    /// На встрече говорят «сегодня к шести», а не «~6 дней»: посчитанный срок —
    /// арифметика поверх того, чего модель не знает.
    func testПосчитанныйСрок() {
        XCTAssertEqual(kinds("- Левон готовит доки (срок: ~6 дней)."), [.computedDeadline])
        XCTAssertEqual(kinds("- Иконки в течение 2 недель."), [.computedDeadline])
    }

    /// Замер по решётке моделей (`tools/recap-lab`, 2026-08-12): 9B прочитала
    /// метку времени реплики как дедлайн. `unspokenDeadline` тут бессилен —
    /// «20:34» в транскрипте есть, это таймкод.
    func testТаймкодПрочитанныйКакСрок() {
        let recap = "## Задачи\n- **Левон** — подготовить макет к 20:34 текущего дня встречи.\n"
        let transcript = "**Левон** · 20:34\nДавайте сделаем ещё одну итерацию.\n"
        XCTAssertTrue(kinds(recap, transcript: transcript).contains(.timecodeDeadline))
    }

    /// Обе формы прошли мимо старой проверки: она знала только именительный
    /// падеж и восемь глаголов.
    func testСторонникиВДругомПадежеИСДругимГлаголом() {
        XCTAssertTrue(kinds("- Сторонники пришли к консенсусу по главной.").contains(.inventedActor))
        XCTAssertTrue(kinds("- Сторонникам поручено сделать итерацию.").contains(.inventedActor))
    }

    // MARK: - Вырезка

    /// Задача остаётся, выдуманный исполнитель уходит. Пунктов столько же:
    /// `polished(...)` читает изменение формы как потерю содержания.
    func testПризрачныйИсполнительУходитАЗадачаОстаётся() {
        let recap = "## Задачи\n- **Команда дизайна VK Музыка** — доработать плашки.\n"
        let grounded = grounded(recap, transcript: "")
        XCTAssertEqual(grounded, "## Задачи\n- Доработать плашки.\n")
        XCTAssertEqual(RecapLint.shape(of: grounded).bullets, RecapLint.shape(of: recap).bullets)
    }

    /// Метка диаризации — не человек. qwen2.5:7b подписала ею задачу.
    func testМеткаСпикераНеСчитаетсяИсполнителем() {
        XCTAssertEqual(
            grounded("- **Спикер S1** — доработать текстовое описание.", transcript: ""),
            "- Доработать текстовое описание."
        )
    }

    /// Живого человека вырезка не трогает — иначе она стирала бы правду.
    func testНастоящийИсполнительОстаётся() {
        let recap = "- **Левон** — подготовить макеты."
        XCTAssertEqual(grounded(recap, transcript: ""), recap)
    }

    func testВыдуманныйСрокУходитВместеСТире() {
        let recap = "- **Левон** — прислать доки — **к пятнице**."
        let transcript = "**Левон** · 00:10\nПришлю, как соберу.\n"
        XCTAssertEqual(grounded(recap, transcript: transcript), "- **Левон** — прислать доки.")
    }

    func testНазванныйСрокНеВырезается() {
        let recap = "- **Левон** — прислать доки к пятнице."
        let transcript = "**Левон** · 00:10\nДавай к пятнице пришлю.\n"
        XCTAssertEqual(grounded(recap, transcript: transcript), recap)
    }

    func testПосчитанныйСрокУходитВместеСоСкобками() {
        XCTAssertEqual(
            grounded("- Левон готовит доки (срок: ~6 дней).", transcript: ""),
            "- Левон готовит доки."
        )
    }

    /// Скобка с именем — единственное, что модель про ответственного знала.
    /// Снести заголовок целиком значило бы выбросить его вместе с призраком.
    func testИмяИзСкобкиСтановитсяОтветственным() {
        XCTAssertEqual(
            grounded("- **Команда дизайна (Левон)** — убрать подстрочники.", transcript: ""),
            "- **Левон** — убрать подстрочники."
        )
    }

    /// Дословно из прогонов решётки (`tools/recap-lab`, 2026-08-12): четыре
    /// модели, четыре разных призрака, ни одного живого имени.
    func testПризракиИзРеальныхПрогонов() {
        let lines = [
            "- **Speaker S1** — доработать макет главной страницы.",
            "- **Команда VK Музыка** — подготовить концепцию отображения потоков.",
            "- **Команда PG x VK Музыка** — реализовать облегчённый рич-текст.",
            "- **Команда дизайна** — доработать форму отображения кластеров.",
        ]
        for line in lines {
            let grounded = grounded(line, transcript: "")
            XCTAssertFalse(grounded.contains("**"), "исполнитель остался: \(grounded)")
            XCTAssertTrue(grounded.hasPrefix("- "), "пункт потерян: \(grounded)")
        }
    }

    /// Вырезка работает только по пунктам: прозаические секции («Итог», «Ход
    /// обсуждения») она не трогает, там нет назначений.
    func testПрозаНеТрогается() {
        let prose = "## Итог\nКоманда договорилась о трёх уровнях к 20:34.\n"
        XCTAssertEqual(grounded(prose, transcript: ""), prose)
    }
}
