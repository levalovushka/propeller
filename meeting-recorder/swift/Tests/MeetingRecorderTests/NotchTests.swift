import XCTest
import PropellerPure

/// Чёлка: сколько места она занимает и на каком экране стоит.
///
/// Проверяется здесь, потому что глазами это проверить негде: у автора один
/// ноутбук из четырёх геометрий, а половина ошибок живёт на второй машине —
/// внешний монитор, закрытая крышка, масштабированное разрешение.
final class NotchGeometryTests: XCTestCase {

    /// Как это приходит из `NSScreen`: края экрана, свободные углы и
    /// `safeAreaInsets.top`. Ничего из этого мы не знаем заранее.
    private func screen(
        left: CGFloat = 0, width: CGFloat, top: CGFloat, safeTop: CGFloat, aux: CGFloat?
    ) -> NotchGeometry.Screen? {
        NotchGeometry.screen(
            left: left, width: width, top: top, safeAreaTop: safeTop,
            auxiliaryLeftWidth: aux, auxiliaryRightWidth: aux
        )
    }

    /// 14″ MacBook Pro в родном масштабе — 1512×982, вырез 185×32.
    private lazy var mbp14 = screen(width: 1512, top: 982, safeTop: 32, aux: 663.5)!
    /// 16″ — 1728×1117, вырез 220×38.
    private lazy var mbp16 = screen(width: 1728, top: 1117, safeTop: 38, aux: 754)!

    func testЧёлкаРастётТолькоВширь() {
        // Плита, свисающая под вырез, читается как выехавшая панель, а не как
        // раздавшаяся чёлка. Высота у обеих стадий одна.
        let open = NotchGeometry.frame(on: mbp14, stage: .open)
        let sealed = NotchGeometry.frame(on: mbp14, stage: .sealed)
        XCTAssertEqual(open.height, sealed.height)
        XCTAssertGreaterThan(open.width, sealed.width)
    }

    func testРаскрытаяЧёлкаЭтоВырезИДваКрыла() {
        let f = NotchGeometry.frame(on: mbp14, stage: .open)
        // Крыло считается, а не задаётся: скос по высоте выреза плюс кнопки.
        XCTAssertEqual(f.width, 185 + 2 * NotchGeometry.wingWidth(height: 32))
        XCTAssertEqual(f.width, 356, "185 выреза и два крыла по 85,5 — как в макете")
        XCTAssertEqual(f.groupInset, 21.5, "и пара стоит в 21,5 от внешнего края")
        XCTAssertEqual(f.height, 32, "чёлка растёт вширь, а не вниз: высота — её собственная")
        XCTAssertEqual(f.wingWidth, NotchGeometry.wingWidth(height: 32))
    }

    func testСвёрнутаяПлитаЭтоРовноВырез() {
        // Из неё плита вырастает при старте записи и в неё уходит на стопе:
        // рост начинается из железа, а не из точки посреди кромки.
        let f = NotchGeometry.frame(on: mbp14, stage: .sealed)
        XCTAssertEqual(f.width, 185)
        XCTAssertEqual(f.height, 32)
    }

    func testКнопкиНеЛезутПодКамеруНиНаОднойГеометрии() {
        for s in [mbp14, mbp16] {
            let f = NotchGeometry.frame(on: s, stage: .open)
            XCTAssertEqual(f.groupWidth, 64, "две кнопки 32, вплотную")
            XCTAssertGreaterThan(f.groupInset, 0, "снаружи от пары остаётся чернота крыла")
        }
    }

    func testФигураСтоитТамЖеГдеВырезАНеПоЦентруЭкрана() {
        for stage in [NotchGeometry.Stage.sealed, .open] {
            let f = NotchGeometry.frame(on: mbp16, stage: stage)
            XCTAssertEqual(f.originX + f.width / 2,
                           mbp16.notchLeft + mbp16.notchWidth / 2, accuracy: 0.001)
        }
    }

