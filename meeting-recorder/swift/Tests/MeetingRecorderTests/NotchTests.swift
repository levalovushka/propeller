import XCTest
import PropellerPure

/// Чёлка: сколько места она занимает и как ведёт себя лопасть.
///
/// Оба вопроса проверяются здесь, потому что глазами их проверить негде: у
/// автора один ноутбук из четырёх геометрий, а поведение лопасти в тишине
/// становится видно только через сорок минут встречи.
final class NotchGeometryTests: XCTestCase {

    /// Как это приходит из `NSScreen`: края экрана, свободные углы и
    /// `safeAreaInsets.top`. Ничего из этого мы не знаем заранее. `left` по
    /// умолчанию нулевой — это экран, который сейчас главный.
    private func screen(
        left: CGFloat = 0, width: CGFloat, top: CGFloat, safeTop: CGFloat,
        aux: CGFloat?, auxRight: CGFloat? = nil
    ) -> NotchGeometry.Screen? {
        NotchGeometry.screen(
            left: left, width: width, top: top, safeAreaTop: safeTop,
            auxiliaryLeftWidth: aux, auxiliaryRightWidth: auxRight ?? aux
        )
    }

    /// 14″ MacBook Pro в родном масштабе — 1512×982, вырез 185×32.
    private lazy var mbp14 = screen(width: 1512, top: 982, safeTop: 32, aux: 663.5)!
    /// 16″ — 1728×1117, вырез 220×38.
    private lazy var mbp16 = screen(width: 1728, top: 1117, safeTop: 38, aux: 754)!

    func testВПокоеЧёлкаОтрастаетНаДваУхаИНеСвисаетВниз() {
        let f = NotchGeometry.frame(on: mbp14, stage: .resting)
        XCTAssertEqual(f.width, 185 + 72 + 16, "тело, два уха и по галтели с краёв")
        XCTAssertEqual(f.height, 32, "в покое фигура ровно на высоту выреза")
        XCTAssertEqual(f.earWidth, 36)
    }

    func testСвёрнутаяПлитаЭтоРовноВырез() {
        // Ниже галтелей от неё остаётся ширина выреза — поэтому рост при старте
        // записи начинается из железа, а не из точки посреди кромки.
        let f = NotchGeometry.frame(on: mbp14, stage: .sealed)
        XCTAssertEqual(f.width - 2 * f.contentInset, 185)
        XCTAssertEqual(f.height, 32)
        XCTAssertEqual(f.earWidth, 0, "ушей ещё нет — значкам негде стоять")
    }

    func testУхоНеЗаезжаетНаГалтель() {
        // Первый снимок показал обрезанный значок заметки: у самой кромки
        // фигура шире, чем ниже, и содержимое в этот клин ставить нельзя.
        let f = NotchGeometry.frame(on: mbp14, stage: .resting)
        XCTAssertEqual(f.contentInset * 2 + f.earWidth * 2 + f.notchWidth, f.width)
    }

    func testФигураСтоитПоЦентруВырезаАНеЭкрана() {
        // Не «по центру экрана»: `NSScreen` на 14″ отдаёт свободные углы 665 и
        // 662 — вырез стоит на 1,5 pt правее середины, и фигура идёт за ним.
        // Замерено на встроенном экране 1512×982.
        let s = screen(width: 1512, top: 982, safeTop: 32, aux: 665, auxRight: 662)!
        let f = NotchGeometry.frame(on: s, stage: .resting)
        XCTAssertEqual(f.originX + f.width / 2, 665 + 185 / 2, accuracy: 0.001)
        XCTAssertNotEqual(f.originX + f.width / 2, 1512 / 2)
    }

    // MARK: - Мультимонитор

