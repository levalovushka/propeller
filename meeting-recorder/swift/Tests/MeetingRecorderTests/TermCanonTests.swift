import XCTest
@testable import PropellerPure

/// Названо по тому, что человек видит в конспекте: термин, который он произнёс,
/// написан так, как он его пишет. Каждый случай ниже взят из архива автора —
/// это формы, которые распознавание выдало на самом деле, а не придуманные.
final class TermCanonTests: XCTestCase {

    func testРаспознанноеИскажениеСтановитсяТермином() {
        XCTAssertEqual(TermCanon.normalize("майплайн упал"), "пайплайн упал")
        XCTAssertEqual(TermCanon.normalize("дискриптор блока"), "дескриптор блока")
        XCTAssertEqual(TermCanon.normalize("майнсет команды"), "майндсет команды")
        XCTAssertEqual(TermCanon.normalize("анбординг новичка"), "онбординг новичка")
        XCTAssertEqual(TermCanon.normalize("беклог"), "бэклог")
        XCTAssertEqual(TermCanon.normalize("бекенд"), "бэкенд")
    }

    /// Одна строка таблицы обязана чинить весь падеж: «джабов» и «джабы» пришли
    /// из одного и того же слова, и заводить строку на каждую форму — способ
    /// пропустить ту, которая встретится завтра.
    func testПадежныеФормыЧинятсяОднойСтрокой() {
        XCTAssertEqual(TermCanon.normalize("джаба"), "джоба")
        XCTAssertEqual(TermCanon.normalize("джабы встали"), "джобы встали")
        XCTAssertEqual(TermCanon.normalize("десять джабов"), "десять джобов")
    }

    func testНазваниеПродуктаТеряетПадежныйХвост() {
        XCTAssertEqual(TermCanon.normalize("лимиты клода"), "лимиты Claude")
        XCTAssertEqual(TermCanon.normalize("клоуд не отвечает"), "Claude не отвечает")
        XCTAssertEqual(TermCanon.normalize("сидим в клоде"), "сидим в Claude")
    }

    /// Замена в начале пункта не должна оставлять строчную букву там, где
    /// человек написал заглавную — иначе правило чинит термин и ломает фразу.
    func testЗаглавнаяБукваСохраняется() {
        XCTAssertEqual(TermCanon.normalize("Майплайн переписали"), "Пайплайн переписали")
        XCTAssertEqual(TermCanon.normalize("Анбординг занял неделю"), "Онбординг занял неделю")
    }

    /// Главный риск таблицы — обычное русское слово, начинающееся так же.
    /// «Инстанция» поэтому в таблицу не попала вовсе, а хвост длиннее падежного
    /// снимает замену: «клоунада» не имеет отношения к Claude.
    func testОбычныеСловаНеТрогаем() {
        XCTAssertEqual(TermCanon.normalize("суд первой инстанции"), "суд первой инстанции")
        XCTAssertEqual(TermCanon.normalize("клоунада какая-то"), "клоунада какая-то")
        XCTAssertEqual(TermCanon.normalize("бекон и яйца"), "бекон и яйца")
    }

    /// Конспект — это markdown, и правило работает по словам, а не по строкам:
    /// разметка, переносы и пунктуация обязаны дожить до файла в целости.
    func testРазметкаИПунктуацияНеПортятся() {
        let recap = """
        ## Решения
        - **Слава** — чинит майплайн, не трогая джабы.
        - Лимиты клода упёрлись в потолок (см. [12:45]).
        """
        XCTAssertEqual(TermCanon.normalize(recap), """
        ## Решения
        - **Слава** — чинит пайплайн, не трогая джобы.
        - Лимиты Claude упёрлись в потолок (см. [12:45]).
        """)
    }

    func testТекстБезТерминовНеМеняется() {
        let text = "Договорились: Пётр готовит смету к пятнице."
        XCTAssertEqual(TermCanon.normalize(text), text)
    }