    func testВерхФигурыСовпадаетСВерхомЭкрана() {
        for stage in [NotchGeometry.Stage.sealed, .open] {
            let f = NotchGeometry.frame(on: mbp14, stage: stage)
            XCTAssertEqual(f.originY + f.height, 982, "стык с железом не даёт зазора")
        }
    }

    // MARK: - Экран, на котором она живёт

    func testПлитаОстаётсяНаСвоёмЭкранеАНеНаГлавном() {
        // Ноутбук стоит справа от внешнего монитора: его левый край — 1920.
        // Без этого края плита уезжала на главный монитор (замерено на живой
        // раскладке).
        let laptop = screen(left: 1920, width: 1512, top: 982, safeTop: 32, aux: 663.5)!
        let f = NotchGeometry.frame(on: laptop, stage: .open)
        XCTAssertTrue(f.fits(on: laptop))
        XCTAssertGreaterThan(f.originX, 1920)
    }

    func testУВырезаШиринаСчитаетсяПоСвободнымУглам() {
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
        // Замерено на живой машине (`notchprobe`, 2026-08-27): 14″ M-series,
        // панель 3024×1964, вырез 370×64 физических пикселя. В точках он
        // меняется вместе с выбранным разрешением — 370 × ширина_pt / 3024.
        // 16″ здесь **не замерен**, а посчитан по тому же правилу от 220×38 из
        // открытых замеров: своего 16-дюймового у нас нет.
        let cases: [(w: CGFloat, top: CGFloat, safeTop: CGFloat, aux: CGFloat, notch: CGFloat)] = [
            (1512, 982, 32, 663.5, 185),        // 14″, по умолчанию — замерено
            (1352, 878, 28.6, 593.3, 165.4),    // 14″, «Больше текста»
            (1280, 832, 27.1, 561.7, 156.6),    // 14″
            (1147, 745, 24.3, 503.3, 140.4),    // 14″, самое мелкое
            (1728, 1117, 38, 754, 220),         // 16″, по умолчанию — не замерено
        ]
        for c in cases {
            guard let s = screen(width: c.w, top: c.top, safeTop: c.safeTop, aux: c.aux) else {
                return XCTFail("вырез \(c.notch) не распознан")
            }
            XCTAssertEqual(s.notchWidth, c.notch, accuracy: 0.01)
            let f = NotchGeometry.frame(on: s, stage: .open)
            XCTAssertEqual(f.width, c.notch + 2 * NotchGeometry.wingWidth(height: c.safeTop),
                           accuracy: 0.01)
            XCTAssertEqual(f.wingWidth, NotchGeometry.wingWidth(height: c.safeTop), accuracy: 0.01)
            // С допуском: крыло выведено из этой же величины, и вычитание
            // возвращает её с точностью до последнего бита.
            XCTAssertGreaterThan(f.groupInset, 0)
            XCTAssertEqual(f.originY + f.height, c.top, "и всегда стоит на кромке")
        }
    }

    func testВырезСтоитНеПоЦентруЭкранаИПлитаЭтоЗнает() {
        // Замерено: свободные углы 665 слева и 662 справа, то есть вырез сдвинут
        // на полтора пункта вправо от середины экрана. Плита, поставленная по
        // центру экрана, разошлась бы с железом ровно на эти полтора пункта.
        let s = NotchGeometry.screen(
            left: 0, width: 1512, top: 982, safeAreaTop: 32,
            auxiliaryLeftWidth: 665, auxiliaryRightWidth: 662
        )!
        XCTAssertEqual(s.notchWidth, 185)
        let f = NotchGeometry.frame(on: s, stage: .open)
        XCTAssertEqual(f.originX + f.width / 2, 665 + 185 / 2, accuracy: 0.001)
        XCTAssertNotEqual(f.originX + f.width / 2, 1512 / 2)
    }

    func testУзкийВырезНеПринимаетсяЗаЧёлку() {
        // Ниже 120 pt вырезов не бывает; всё, что уже, — арифметика.
        XCTAssertNil(screen(width: 1512, top: 982, safeTop: 32, aux: 706))
    }
}