    /// Экран с вырезом лежит в нуле только пока он главный. Стоит сделать
    /// главным внешний монитор — и у встроенного появляется свой левый край,
    /// а рамка панели живёт в общих координатах рабочего стола, а не в
    /// координатах экрана.
    ///
    /// Так это и выглядело у первого же человека с докой: чёлка выросла на
    /// внешнем мониторе. Промах был ровно `-minX`.
    private let arrangements: [(name: String, left: CGFloat, top: CGFloat)] = [
        ("ноутбук главный", 0, 982),
        ("внешний главный, ноутбук справа", 2560, 0),
        ("внешний главный, ноутбук слева", -1512, 0),
        ("внешний главный сверху, ноутбук снизу по центру", 524, 0),
    ]

    func testНаЛюбойРаскладкеЭкрановФигураПопадаетВСвойВырез() {
        for a in arrangements {
            let s = screen(left: a.left, width: 1512, top: a.top, safeTop: 32,
                           aux: 665, auxRight: 662)!
            for stage in [NotchGeometry.Stage.sealed, .resting, .composing] {
                let f = NotchGeometry.frame(on: s, stage: stage)
                XCTAssertEqual(f.originX + f.width / 2,
                               a.left + 665 + 185 / 2, accuracy: 0.001,
                               "\(a.name), \(stage): фигура не по вырезу")
                XCTAssertEqual(f.originY + f.height, a.top, "\(a.name): не на кромке")
            }
        }
    }

    func testФигураНеВыходитЗаПределыЭкранаСВырезом() {
        // Промах здесь означал не «криво стоит», а «нет вовсе»: рамку за краями
        // всех экранов AppKit не подтягивает — панель остаётся невидимой, а
        // ⌃⌥N при этом продолжает брать клавиатуру.
        for a in arrangements {
            let s = screen(left: a.left, width: 1512, top: a.top, safeTop: 32,
                           aux: 665, auxRight: 662)!
            for stage in [NotchGeometry.Stage.sealed, .resting, .composing] {
                let f = NotchGeometry.frame(on: s, stage: stage)
                XCTAssertTrue(s.contains(f),
                              "\(a.name), \(stage): фигура на \(f.originX) — не на этом экране")
            }
        }
    }

    func testЛевыйКрайЭкранаНеМеняетНиРазмерНиВысоту() {
        // Раскладка переставляет фигуру, но не пересчитывает её: тот же вырез —
        // та же плита.
        let home = NotchGeometry.frame(on: screen(width: 1512, top: 982, safeTop: 32,
                                                 aux: 665, auxRight: 662)!, stage: .composing)
        let docked = NotchGeometry.frame(on: screen(left: 2560, width: 1512, top: 0,
                                                   safeTop: 32, aux: 665, auxRight: 662)!,
                                        stage: .composing)
        XCTAssertEqual(home.width, docked.width)
        XCTAssertEqual(home.height, docked.height)
        XCTAssertEqual(docked.originX - home.originX, 2560)
    }

    func testВерхФигурыСовпадаетСВерхомЭкрана() {
        for stage in [NotchGeometry.Stage.resting, .composing] {
            let f = NotchGeometry.frame(on: mbp14, stage: stage)
            XCTAssertEqual(f.originY + f.height, 982, "стык с железом не даёт зазора")
        }
    }

    func testЗаметкаОпускаетЧёлкуВнизИНеРаздаётЕёВширь() {
        let rest = NotchGeometry.frame(on: mbp14, stage: .resting)
        let compose = NotchGeometry.frame(on: mbp14, stage: .composing)
        XCTAssertEqual(compose.width, rest.width, "вширь чёлка не расходится вовсе")
        XCTAssertEqual(compose.originX, rest.originX, "и, значит, никуда не едет")
        XCTAssertEqual(compose.height, 96, "раскрытая чёлка 14″")
    }

    func testВРаскрытуюЧёлкуВмещаетсяРовноТриСтроки() {
        // Высота взята не числом: это три строки 13/16 и воздух над первой и
        // под последней. Поменяется кегль — поменяется и она, вместе.
        let lines = CGFloat(NotchGeometry.noteVisibleLines) * NotchGeometry.noteLineHeight
        XCTAssertEqual(
            NotchGeometry.composeDrop,
            lines + NotchGeometry.notePaddingTop + NotchGeometry.notePaddingBottom
        )
        XCTAssertEqual(NotchGeometry.noteVisibleLines, 3)
    }