    /// Найдено замером по конспектам, а не по расшифровкам: эти поломки рождаются
    /// уже после распознавания, и горячие слова до них не достают.
    func testПоломкиРодомИзКонспекта() {
        XCTAssertEqual(TermCanon.normalize("десять инстантов"), "десять инстансов")
        XCTAssertEqual(TermCanon.normalize("инстанты упали"), "инстансы упали")
        XCTAssertEqual(TermCanon.normalize("ритч-текст в карточке"), "рич-текст в карточке")
    }

    /// Storybook звучит четырьмя способами и ни разу своим: «стурибук» и
    /// «стрибук» в расшифровке, «стейтбук» — уже в конспекте, где модель
    /// подтянула знакомое слово «стейт».
    func testStorybookВЛюбомИзЧетырёхНаписаний() {
        for wrong in ["стейтбук", "стрибук", "стурибук", "сторибук"] {
            XCTAssertEqual(TermCanon.normalize("собрали в \(wrong)е"), "собрали в Storybook")
        }
        XCTAssertEqual(TermCanon.normalize("Стейтбук готов"), "Storybook готов")
    }

    /// Замер по 20 встречам августа: «лендос» в архиве не написан правильно ни
    /// разу — он приходит «лондосом» и «лундосом», и в конспект переезжает как
    /// услышан. Падежи чинятся той же одной строкой.
    func testПоломкиАвгустовскогоЗамера() {
        XCTAssertEqual(TermCanon.normalize("кейсы лондосов"), "кейсы лендосов")
        XCTAssertEqual(TermCanon.normalize("лундос сайт"), "лендос сайт")
        XCTAssertEqual(TermCanon.normalize("блок «реч-текст»"), "блок «рич-текст»")
        XCTAssertEqual(TermCanon.normalize("прислать мадборды"), "прислать мудборды")
        XCTAssertEqual(TermCanon.normalize("зовём на лок-шопы"), "зовём на воркшопы")
        XCTAssertEqual(TermCanon.normalize("гранулированные классеры"), "гранулированные кластеры")
        XCTAssertEqual(TermCanon.normalize("сториеллинг страницы"), "сторителлинг страницы")
        XCTAssertEqual(TermCanon.normalize("вейпкодил приложение"), "вайбкодил приложение")
        XCTAssertEqual(TermCanon.normalize("Лондосы Pragmatica"), "Лендосы Pragmatica")
    }

    /// Две поломки, где конспект придумал человека. «Медловский (мидл)» — это
    /// должность, услышанная как фамилия; «Бладос» — Владос, которого
    /// расшифровка пишет верно тринадцать раз из тринадцати.
    func testВыдуманныеЛюдиВозвращаютсяКСказанному() {
        XCTAssertEqual(TermCanon.normalize("Медловский присоединится"), "мидл присоединится")
        XCTAssertEqual(TermCanon.normalize("роль Медловского"), "роль мидл")
        XCTAssertEqual(TermCanon.normalize("Бладос доделает"), "Владос доделает")
        XCTAssertEqual(TermCanon.normalize("статус у бладоса"), "статус у владоса")
        // Соседние слова не задеты: «медленно» начинается так же на три буквы.
        XCTAssertEqual(TermCanon.normalize("медленно и медлил"), "медленно и медлил")
    }

    /// «Инстант-кофе» и «стрижка» под правило не попадают: одно короче основы,
    /// другое начинается иначе. Проверяем, что замена не расползлась.
    func testСоседниеСловаНеЗадеты() {
        XCTAssertEqual(TermCanon.normalize("стрижка ежиком"), "стрижка ежиком")
        XCTAssertEqual(TermCanon.normalize("рич-текст остаётся"), "рич-текст остаётся")
        XCTAssertEqual(TermCanon.normalize("классная работа"), "классная работа")
        XCTAssertEqual(TermCanon.normalize("речь про Лондон"), "речь про Лондон")
    }
}