    func testПодНабираемойСтрокойВоздухаБольшеЧемНадПервой() {
        // Снизу у плиты скругление, и оно съедает часть просвета: при равных
        // отступах строка, по которой идёт набор, выглядит прижатой к краю.
        XCTAssertGreaterThan(NotchGeometry.notePaddingBottom, NotchGeometry.notePaddingTop)
    }

    // MARK: - Есть ли вообще чёлка

    func testУВырезаШиринаСчитаетсяПоСвободнымУглам() {
        // 14″: два угла по 663.5 pt, между ними 185.
        let s = screen(width: 1512, top: 982, safeTop: 32, aux: 663.5)
        XCTAssertEqual(s?.notchWidth, 185)
        XCTAssertEqual(s?.notchHeight, 32)
    }

    func testНаЭкранеБезВырезаЧёлкиНетВовсе() {
        // Внешний монитор, iMac, Air M1: `safeAreaInsets.top` нулевой.
        XCTAssertNil(screen(width: 1920, top: 1080, safeTop: 0, aux: 960))
    }

    func testБезСвободныхУгловЧёлкиНет() {
        // На экране без выреза AppKit не отдаёт `auxiliaryTop*Area` вовсе.
        // Подставлять полэкрана вместо них нельзя: получится вырез шириной ноль
        // на машине, где его нет.
        XCTAssertNil(NotchGeometry.screen(
            left: 0, width: 1920, top: 1080, safeAreaTop: 32,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        ))
    }

    func testПогрешностьВПолпиксаНеСтановитсяВырезом() {
        XCTAssertNil(
            NotchGeometry.screen(left: 0, width: 1920, top: 1080, safeAreaTop: 24,
                                 auxiliaryLeftWidth: 960, auxiliaryRightWidth: 959.5),
            "экран без чёлки не должен отрастить вырез в полпикселя"
        )
    }

    // MARK: - Вырезы бывают разные

    func testРазмерыСчитаютсяИзЭкранаАНеИзКонстант() {
        // 14″, 16″ и масштабированное разрешение «Больше места», где тот же
        // вырез приходит другими числами. Ни одно из них мы не знаем заранее.
        let cases: [(w: CGFloat, top: CGFloat, safeTop: CGFloat, aux: CGFloat, notch: CGFloat)] = [
            (1512, 982, 32, 663.5, 185),     // 14″ по умолчанию
            (1728, 1117, 38, 754, 220),      // 16″ по умолчанию
            (1800, 1169, 38, 790, 220),      // 16″, «Больше места»
            (1710, 1107, 29, 762.5, 185),    // 14″, «Больше места»
        ]
        for c in cases {
            guard let s = screen(width: c.w, top: c.top, safeTop: c.safeTop, aux: c.aux) else {
                return XCTFail("вырез \(c.notch) не распознан")
            }
            XCTAssertEqual(s.notchWidth, c.notch)
            let f = NotchGeometry.frame(on: s, stage: .resting)
            XCTAssertEqual(f.width, c.notch + 72 + 16)
            XCTAssertEqual(f.height, c.safeTop, "плита ровно по высоте выреза")
            XCTAssertEqual(f.earWidth, 36, "ухо не зависит от того, какой ноутбук")
            XCTAssertEqual(f.originY + f.height, c.top, "и всегда стоит на кромке")
        }
    }

    func testУзкийВырезНеПринимаетсяЗаЧёлку() {
        // Ниже 120 pt вырезов не бывает; всё, что уже, — арифметика.
        XCTAssertNil(screen(width: 1512, top: 982, safeTop: 32, aux: 706))
    }
}

/// Лопасть: чем она питается и что означает её остановка.
final class BladeDriveTests: XCTestCase {

    // MARK: - Огибающая: чем лопасть питается на самом деле

    /// Как громкая речь выглядит в захвате: пик за буфер, приходящий раз в
    /// ~50 мс, где слог даёт 0.8, а пауза между словами — почти ноль.
    private func syllables(seconds: Double, tick: Double = 0.05) -> [Float] {
        stride(from: 0.0, to: seconds, by: tick).map { t in
            Int(t / tick) % 3 == 0 ? 0.8 : 0.03
        }
    }

    func testМеждуСловамиОгибающаяНеПроваливается() {
        var envelope: Float = 0
        for level in syllables(seconds: 2) {
            envelope = BladeDrive.envelope(envelope, level: level, dt: 0.05)
        }
        XCTAssertGreaterThan(envelope, 0.3, "пауза между слогами — не тишина")
    }

    func testПослеРепликиОгибающаяВсёЖеОпускается() {
        var envelope: Float = 0.8
        func hold(seconds: Double) {
            for _ in 0..<Int(seconds / 0.05) {
                envelope = BladeDrive.envelope(envelope, level: 0, dt: 0.05)
            }
        }
        // Пауза в разговоре — не тишина: за две секунды лопасть сбрасывает
        // мощность, но не встаёт на холостой ход.
        hold(seconds: 2)
        XCTAssertLessThan(envelope, 0.1)
        XCTAssertGreaterThan(envelope, BladeDrive.floorLevel)
        // А комната, замолчавшая совсем, доводит её до холостого хода.
        hold(seconds: 2)
        XCTAssertLessThan(envelope, BladeDrive.floorLevel)
    }

    func testНаГромкойРечиХодЛопастиРовный() {
        // Тот самый дефект: пик за буфер скачет, привод тянет вверх втрое
        // быстрее, чем отпускает, — и на слогах это работало храповиком.
        // Замерено на этой модели: 13,1 % размаха напрямую по пикам против
        // 4,7 % через огибающую, то есть пульсация втрое меньше.
        XCTAssertLessThan(ripple(throughEnvelope: true), 0.06)
        XCTAssertGreaterThan(ripple(throughEnvelope: false), 0.10)
    }

    /// Размах колебаний скорости на установившейся речи, долей от полного
    /// диапазона лопасти.
    ///
    /// Модель повторяет то, что происходит на самом деле: лопасть считается
    /// каждый кадр (60 Гц), а уровень приходит редко — пик за буфер, который
    /// между отсчётами держится неизменным.
    private func ripple(throughEnvelope: Bool, levelPeriod: Double = 0.15) -> Double {
        let dt = 1.0 / 60
        var envelope: Float = 0, speed = BladeDrive.idleSpeed
        var settled: [Double] = []
        var held: Float = 0
        var t = 0.0, nextSample = 0.0
        while t < 6 {
            if t >= nextSample {
                // Слог даёт пик под 0.8, пауза между словами — почти ноль.
                held = Int(t / 0.25) % 2 == 0 ? 0.8 : 0.03
                nextSample += levelPeriod
            }
            envelope = BladeDrive.envelope(envelope, level: held, dt: dt)
            speed = BladeDrive.advance(
                speed: speed, level: throughEnvelope ? envelope : held,
                paused: false, dt: dt
            )
            // Первые три секунды — разгон, он и должен быть заметным.
            if t > 3 { settled.append(speed) }
            t += dt
        }
        return (settled.max()! - settled.min()!).magnitude
            / abs(BladeDrive.topSpeed - BladeDrive.idleSpeed)
    }

    func testОгибающаяПодхватываетНачалоФразыБыстро() {
        var envelope: Float = 0
        for _ in 0..<4 { envelope = BladeDrive.envelope(envelope, level: 0.6, dt: 0.05) }
        XCTAssertGreaterThan(envelope, 0.4, "0,2 с — и лопасть уже пошла")
    }

    func testВТишинеЛопастьИдётХолостымХодомАНеВстаёт() {
        let target = BladeDrive.targetSpeed(level: 0, paused: false)
        XCTAssertEqual(target, BladeDrive.idleSpeed)
        XCTAssertNotEqual(target, 0, "остановка в тишине читалась бы как поломка")
    }

    func testНольЭтоТолькоПауза() {
        XCTAssertEqual(BladeDrive.targetSpeed(level: 0.4, paused: true), 0)
        XCTAssertEqual(BladeDrive.targetSpeed(level: 0, paused: true), 0)
    }

    func testГромкийРазговорДаётПолнуюМощность() {
        XCTAssertEqual(BladeDrive.targetSpeed(level: 0.8, paused: false), BladeDrive.topSpeed)
    }

    func testМощностьРастётВместеСУровнем() {
        var previous = -1.0
        for level in stride(from: Float(0), through: 1, by: 0.05) {
            let power = BladeDrive.power(level: level)
            XCTAssertGreaterThanOrEqual(power, previous)
            XCTAssertTrue((0...1).contains(power))
            previous = power
        }
    }

    func testОбычнаяРечьЖивётВСерединеШкалыАНеУПола() {
        // Пик 0.1 — разговорная громкость в метре от микрофона.
        let power = BladeDrive.power(level: 0.1)
        XCTAssertGreaterThan(power, 0.4, "на линейной шкале здесь было бы 0.1")
        XCTAssertLessThan(power, 0.8)
    }

    func testМощностьПриходитЗаСекундуАУходитВтроеДольше() {
        // Приход: 63 % пути за `attack`.
        let started = BladeDrive.advance(speed: BladeDrive.idleSpeed, level: 0.8,
                                         paused: false, dt: BladeDrive.attack)
        let full = BladeDrive.topSpeed - BladeDrive.idleSpeed
        XCTAssertEqual(started, BladeDrive.idleSpeed + full * 0.632, accuracy: 1)

        // Уход: за то же время лопасть теряет заметно меньше.
        let coasting = BladeDrive.advance(speed: BladeDrive.topSpeed, level: 0,
                                          paused: false, dt: BladeDrive.attack)
        XCTAssertLessThan(abs(coasting - BladeDrive.topSpeed), abs(started - BladeDrive.idleSpeed))
    }

    func testЛопастьНеПерескакиваетЦельНаДлинномКадре() {
        let speed = BladeDrive.advance(speed: BladeDrive.idleSpeed, level: 1,
                                       paused: false, dt: 10)
        XCTAssertGreaterThanOrEqual(speed, BladeDrive.topSpeed)
        XCTAssertLessThanOrEqual(speed, BladeDrive.idleSpeed)
    }

    func testПаузаОстанавливаетЛопастьСовсем() {
        var speed = BladeDrive.topSpeed
        for _ in 0..<120 { speed = BladeDrive.advance(speed: speed, level: 0.5,
                                                      paused: true, dt: 1.0 / 60) }
        XCTAssertEqual(speed, 0, "не «почти ноль»: медленный дрейф означает идущую запись")
    }

    func testПаузаДочитываетсяЗаСекунду() {
        var speed = BladeDrive.topSpeed
        for _ in 0..<60 { speed = BladeDrive.advance(speed: speed, level: 0.5,
                                                     paused: true, dt: 1.0 / 60) }
        XCTAssertEqual(speed, 0)
    }

    func testДлительностьКадраНеМеняетИсход() {
        // Тот же результат за секунду, набранную шестьюдесятью кадрами и шестью.
        var fast = BladeDrive.idleSpeed, slow = BladeDrive.idleSpeed
        for _ in 0..<60 { fast = BladeDrive.advance(speed: fast, level: 0.3,
                                                    paused: false, dt: 1.0 / 60) }
        for _ in 0..<6 { slow = BladeDrive.advance(speed: slow, level: 0.3,
                                                   paused: false, dt: 1.0 / 6) }
        XCTAssertEqual(fast, slow, accuracy: 1)
    }
}
