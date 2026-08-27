import SwiftUI
import AppKit
import CoreText

/// Propeller design tokens — three-tier alias chain (rntl / ArtIntel logic):
/// **Primitive → Token → Semantic**. Components consume **Semantic** (and Space /
/// Radius). Off-scale literals snap to the nearest step instead of inventing new ones.
///
/// Typography stays SF Pro (macOS-native). System Settings / alerts are out of scope.
///
/// # Two themes, one call site
///
/// Every semantic colour is a *pair* — one value for dark, one for light —
/// resolved by AppKit at draw time (`Tokens.dual`). A view never asks which
/// theme is on, and there is no second set of components for light mode. The
/// dark values are the ones drawn in Figma; the light ones are derived by the
/// rule in `Primitive.ink` and are the only place to touch when the light
/// design lands.
public enum Tokens {

    // MARK: - 0. Scheme

    /// A colour with two values, one per appearance.
    ///
    /// Resolution happens inside AppKit, so a `Tokens.Paint.*` constant can stay
    /// a plain `Color` and every existing call site keeps working — switching
    /// the app to light mode changes no view code at all.
    public static func dual(dark: NSColor, light: NSColor) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: dualNSColor(dark: dark, light: light))
    }

    /// `dual` for the places that need AppKit (window backgrounds, glass tint).
    public static func dualNSColor(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - 1. Primitives

    public enum Primitive {
        public enum AlphaWhite {
            public static let a0: Double = 0
            public static let a3: Double = 0.03
            public static let a5: Double = 0.05
            public static let a7: Double = 0.07
            public static let a10: Double = 0.10
            public static let a12: Double = 0.12
            public static let a15: Double = 0.15
            public static let a20: Double = 0.20
            public static let a30: Double = 0.30
            public static let a40: Double = 0.40 // snap for legacy 0.40 UI chrome
            public static let a50: Double = 0.50
            public static let a55: Double = 0.55
            public static let a70: Double = 0.70
            public static let a75: Double = 0.75
            /// The redesign's one loud ink: `rgba(255,255,255,0.9)` on nav
            /// labels and meeting titles alike (Figma 308:8446).
            public static let a90: Double = 0.90
            public static let a95: Double = 0.95
            public static let a100: Double = 1.0

            public static func color(_ a: Double) -> SwiftUI.Color { SwiftUI.Color.white.opacity(a) }
            public static func nsColor(_ a: Double) -> NSColor {
                NSColor(calibratedWhite: 1, alpha: a)
            }
        }

        public enum AlphaBlack {
            public static let a0: Double = 0
            public static let a3: Double = 0.03
            public static let a5: Double = 0.05
            public static let a6: Double = 0.06
            public static let a7: Double = 0.07
            public static let a8: Double = 0.08
            public static let a9: Double = 0.09
            public static let a10: Double = 0.10
            public static let a12: Double = 0.12
            public static let a15: Double = 0.15
            public static let a28: Double = 0.28
            public static let a30: Double = 0.30
            public static let a42: Double = 0.42
            public static let a48: Double = 0.48
            public static let a50: Double = 0.50
            public static let a55: Double = 0.55
            public static let a58: Double = 0.58
            public static let a60: Double = 0.60 // скрим модалки (298:26274)
            public static let a68: Double = 0.68
            public static let a70: Double = 0.70
            public static let a80: Double = 0.80 // glass wash
            /// Light twin of `AlphaWhite.a90` — a shade less, per the note on
            /// `Primitive.ink`: black at the loud end outweighs white.
            public static let a88: Double = 0.88
            public static let a92: Double = 0.92
            public static let a95: Double = 0.95
            public static let a100: Double = 1.0

            public static func color(_ a: Double) -> SwiftUI.Color { SwiftUI.Color.black.opacity(a) }
            public static func nsColor(_ a: Double) -> NSColor {
                NSColor(calibratedWhite: 0, alpha: a)
            }
        }

        /// Near-black used under glass (#0A0A0A).
        public static let inkWashWhite: CGFloat = 10.0 / 255.0
        /// Its light-theme twin (#F5F5F5).
        public static let inkWashWhiteLight: CGFloat = 245.0 / 255.0

        /// An ink pair: white over dark, black over light.
        ///
        /// The two alphas are rarely equal. Black at 30 % on a near-white rail
        /// reads fainter than white at 30 % on a near-black one — the eye is not
        /// symmetric about mid-grey — so the quiet end of the light ramp carries
        /// more alpha than its dark counterpart. The loud end carries slightly
        /// less: black at 95 % is heavier than white at 95 %.
        public static func ink(dark: Double, light: Double) -> SwiftUI.Color {
            Tokens.dual(dark: AlphaWhite.nsColor(dark), light: AlphaBlack.nsColor(light))
        }

        /// The same pair for the places that draw through AppKit — a text
        /// storage takes `NSColor`, and going through `Color` there loses the
        /// appearance-resolving closure that makes the pair a pair.
        public static func inkNSColor(dark: Double, light: Double) -> NSColor {
            Tokens.dualNSColor(dark: AlphaWhite.nsColor(dark), light: AlphaBlack.nsColor(light))
        }

        /// A solid pair given as **sRGB** whites (0…1) — i.e. as hex.
        ///
        /// `surface` below takes *calibrated* white, whose gamma is not sRGB's:
        /// #212121 asked for that way draws as #2C2C2C, a fifth lighter than the
        /// comp. It never showed up because every existing surface is 0 or 1,
        /// where the two spaces agree. A value read off Figma is a hex, so it is
        /// stated in the space hexes are written in.
        public static func surfaceSRGB(dark: CGFloat, light: CGFloat, alpha: CGFloat = 1) -> SwiftUI.Color {
            Tokens.dual(
                dark: NSColor(srgbRed: dark, green: dark, blue: dark, alpha: alpha),
                light: NSColor(srgbRed: light, green: light, blue: light, alpha: alpha)
            )
        }

        /// A solid pair given as calibrated whites (0…1).
        public static func surface(dark: CGFloat, light: CGFloat, alpha: CGFloat = 1) -> SwiftUI.Color {
            Tokens.dual(
                dark: NSColor(calibratedWhite: dark, alpha: alpha),
                light: NSColor(calibratedWhite: light, alpha: alpha)
            )
        }
    }

    // MARK: - 2. Tokens (aliases over primitives)

    public enum Neutral {
        public static let aw7 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a7)
        public static let aw10 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a10)
        public static let aw12 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a12)
        public static let aw15 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a15)
        public static let aw20 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a20)
        public static let aw30 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a30)
        public static let aw40 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a40)
        public static let aw50 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a50)
        public static let aw70 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a70)
        public static let aw95 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a95)
        public static let white = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a100)

        public static let ab7 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a7)
        public static let ab15 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a15)
        public static let ab30 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a30)
        public static let ab70 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a70)
        public static let ab95 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a95)
        public static let black = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a100)
    }

    // MARK: - 3. Semantic (what components use)

    /// Each constant is a dark/light pair. Dark is what Figma draws; light is
    /// derived (see `Primitive.ink`) and is the single place to revise when the
    /// light comps arrive.
    public enum Paint {
        public enum Bg {
            public static let page = Primitive.surface(dark: 0, light: 1)
            public static let surface = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                      light: Primitive.AlphaBlack.a6)
            public static let selected = Primitive.ink(dark: Primitive.AlphaWhite.a12,
                                                       light: Primitive.AlphaBlack.a10)
            /// Scrim under sheets. Light needs far less of it — the sheet already
            /// separates itself by being brighter than the page.
            public static let overlay = Tokens.dual(
                dark: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a70),
                light: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a30)
            )
            public static let inverted = Primitive.surface(dark: 1, light: 0)
            /// `#0A0A0A @ 80%` wash over `.thickMaterial` (light: `#F5F5F5 @ 80%`).
            public static var glassWash: NSColor {
                Tokens.dualNSColor(
                    dark: NSColor(calibratedWhite: Primitive.inkWashWhite, alpha: Primitive.AlphaBlack.a80),
                    light: NSColor(calibratedWhite: Primitive.inkWashWhiteLight, alpha: Primitive.AlphaBlack.a80)
                )
            }
        }

        public enum Text {
            public static let primary = Primitive.ink(dark: Primitive.AlphaWhite.a95,
                                                      light: Primitive.AlphaBlack.a92)
            public static let secondary = Primitive.ink(dark: Primitive.AlphaWhite.a70,
                                                        light: Primitive.AlphaBlack.a68)
            public static let tertiary = Primitive.ink(dark: Primitive.AlphaWhite.a30,
                                                       light: Primitive.AlphaBlack.a42)
            public static let quaternary = Primitive.ink(dark: Primitive.AlphaWhite.a40,
                                                         light: Primitive.AlphaBlack.a50)
            public static let disabled = Primitive.ink(dark: Primitive.AlphaWhite.a20,
                                                       light: Primitive.AlphaBlack.a28)
            /// Ink *on* an inverted fill — flips with the theme like everything else.
            public static let primaryInverse = Tokens.dual(
                dark: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a95),
                light: Primitive.AlphaWhite.nsColor(Primitive.AlphaWhite.a95)
            )
            public static let secondaryInverse = Tokens.dual(
                dark: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a70),
                light: Primitive.AlphaWhite.nsColor(Primitive.AlphaWhite.a70)
            )
        }

        public enum Interactive {
            public enum Primary {
                public static let rest = Text.primary
                public static let hover = Primitive.surface(dark: 1, light: 0)
                public static let disabled = Bg.surface
            }
            public enum Secondary {
                public static let rest = Bg.surface
                public static let hover = Bg.selected
                public static let active = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                         light: Primitive.AlphaBlack.a8)
                public static let disabled = Bg.surface
            }
            public enum Ghost {
                public static let rest = SwiftUI.Color.clear
                public static let hover = Bg.surface
                public static let active = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                         light: Primitive.AlphaBlack.a8)
                public static let disabled = SwiftUI.Color.clear
            }
            /// No fill ever — content only brightens (Propeller-specific).
            public enum Minimal {
                public static let rest = Text.tertiary
                public static let hover = Text.secondary
                public static let disabled = Text.disabled
            }
        }

        public enum Status {
            /// System reds/oranges already carry their own light/dark values.
            public static let record = SwiftUI.Color(nsColor: .systemRed)
            public static let warning = SwiftUI.Color(nsColor: .systemOrange)
            public static let accent = SwiftUI.Color.accentColor
            /// The one red that is a *choice*, not a recording light: «Очистить»
            /// (Figma 284:16769, `#FF4B59`). Stated as sRGB because it was read
            /// off a hex; the light twin is a step darker so it survives white.
            public static let destructive = Tokens.dual(
                dark: NSColor(srgbRed: 1.0, green: 0.294, blue: 0.349, alpha: 1),
                light: NSColor(srgbRed: 0.839, green: 0.157, blue: 0.216, alpha: 1)
            )
        }
    }

    // MARK: - 4. Radiuses

    /// The whole scale sits 4 pt tighter than the Figma comps: the corners there
    /// were drawn against a 48 pt window header and read as too soft once the
    /// same shapes carry 12 pt rows. `none` and `full` are not on the scale —
    /// one is a square corner, the other a pill — so neither moves.
    public enum Radius {
        public static let none: CGFloat = 0
        public static let xxxxs: CGFloat = 2
        public static let xxxs: CGFloat = 4
        public static let xxs: CGFloat = 6
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 10
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 26
        public static let x2l: CGFloat = 34
        public static let x3l: CGFloat = 42
        public static let full: CGFloat = 9999
    }

    // MARK: - 5. Spaces

    public enum Space {
        public static let s2: CGFloat = 2
        public static let s4: CGFloat = 4
        public static let s6: CGFloat = 6
        public static let s8: CGFloat = 8
        public static let s10: CGFloat = 10
        public static let s12: CGFloat = 12
        public static let s16: CGFloat = 16
        public static let s20: CGFloat = 20
        public static let s24: CGFloat = 24
        /// Between 24 and 32 — added for the setup plate, whose two silences
        /// around the permission list the comps draw at 28 (Figma 130:2165).
        public static let s28: CGFloat = 28
        public static let s32: CGFloat = 32
        public static let s40: CGFloat = 40
        public static let s48: CGFloat = 48
        public static let s64: CGFloat = 64
    }

    // MARK: - 6. Motion

    public enum Motion {
        /// Лестница длительностей — то же, чем `Space` служит отступам.
        ///
        /// До неё в приложении жило четырнадцать длительностей, часть из которых
        /// различима только на бумаге (0.08 против 0.09, 0.12 против 0.13).
        /// Семь ступеней с шагом примерно ×1.4: соседние читаются как разные,
        /// а промежуток между ними нечем занять. Имя — миллисекунды, потому что
        /// про движение думают в них, а не в долях секунды.
        ///
        /// Всё, что длится, снапится к ступени. Исключения — не вкус, а другая
        /// природа: пружины чёлки (там ручка — отклик, а не время), развёртка
        /// шиммера (бесконечный цикл) и печатная машинка (время от числа
        /// символов).
        public enum Step {
            /// Отклик на нажатие. Ниже порога, за которым палец чувствует лаг.
            public static let t60: Double = 0.06
            /// Уход мелкого: панель действий, подмена того, про кого панель.
            public static let t90: Double = 0.09
            /// Ховер и приход мелкого. Рабочая ступень всего приложения.
            public static let t120: Double = 0.12
            /// Шаг: уход содержимого, кнопка на месте колонки, рельс.
            public static let t180: Double = 0.18
            /// Приход содержимого и переукладка списка — там, где есть что
            /// прочитать в новом положении.
            public static let t240: Double = 0.24
            /// Верхняя ступень для интерфейса. Сейчас на ней ничего не стоит:
            /// её занимала поездка окна за колонкой заметок, а колонки больше
            /// нет. Оставлена лестнице, а не выкинута, — ступень между 240 и
            /// пеплом нужна ровно тогда, когда снова понадобится двигать корпус.
            public static let t320: Double = 0.32
            /// Пепел. Раз за встречу и по своей физике — см. `Ash`.
            public static let t550: Double = 0.55
        }

        /// # Кривая
        ///
        /// Приходит и уходит — `easeOut`. Едет по экрану — `easeInOut`. Крутится
        /// без конца — `linear`. `easeIn` не бывает нигде: он начинается с нуля
        /// скорости, а всё, что здесь движется, начинается от действия человека
        /// и обязано тронуться в тот же кадр.
        ///
        /// Уход тоже `easeOut`, и это не оговорка. Уход у нас — освобождение
        /// места для того, что придёт следом (см. `Pane.columnSwapOut`), и место
        /// должно освободиться сразу, а не после паузы на разгон.
        ///
        /// # Что не анимируется
        ///
        /// То, что делают сотни раз в день, и то, что вызвано клавишей: клавишу
        /// стучат быстрее, чем идёт ход, и анимация превращается в отставание.
        /// Поэтому у выбора встречи в рельсе нет ни просадки под нажатием
        /// (`PressStyle` — только на мишенях-действиях), ни хода.
        ///
        /// Исключение ровно одно и названо здесь, чтобы его не приняли за
        /// недосмотр: шаг ⌥Tab (`Pane.Switcher.step`). Панель за секунду жизни
        /// обязана показать, откуда и куда идёшь, а это читается только связным
        /// движением списка — см. шапку `MeetingSwitcherPanel`.
        public static let hover = Step.t120
        /// Кнопка проседает под курсором и отпускает.
        ///
        /// Нажатие короче отпускания: палец уже знает, что нажал, и ждать
        /// подтверждения ему незачем, — а вот возврат в покой на той же
        /// скорости читается как отскок.
        public static let press = Step.t60
        public static let release = Step.t120
        /// Насколько кнопка проседает под нажатием.
        ///
        /// Четыре процента. На мишени в 32 pt это чуть больше пункта — меньше
        /// не видно вовсе, больше читается как кнопка, которая проваливается.
        /// Масштаб, а не заливка: заливкой у нас говорит наведение, и второй
        /// разговор в том же месте про то же самое ничего не добавляет.
        public static let pressScale: CGFloat = 0.96
        /// Рельс уходит за левый край и приходит обратно.
        public static let sidebarToggle = Step.t180
        /// Вопрос, пришвартованный к низу рельса.
        public static let promptDock = Step.t240
        /// List insert/remove reflow when ash is not driving the slot.
        public static let listReflow = Step.t240
        /// Legacy alias.
        public static let listDissolve: Double = listReflow

        /// Удаление встречи из рельса: строка осыпается пеплом, слот под ней
        /// закрывается. Все ручки — здесь и только здесь; ни в шейдере, ни в
        /// `AshRenderer` не осталось числа, которое стоило бы крутить.
        ///
        /// Модель — частицы, не фильтр: строка один раз растрируется в текстуру,
        /// на каждую клетку рождается квад, который несёт *свой* кусок этой
        /// текстуры. Летят они по настоящей физике (скорость + гравитация,
        /// интегрируется по реальному Δt), а не по формуле от прогресса.
        public enum Ash {
            /// Общий такт. Всё кончается вместе — но не всё вместе начинается,
            /// см. `settleDelay`.
            public static let duration = Step.t550

            /// Дата над строкой не уезжает, а растворяется — вместе с буквами,
            /// которые уносит пеплом.
            ///
            /// У неё исчезает повод существовать, а не место: заголовок дня — это
            /// утверждение «ниже встречи такого-то числа», и в момент, когда
            /// последняя из них горит, утверждение перестаёт быть верным. Поэтому
            /// `easeOut` и коротко, как всякий уход, — а высота её блока едет
            /// отдельно и позже, вместе с остальной раскладкой.
            public static let inkFade = Step.t180

            /// Насколько позже пепла трогается раскладка.
            ///
            /// Крошечно, и в этом весь смысл: пепел и дата обязаны начаться в кадр
            /// нажатия — это ответ на действие. А смыкание — уже следствие, и
            /// одновременный старт превращает три события в одно мутное. Ступень
            /// задержки даёт им порядок: сначала исчезло, потом сомкнулось.
            public static let settleDelay = Step.t60

            /// Сколько едет высота — остаток такта после задержки, чтобы пепел,
            /// дата и слот кончились в один кадр.
            public static var settle: Double { duration - settleDelay }

            /// Сторона частицы в pt. 1 — одна частица на точку строки: строка
            /// 272×40 даёт ~10 900 квадов, и это один draw call. Больше значение
            /// — крупнее зерно и меньше частиц (2 → вчетверо меньше).
            public static let cellSize: CGFloat = 1

            /// Стартовая скорость разлёта, pt/с. Направление у каждой частицы
            /// своё, случайное по всему кругу — строка осыпается, а не сдувается
            /// в одну сторону. Направленность даёт `gravity`, а не старт.
            public static let speedMin: CGFloat = 30
            public static let speedMax: CGFloat = 90
            /// Притяжение, pt/с². Плюс — вниз. Оно и загибает пух в падение;
            /// 0 оставит ровное облако во все стороны.
            public static let gravity: CGFloat = 260

            /// Сколько живёт частица, в долях такта. Разброс обязателен: без
            /// него поле гаснет одной плитой.
            ///
            /// **Бюджет: `waveDuration + lifetimeMax` ≤ 1.** Частица начинает
            /// гореть только когда до неё дошла волна, так что крайней правой
            /// остаётся ровно `1 − waveDuration` такта на всю свою жизнь. При
            /// 0.8 + 1.0 на экране в момент схлопывания слота оставалась четверть
            /// пепла — измерено оффскрином, 118 альфы из 448.
            public static let lifetimeMin: CGFloat = 0.3
            public static let lifetimeMax: CGFloat = 0.5
            /// Хвост угасания в долях такта. Частица держит полную непрозрачность
            /// почти всю жизнь и гаснет только на этом хвосте.
            public static let fadeTail: CGFloat = 0.3

            /// Ширина фронта волны в долях ширины строки. Волна едет слева
            /// направо; перед ней частица **заморожена**, а не невидима.
            public static let waveWindow: CGFloat = 0.8
            /// За какую долю такта волна проходит строку насквозь.
            /// Связана с `lifetimeMax` бюджетом выше.
            public static let waveDuration: CGFloat = 0.45

            /// Запас холста вокруг строки, pt. Не вкус, а физика: ровно то, что
            /// успевает пролететь самая быстрая и самая живучая частица —
            /// `v·t + g·t²/2`. Отдельной ручкой быть не должен, иначе разъедется
            /// с разлётом и хлопья начнёт срезать краем.
            public static var headroom: CGFloat {
                let t = lifetimeMax * CGFloat(duration)
                return max(8, speedMax * t + gravity * t * t / 2)
            }
        }
    }

    // MARK: - Layout semantics (roles → Space / Radius)

    public enum Glass {
        public static var fill: NSColor { Paint.Bg.glassWash }
        public static var fillWhite: CGFloat { Primitive.inkWashWhite }
        public static var fillAlpha: CGFloat { Primitive.AlphaBlack.a80 }
        public static var tint: NSColor { fill }

        /// Подкрас вызванного инструмента — панели действий, переключателя
        /// встреч, плашки заметки (`SummonedPlate`).
        ///
        /// **Светлее всего остального в окне**, и это единственное, чем такой
        /// инструмент отличается от плиты. Окно подкрашивает своё стекло почти
        /// чёрным (`glassWash`): оно фон, ему положено уходить. Инструменту
        /// положено обратное — он поднят над текстом и держится, пока держат
        /// позвавший его жест, поэтому темнеть вместе с фоном ему нельзя: тёмная
        /// плита над тёмной колонкой читается как дырка в ней, а не как
        /// предмет над ней.
        public static var summonedFill: NSColor {
            Tokens.dualNSColor(
                dark: NSColor(calibratedWhite: 1, alpha: Primitive.AlphaWhite.a7),
                light: NSColor(calibratedWhite: 1, alpha: Primitive.AlphaBlack.a58)
            )
        }
        /// Материал под этим подкрасом — самый толстый, какой есть
        /// (`.ultraThickMaterial` в `SummonedPlate`).
        ///
        /// Инструмент поднят над текстом, и текст под ним обязан **уйти**, а не
        /// просвечивать: буквы, читаемые сквозь плиту, спорят с буквами на ней.
        /// Толщина делает ровно это и заодно позволяет держать сам подкрас тихим
        /// — светлее фона, но не белым пятном. Подобрана она выкрасками так,
        /// чтобы цвет плиты не поехал: на плоском фоне `ultraThick` и `thick`
        /// различаются на глаз почти ничем, а сквозь них видно по-разному.
        public static var summonedTint: NSColor { summonedFill }
    }

    public enum Window {
        public static let contentWidth: CGFloat = 640
        /// Narrowest the content pane may get. The rail adds its own 300 on top
        /// — the window minimum is the sum, derived rather than restated.
        public static let contentPaneMinWidth: CGFloat = 480
        /// Opening pane width. Wider than Figma `thin` (601) so the summary
        /// reads comfortably from the first launch. ~920 window with the rail.
        public static let defaultPaneWidth: CGFloat = 620
        public static let chromePadding: CGFloat = Space.s12
        public static let trafficLightSlotWidth: CGFloat = 76

        /// Смена того, **чем окно является**: приглашение записать первую встречу
        /// уходит, колонки приходят. Те же две ступени, что у подмены содержимого
        /// колонки (`Pane.columnSwapOut` / `columnSwapIn`), и по той же причине —
        /// по очереди, а не крест-накрест, уход короче прихода.
        ///
        /// Своя пара имён, а не переиспользованная панельная: панельные числа
        /// правят, думая про колонку, и однажды поправят — а здесь меняется всё
        /// окно, и это решение принимается отдельно от того.
        public static let swapOut = Motion.Step.t180
        public static let swapIn = Motion.Step.t240

        /// Where the rail toggle sits, measured from the window's top-left — and
        /// it sits there whatever the rail is doing.
        ///
        /// The button used to be drawn twice: once inside the rail's header and
        /// once in the pane's, eight points further along, so putting the rail away
        /// slid it sideways *and* swapped one view for another — which reset its
        /// hover and made it blink at the moment you were looking straight at it.
        /// One button, owned by the window, is the only arrangement in which the
        /// rail can come and go without the control that does it moving at all.
        /// Derived from the rail's own header, not from this group's copy of the
        /// same numbers: the button has to land exactly where the rail's reserved
        /// slot ends, and two independent 76s are two chances to drift.
        public static let chromeToggleLeading =
            Sidebar.headerPadding + Sidebar.trafficLightSlotWidth
        /// Centred on the 48 pt header row, same as the traffic lights beside it.
        public static let chromeToggleTop = (Sidebar.headerHeight - Sidebar.toggleSide) / 2
        /// What a pane header has to leave clear for the two of them.
        public static let chromeReserve = chromeToggleLeading + Sidebar.toggleSide
        // `trafficLightLeading` / `trafficLightSpacing` жили и здесь, и в
        // `Sidebar`, с разными значениями (24 против 20) и без единого читателя
        // у этой пары. Сняты 2026-08-26: два имени с одним смыслом и разными
        // числами — это способ однажды прочитать не то.
        public static let topBarHeight: CGFloat = 56
        public static let titleBlockHeight: CGFloat = 100
        public static let sectionStackGap: CGFloat = Space.s24
        public static let sectionInnerGap: CGFloat = Space.s8
        public static let rowRadius: CGFloat = Radius.md
        public static let updatePillHeight: CGFloat = Space.s32
        public static let updatePillHPadding: CGFloat = Space.s10
    }

    /// Анимированная иконка статуса встречи (`PropellerStatusIcon`).
    ///
    /// Своя группа, а не часть `Sidebar`: та же фигура тем же приводом просится
    /// в меню-бар и в чёлку, а туда рельс с собой не возьмёшь.
    public enum StatusIcon {
        /// Сторона квадрата. Совпадает с глифом нав-строки — работающая встреча
        /// и пункт меню начинают текст на одном отступе.
        public static let side = Space.s16
        /// 30 кадров в секунду. Не 60: фигура из двенадцати кружков на 16 pt
        /// движется медленно, и половина кадров уходит в одни и те же пиксели —
        /// а платит за них главный поток, который в этот момент расшифровывает.
        public static let frameInterval: Double = 1.0 / 30.0
        /// Ниже этого точку не рисуем вовсе: на 16 pt она всё равно не видна, а
        /// заливка стоит столько же, сколько видимая.
        public static let alphaFloor: CGFloat = 0.01
        /// Покой — состояние без движения, поэтому и без веса.
        public static let idleOpacity: Double = 0.4
    }

    /// The left rail — Figma `sidebar new` (308:8446), component `Sidebar`
    /// with its two types: `Primary` (307:6495) and `Secondary` (307:6497).
    ///
    /// Every number here was measured off that frame; the comment on each says
    /// where it comes from, because "264" and "11" are the kind of value that
    /// gets rounded to something tidier by the next person who reads it.
    public enum Sidebar {

        // MARK: Layout

        /// Rail width. The content pane is whatever is left.
        ///
        /// 300 → 264 with the redesign: the rows lost their second line, so the
        /// rail no longer has to hold two sentences side by side — one title and
        /// a 16 pt status icon fit in less.
        public static let width: CGFloat = 264
        public static let minWidth: CGFloat = 240
        public static let maxWidth: CGFloat = 420
        /// Titlebar row: traffic lights and the collapse toggle on the left, search
        /// on the right.
        public static let headerHeight: CGFloat = 48
        /// Inset of that row. Read by the window too, which draws the toggle at
        /// `Tokens.Window.chromeToggleLeading` — one number, so the button cannot
        /// land beside the slot instead of after it.
        ///
        /// 12 → 8 with the redesign. The traffic lights did **not** move with it
        /// (`trafficLightLeading` below): those are real window buttons, and
        /// macOS puts them where macOS puts them.
        public static let headerPadding = Space.s8
        /// Body inset — `py-10` on Frame 123, but 10 across rather than the
        /// comps' 12.
        ///
        /// The rail's margin is split between this and the rows' own padding,
        /// and the split is what moves, not the sum: the text still lands on
        /// the same 24 pt margin, while the hover and selected fills reach 2 pt
        /// closer to both bezels. A row under the pointer should feel like it
        /// belongs to the rail, not like a card floating inside it.
        public static let bodyHPadding = Space.s10
        public static let bodyVPadding = Space.s10
        /// Between the nav block and the meeting list (`gap-20`).
        ///
        /// There used to be a rule between them; it is gone from the comps, and
        /// the gap grew to carry the separation on its own. Brought back from
        /// 28 → 20 — eight points of air the list did not need.
        public static let blockGap = Space.s20
        /// Between dated meeting groups (`gap-20` on 307:6510).
        public static let groupGap = Space.s20
        /// Soft alpha fade at the top of the meeting list once scrolled — mask
        /// height, not a painted wash. Zero while parked at the top.
        public static let listTopFade = Space.s24
        /// Soft alpha fade at the foot of the meeting list — always on. When a
        /// docked prompt is present the clear zone under this fade grows to the
        /// prompt's measured height; the fade itself stays this tall.
        ///
        /// 36 → 32: снято с самой маски макета, а не с глаза. В экспорте она
        /// одна на весь список (244 × 474) и вертикальная — прозрачна у нижней
        /// кромки и непрозрачна с 6.67 % высоты, то есть 474 × 0.0667 = 31.6.
        /// Горизонтального затухания в файле нет вовсе: длинные названия там
        /// обрезаются, и то, что они уходят в прозрачность у нас, — решение
        /// владельца, а не макет (`titleFade`).
        public static let listBottomFade = Space.s32

        /// Nav rows — `list-item`, h-32 rounded-8.
        public static let navRowHeight = Space.s32
        /// `px-8` on `nav-item` (307:6735) — and the same number on the
        /// meeting rows below, which is new: the old rail split its margin
        /// 13/14 so the two blocks' *glyphs* lined up at different paddings.
        /// The redesign gives both rows one padding and lines them up by it.
        public static let navRowHPadding = Space.s8
        public static let navRowGap = Space.s8
        public static let navIconSide = Space.s16
        /// Point size of the SF Symbol inside that 16 pt box — the *ink*, not
        /// the box. The comps set every glyph in the rail at the body size.
        public static let navIconSize: CGFloat = 13
        /// Same, for the header's chrome glyphs (collapse, search, back).
        public static let chromeIconSize: CGFloat = 13

        /// Meeting rows — `meeting-item` (307:7177): h-32, px-8 py-6,
        /// rounded-8, one line and an optional 16 pt status icon.
        ///
        /// The row is a **fixed height** now, not padding around a paragraph:
        /// the title is one line with an ellipsis, so nothing under the pointer
        /// can change how tall the list is.
        public static let meetingRowHeight = Space.s32
        public static let meetingHPadding = Space.s8
        /// Чем длинное название кончается у правого края строки.
        ///
        /// Не многоточием: у самой строки лежит маска, и название уходит в
        /// прозрачность (слой `mask` внутри `meeting-item`, 307:7191). Разница
        /// не косметическая — многоточие съедает ещё один знак ради того, чтобы
        /// сказать «тут не всё», а затухание говорит то же самое и не отнимает
        /// ничего.
        ///
        /// Числа сняты с ассета: в строке 260 × 32 градиент идёт от 0 до 247.5,
        /// стоп непрозрачности на 0.75, прозрачность на 1.0. В долях ширины
        /// строки это 0.714 и 0.952 — то есть затухание длиной около 62 pt, и
        /// последние ~12 pt строки срезаны совсем.
        ///
        /// Долями, а не точками: в макете строка 260, в приложении 244, и
        /// градиент в Figma тянется вместе со слоем.
        private static let titleMaskSpan: CGFloat = 247.5
        private static let titleMaskWidth: CGFloat = 260
        public static let titleFadeStart = 0.75 * titleMaskSpan / titleMaskWidth
        public static let titleFadeEnd = titleMaskSpan / titleMaskWidth

        /// Leading slot for the animated status icon (`PropellerStatusIcon`).
        /// Sized like the nav glyph box, so a working meeting and a nav row
        /// start their text on the same margin.
        public static let meetingIconSide = Space.s16
        /// Date header block — `nav-title` (307:7146): a 14 pt line box and
        /// `pb-4` under it.
        public static let sectionHeaderBlockHeight: CGFloat = 18
        /// What is left of that block once the line has taken its share.
        ///
        /// Derived rather than stated as 8, so changing the header's type moves
        /// the gap instead of growing the group — which is how a one-point line
        /// box turns into a one-point shift of every dated section below it.
        public static var sectionHeaderBottomGap: CGFloat {
            max(0, sectionHeaderBlockHeight - Typo.sectionHeader.lineHeight)
        }

        /// Между строками — одна точка (`gap-px` на обоих контейнерах списка,
        /// 307:6340 и 307:6361). Не ноль: на соседних строках под ховером и
        /// выделением две плашки без зазора слипаются в одну.
        public static let rowGap: CGFloat = 1

        public static let rowRadius = Radius.xs
        /// Meeting rows share the nav rows' corner now. They used to be a step
        /// softer, when a meeting was a three-line card and a nav row was a
        /// control; both are 32 pt rows today, and two corners on one list read
        /// as two lists.
        public static let meetingRadius = Radius.xs
        /// Header chrome — 32×32 rounded-6 (`Icon Background`, 307:6571).
        public static let toggleSide = Space.s32
        public static let toggleIconSide = Space.s16
        public static let chromeRadius = Radius.xxs
        /// «← Назад» in the Secondary header (307:6505): the same 32 pt block as
        /// the icon buttons, widened by its label.
        public static let backGap = Space.s4
        public static let backHPadding = Space.s8

        /// Traffic-light slot: 76×32 after the header's 8 pt padding; discs Ø12
        /// at x 20/40/60, centred on y 24. `SceneWindowChrome` moves the real
        /// window buttons here.
        ///
        /// **Позиция названа центрами, а не углом.** Числа сняты с самого
        /// экспорта слота (76×32, `circle cx=18/38/58 cy=16 r=6`) плюс поле
        /// шапки 8: центры на 26 / 46 / 66 по горизонтали и на 24 по вертикали,
        /// диаметр 12.
        ///
        /// Центрами — потому что кнопка окна не равна нарисованному диску: на
        /// этой системе она **14 pt**, а не 12 (замерено на снимке окна). Ровняя
        /// её угол по углу диска, весь светофор уезжает на точку вправо и вниз;
        /// ровняя центр по центру — он стоит там, где нарисован, при любом
        /// размере, который отдаст AppKit.
        ///
        /// До 2026-08-26 здесь стояли 24 / 44 / 64 из старых макетов.
        public static let trafficLightSlotWidth: CGFloat = 76
        public static let trafficLightFirstCenterX: CGFloat = 26
        public static let trafficLightSpacing = Space.s20
        public static let trafficLightCenterY: CGFloat = 24
        /// Диаметр диска **в макете**. Рисует его только галерея
        /// (`SidebarTrafficLights.drawn`) — настоящую кнопку рисует AppKit.
        public static let trafficLightDiameter = Space.s12

        /// Foot of the Secondary rail — mark, name, version, the sentence that
        /// invites a bug report, and «Помощь ↗» (307:6678).
        ///
        /// It carries what the Primary rail used to carry as a nav row
        /// («Сообщить о проблеме»). A row in a list of destinations that opened
        /// a browser was the odd one out; at the foot of settings, under the
        /// version it needs anyway, it is the same offer in the right place.
        public enum Footer {
            /// Плита иконки приложения — 32 со скруглением 8 (307:6679).
            public static let markSide = Space.s32
            public static let markRadius = Radius.xs
            /// Высота самой марки внутри плиты. Снято с экспорта иконки:
            /// рисунок занимает 16.63 × 18.40 в квадрате 32 и стоит по центру.
            /// Не «плита минус отступ»: у марки своя пропорция, и подгонять её
            /// под квадрат — терять ту симметрию, на которой держится вращение.
            public static let markGlyph: CGFloat = 18.4
            /// Плита и рисунок — свои краски, не из пары «тёмная / светлая»:
            /// это иконка приложения, и она одна в обеих темах.
            public static let markPlate = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a100)
            public static let markInk = SwiftUI.Color(
                .sRGB, red: 3.0 / 255, green: 3.0 / 255, blue: 3.0 / 255, opacity: 1
            )
            public static let blockGap = Space.s16
            public static let textGap = Space.s6
            public static let hPadding = Space.s8
            public static let topPadding = Space.s8
            public static let bottomPadding = Space.s16
            public static let buttonHeight = Space.s32
            public static let buttonRadius = Radius.xs
            public static let buttonHPadding = Space.s8
            public static let buttonGap = Space.s4
            /// 12 / 16 — подпись кнопки подвала (307:6688). Единственный кегль
            /// в рельсе, отличный от 13: кнопка тише строки, на которой стоит.
            public static let buttonLabel = Typography.Style(
                size: 12, lineHeight: 16, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// `bg-white/10` в покое (307:6686) — не 5 %, как у строк списка:
            /// это кнопка, а не ряд, и в покое она видна.
            public static let buttonFill = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                         light: Primitive.AlphaBlack.a10)
            public static let buttonHoverFill = Primitive.ink(dark: Primitive.AlphaWhite.a15,
                                                              light: Primitive.AlphaBlack.a15)
            /// Стрелка «наружу» — 70 %, тише подписи, но громче даты (307:6689).
            public static let buttonGlyph = Primitive.ink(dark: Primitive.AlphaWhite.a70,
                                                          light: Primitive.AlphaBlack.a70)
        }

        // MARK: Paint

        /// The rail is the window's own background, lifted a hair.
        ///
        /// The comps say `#101010 @ 92 %`, which reads as "a plate" and is not:
        /// measured against the pane beside it, the rail is 20/255 and the pane
        /// 17.5 — the *same* ink, the rail simply 92 % opaque where the pane is
        /// 97 %, so a little more of the canvas shows through. One per cent of
        /// separation, and the hairline border does the rest.
        ///
        /// Painting the literal 92 % here was wrong: over Propeller's glass it
        /// covers the material and turns the rail into a slab, which is the one
        /// thing the design is not. What the rail owns is the *difference* — a
        /// wash thin enough that the window still shows through it.
        public static let surface = Primitive.ink(dark: 0.02, light: 0.02)
        /// Hairline on the trailing edge, and the rule under the nav block.
        public static let border = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                 light: Primitive.AlphaBlack.a9)
        /// Selected row wash — white 10 % (`State=Active`, 307:6731).
        public static let rowSelected = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                      light: Primitive.AlphaBlack.a10)
        /// Hover — white 5 % (`State=Hover`, 307:6732), half of `rowSelected`,
        /// so that pointing at a row can never be mistaken for having chosen it.
        public static let rowHover = Primitive.ink(dark: Primitive.AlphaWhite.a5,
                                                   light: Primitive.AlphaBlack.a5)

        /// Nav label and its icon — one colour, they always move together.
        ///
        /// **One colour for every state but disabled**, which is the redesign's
        /// change: the label no longer dims when the row is not selected. The
        /// wash behind the row says which one is chosen, and saying it twice
        /// made an unselected rail look half switched off.
        public static let navLabel = Primitive.ink(dark: Primitive.AlphaWhite.a90,
                                                   light: Primitive.AlphaBlack.a88)
        /// `State=Disabled` (307:6733) — label and glyph together.
        public static let navLabelDisabled = Paint.Text.disabled
        /// Shortcut hint, white 40 %.
        public static let navShortcut = Primitive.ink(dark: Primitive.AlphaWhite.a40,
                                                      light: Primitive.AlphaBlack.a48)
        /// Быстрое действие строки — плюс справа (`Icon`, 307:6712) — в две
        /// ступени: 30 %, пока курсор на строке, и 70 %, когда он на самом
        /// плюсе.
        ///
        /// **Макет даёт одну ступень**, 70 % на ховер строки. Две — решение
        /// владельца 2026-08-27, и оно чинит то, чего в статичном кадре не
        /// видно: плюс, который в 70 % проявляется вместе с плашкой строки,
        /// выглядит нажатым до нажатия, и по нему невозможно понять, куда
        /// сейчас попадёт клик — в строку или в него. Тише строки, пока это
        /// строка; громче её, когда цель — он.
        ///
        /// Ступени называют то, на что наведено, а не «покой» и «ховер»: покоя
        /// у этой кнопки нет вовсе — в покое строки её не видно.
        public static let navQuickActionOnRow = Primitive.ink(dark: Primitive.AlphaWhite.a30,
                                                              light: Primitive.AlphaBlack.a30)
        public static let navQuickActionOnSelf = Primitive.ink(dark: Primitive.AlphaWhite.a70,
                                                               light: Primitive.AlphaBlack.a70)
        /// Плашка под плюсом — 24 × 24 со скруглением 4, решение владельца
        /// 2026-08-27. В макете плашки нет вовсе, глиф стоит голым.
        ///
        /// Квадрат, а не 16 pt глифа: у плюса на строке своя, отдельная цель, и
        /// у цели должны быть края. Двадцать четыре в строке 32 — это по 4
        /// сверху и снизу, и правым краем плашка встаёт на поле строки (8),
        /// то есть новых чисел здесь не появляется, кроме её собственных.
        public static let navQuickActionPlate = Space.s24
        public static let navQuickActionPlateRadius = Radius.xxxs
        /// Заливка плашки под курсором — 10 %, столько же, сколько у выбранной
        /// строки. Ложится **поверх** ховера строки (5 %), так что глазами это
        /// около 14 %: десять процентов здесь — краска плашки, а не итог.
        public static let navQuickActionPlateHover = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                                   light: Primitive.AlphaBlack.a10)

        /// «17:30 · 45 мин».
        public static let meetingMeta = Primitive.ink(dark: Primitive.AlphaWhite.a55,
                                                      light: Primitive.AlphaBlack.a55)
        /// The meeting's name. The only ink on the row now — white 90 %,
        /// the same as a nav label, because they are the same kind of line.
        public static let meetingTitle = Primitive.ink(dark: Primitive.AlphaWhite.a90,
                                                       light: Primitive.AlphaBlack.a88)
        /// What it was about — the quiet half.
        public static let meetingPreview = Primitive.ink(dark: Primitive.AlphaWhite.a55,
                                                         light: Primitive.AlphaBlack.a55)
        /// «Вчера, 24 августа» — white 40 % on `nav-title` (307:6966).
        public static let sectionHeader = Primitive.ink(dark: Primitive.AlphaWhite.a40,
                                                        light: Primitive.AlphaBlack.a48)
        /// Collapse toggle glyph.
        public static let chromeIcon = Primitive.ink(dark: Primitive.AlphaWhite.a40,
                                                     light: Primitive.AlphaBlack.a48)
        /// Brightest point of the processing sweep, painted over `meetingPreview`.
        public static let shimmerPeak = Primitive.ink(dark: Primitive.AlphaWhite.a75,
                                                      light: Primitive.AlphaBlack.a55)

        // MARK: Type

        /// Not `Type` — that spelling collides with metatype syntax at every use site.
        public enum Typo {
            /// 13 / 16 regular — nav row label.
            ///
            /// Same face as the meeting title below it. The rail therefore has
            /// one text size and one weight, and everything is said with colour.
            ///
            /// 14 → 13 with the redesign, and the line box 18 → 16: a row is a
            /// fixed 32 pt now, and 16 is what leaves 8 above and below it.
            public static let navLabel = Typography.Style(
                size: 13, lineHeight: 16, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 11 / 14 regular — time line, shortcut hint.
            ///
            /// Eleven, not the 10 of the label scale: the component sheet says
            /// `text-[11px]`, and it is the one size in the rail that is off the
            /// scale on purpose — 10 is legible but the times sit next to a
            /// 14 pt title and read as a footnote at that size.
            public static let meta = Typography.Style(
                size: 11, lineHeight: 14, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 13 / 16 regular — the meeting title, one line.
            ///
            /// Same Style as `navLabel`: one face for the whole rail.
            public static let meetingTitle = navLabel
            /// 11 / 14 regular — date header. The same face and size as the
            /// time line; only the colour separates them (30 % against 55 %).
            public static let sectionHeader = meta
        }

        // MARK: Motion

        /// One pass of the processing sweep, end to end.
        public static let shimmerPeriod: Double = 1.6
        /// Angle of the sweep, in CSS degrees (0 = up, 90 = right).
        public static let shimmerAngle: Double = 113.913
        /// Half the band's width as a fraction of the gradient line — Figma's
        /// stops are 29.643 % / 43.876 % / 58.108 %.
        public static let shimmerHalfWidth: Double = 0.14232
        public static let shimmerCenter: Double = 0.43876

        /// Soft typewriter on a status line. Не в рельсе с 2026-08-26 — там
        /// строки статуса больше нет; числа остались для живого транскрипта
        /// (`RecordingPane`), который читает их через `SoftTypewriter`.
        public enum StatusReveal {
            public static let softChars: Double = 16
            public static let appearSecondsPerChar: Double = 0.028
            public static let appearMin: Double = 0.35
            public static let appearMax: Double = 0.9
            public static let dismissSecondsPerChar: Double = 0.012
            public static let dismissMin: Double = 0.12
            public static let dismissMax: Double = 0.35
        }
    }

    
    /// The content pane beside the rail — Figma 31:4624.
    ///
    /// Two columns that both flex: the summary takes the room it can up to a
    /// comfortable measure, the notes take the rest. Neither is a fixed width,
    /// which is what lets the same pane work at 800 pt and at 500.
    public enum Pane {

        // MARK: Header (31:4625) — the rail's 48 pt row, continued

        public static let headerHeight = Sidebar.headerHeight
        /// Title block: `w-430 px-16 py-8`.
        public static let headerTitleWidth: CGFloat = 430
        public static let headerHPadding = Space.s16
        public static let headerVPadding = Space.s8
        /// Soft alpha fade where a long title meets the action cluster — same
        /// idea as the rail's list edge, sideways.
        public static let titleEdgeFade = Space.s24
        /// Trailing cluster: `px-8 gap-6`.
        public static let headerActionsPadding = Space.s8
        public static let headerActionsGap = Space.s6
        public static let headerButtonSide = Space.s32
        public static let headerButtonRadius = Radius.xs
        public static let headerIconSize: CGFloat = 13

        // MARK: Summary column (31:4645)

        public static let summaryHPadding = Space.s40
        public static let summaryVPadding = Space.s24
        /// Верх панели — 312:11129. Полосы над встречей больше нет, и панель
        /// начинается от кромки окна, как страница настроек.
        public static let paneTopPadding = Space.s32
        /// Строка атрибутов → имя встречи → первый абзац: один шаг на оба стыка.
        public static let titleGap = Space.s16
        /// Кнопки в правом верхнем углу панели — единственное место, где
        /// горизонтальное поле не 40: они прижаты к кромке блока.
        public static let paneActionsInset = Space.s8
        // MARK: Строка атрибутов — 312:11129

        public enum Meta {
            public static let height = Space.s24
            public static let radius = Radius.xxs
            /// Между содержимым соседних чипов. 14, а не 8: плиты вылезают
            /// за содержимое на 6 в каждую сторону, и 8 склеило бы их.
            public static let gap: CGFloat = 14
            /// Насколько плита ховера шире своего содержимого.
            public static let hPadding = Space.s6
            /// Между иконкой и словом внутри чипа. 4, а не 2: на 2 значок
            /// и слово читались одним предметом, а это два (владелец, 2026-08-27).
            public static let iconGap = Space.s4
            public static let iconSize: CGFloat = 12
            /// Ховер — **только** у чипа, по которому есть что нажать: сейчас
            /// это проекты. Дата не станет нажимаемой никогда, состав — когда
            /// у него будет что показать. Залитый в макете чип «6 человек» —
            /// его ховер, а не его отличие от даты; подсвечивать факт, который
            /// ни во что не ведёт, значит обещать несуществующее действие.
            public static let hoverFill = Sidebar.rowSelected
            public static let label = Paint.Text.primary
            public static let quiet = Sidebar.chromeIcon
        }

        /// «Поделиться» — 312:11129. Первая сплошная кнопка в приложении:
        /// выход наружу конституционен (`VISION.md` §4), и это единственное
        /// действие панели, которое зовут, а не находят.
        public static let sharePillHPadding = Space.s10
        /// Room under the last line so a scrolled summary is not hard against
        /// the window edge.
        public static let summaryBottomPadding = Space.s40
        /// Between sections — 312:11129. Off the scale, and it is the comps'
        /// own number: the section break is the loudest silence on the screen
        /// now that the headings themselves went quiet.
        public static let summarySectionGap: CGFloat = 36
        /// A section heading to the first item under it — 312:11129.
        public static let summaryHeadingGap = Space.s8
        public static let summaryMinWidth: CGFloat = 520
        /// Мера, а не контейнер. 569 = 649 − 40·2, то есть ровно столько текста
        /// в строке, сколько в макете 312:11129. Прежние 640 были правдой для
        /// 14 pt; на 13 pt это уже слишком длинная строка.
        public static let summaryMaxWidth: CGFloat = 569
        /// Мера вместе с полями — ширина блока панели в макете, 649.
        public static let paneMeasure = summaryMaxWidth + summaryHPadding * 2
        /// Мера колонки идущей записи и поля заметки — прежние 720.
        ///
        /// Своё число, не одолженное у саммари. До 2026-08-27 это была одна
        /// мера на всё, и сужение саммари до макетных 569 утащило бы за собой
        /// две поверхности, которые по этому макету не снимались. Та же
        /// развязка, что сделана для страницы настроек.
        public static let recordingMeasure: CGFloat = 640 + summaryHPadding * 2
        /// Между пунктами — а абзац и пункт списка в макете один и тот же
        /// предмет, поэтому число одно. Втяжки у пункта нет: маркера, под
        /// который она делалась, на экране больше нет.
        public static let summaryItemGap = Space.s20

        // MARK: Transcript column (32:5278)

        /// Between remarks. Generous on purpose — a transcript is scanned for
        /// who said what, and the gap is what makes the turns findable.
        public static let transcriptTurnGap = Space.s24
        /// Speaker line to its text.
        public static let transcriptLineGap = Space.s2
        /// Speaker to timecode.
        public static let transcriptMetaGap = Space.s8
        /// Fixed, so the timecodes form a column instead of drifting with names.
        ///
        /// Sized for the widest form `Timecode.text` emits below the ten-hour
        /// mark — `H:MM:SS`, e.g. `1:23:12` — not just `MM:SS`: at 40 pt a
        /// meeting past the one-hour mark wrapped its own timecode onto a
        /// second line next to the speaker name (measured on a live meeting,
        /// `1:23:12` → `1:23:1` / `2`). Monospaced digits make every digit
        /// combination the same width, so only the extra colon's width
        /// (`H:MM:SS` measures ~41.5 pt in `transcriptMeta` at the rail's
        /// weight trim) decides the minimum; 48 keeps the same margin the
        /// original 40 gave `MM:SS`.
        public static let transcriptTimeWidth: CGFloat = Space.s48
        /// Насколько плашка заметки вылезает за её текст.
        ///
        /// Наружу, а не внутрь: заметка стоит в ленте между репликами, и её
        /// строки обязаны начинаться там же, где их строки. Плашка с внутренним
        /// отступом сдвинула бы абзац вправо — подсветка ценой столбца.
        /// Горизонтально шире, чем вертикально, потому что по вертикали её
        /// держат ещё и зазоры между репликами.
        public static let transcriptNotePlateBleedH = Space.s12
        public static let transcriptNotePlateBleedV = Space.s8

        // MARK: Поле заметки на экране записи (Figma 136:3444 / 136:3497)

        /// Как поле растёт.
        ///
        /// Плиты здесь нет: как она поднимается и опускается, знает сама плита
        /// (`SummonedPlate`), на ступенях панели действий — это один и тот же
        /// предмет, и двух способов возникнуть у него быть не может.
        ///
        /// Рост — своя ступень, длиннее прихода. Прибавившаяся строка отодвигает
        /// разговор, а разговор — то, ради чего в это окно смотрят: он обязан
        /// уехать так, чтобы за ним успел глаз, а не моргнуть.
        public enum NoteBar {
            public static let grow = Motion.Step.t180
            /// Подсказка приходит с первым знаком и уходит с последним. Мелкое,
            /// значит рабочая ступень.
            public static let hint = Motion.Step.t120
        }

        /// Отступ поля от краёв панели. Выведен, а не назван: текст в поле
        /// обязан стоять на той же вертикали, что и текст реплик, а плашка
        /// вылезает за него ровно настолько же, насколько плашка заметки внутри
        /// ленты. Сорок минус двенадцать — и на любой ширине окна совпадает.
        public static let noteBarHPadding = summaryHPadding - transcriptNotePlateBleedH
        public static let noteBarVPadding = Space.s16
        /// Внутри плашки. Совпадает с зазором до края панели по вертикали, так
        /// что поле в покое читается как строка, а не как элемент управления.
        public static let noteBarFieldPadding = Space.s12
        public static let noteBarMinHeight = Space.s40
        /// Дальше поле не растёт, а скроллится внутри себя. Четыре строки —
        /// столько видно в макете, и столько же помещается, не съедая разговор,
        /// ради которого заметку и пишут.
        public static let noteBarMaxLines = 4
        public static let noteBarRadius = Radius.md
        /// Подсказка «⏎» в правом нижнем углу. Внизу, а не по центру: она
        /// относится к последней строке, и при росте поля обязана остаться
        /// рядом с ней — та же логика, что у чёлки.
        /// Собственный отступ `NSTextView` внутри редактора — его вычитают,
        /// чтобы набранный текст встал на ту же вертикаль, что мерка,
        /// приглашение и реплики над полем. Замерено, а не выведено: это
        /// системное число, и живёт оно здесь именно поэтому.
        public static let noteBarEditorInset: CGFloat = 5
        public static let noteBarHintSide = Space.s20
        public static let noteBarHintIconSize: CGFloat = 14
        public static let noteBarHintGap = Space.s16
        /// Растворение расшифровки под полем.
        ///
        /// Длинное намеренно: под коротким градиентом строка не исчезает, а
        /// обрезается, и это читается как сбой отрисовки. Замерено с макета.
        public static let transcriptBottomFade: CGFloat = 143

        // MARK: Живая колонка — то же место, что у саммари

        /// Как проявляется живой текст.
        ///
        /// Считано от подачи: движок отвечает раз в две секунды порциями по
        /// три-четыре слова (`GigasttLiveSession`), то есть на проявление есть
        /// почти вся эта пауза. Двадцать пять миллисекунд на знак — порция в
        /// двадцать знаков печатается полсекунды и читается как письмо, а не
        /// как вспышка; потолок в 1.4 с не даёт длинной порции догонять
        /// следующую. Мягкий край в восемь знаков — на этой скорости он виден.
        public enum LiveReveal {
            public static let softChars: Double = 8
            public static let secondsPerChar: Double = 0.025
            public static let minimum: Double = 0.2
            public static let maximum: Double = 1.4
        }

        /// Доезд колонки до низа, когда в неё дописали. Не мгновенно: прыжок
        /// без движения читается как перерисовка экрана.
        public static let followScroll = Motion.Step.t240

        /// Замена содержимого левой колонки: расшифровка уходит, саммари
        /// приходит. Не одновременно — по очереди, иначе два текста проступают
        /// друг сквозь друга. Уход короче прихода: пустое место держать долго
        /// незачем, а появление читается спокойнее медленным.
        public static let columnSwapOut = Motion.Step.t180
        public static let columnSwapIn = Motion.Step.t240

        /// Смена самой встречи: панель показывает уже не то же самое, и уходит из
        /// неё **всё сразу** — заголовок, колонка, заметки. Раньше уходила одна
        /// колонка, а заголовок и заметки щёлкали в тот же кадр, и переход читался
        /// как «одно ещё не ушло, а второе уже здесь».
        ///
        /// Вдвое короче замены содержимого колонки, и это не экономия: там меняется
        /// то, *что* показано, и на смысл нужно время, а здесь — про кого, и это
        /// уже сказал рельс. Только прозрачность: любое движение на 0,2 с успевает
        /// быть замеченным, но не успевает быть прочитанным.
        public static let meetingSwapOut = Motion.Step.t90
        public static let meetingSwapIn = Motion.Step.t120

        // MARK: Плашка заметки

        /// Буквально строка встречи под ховером: тот же оттенок, то же
        /// скругление. Не «похожая», а та же — в одном окне две разные плашки
        /// читаются как два разных приложения.
        public static let notePlateFill = Sidebar.rowHover
        public static let noteRadius = Sidebar.meetingRadius

        // MARK: Paint

        public static let title = Paint.Text.primary
        public static let meta = Sidebar.meetingMeta
        public static let body = Paint.Text.primary
        public static let placeholder = Sidebar.sectionHeader
        public static let buttonIcon = Sidebar.chromeIcon

        // MARK: The summary as an editor

        /// `body`, for the text storage — see `Primitive.inkNSColor`.
        public static let bodyNSColor = Primitive.inkNSColor(
            dark: Primitive.AlphaWhite.a90, light: Primitive.AlphaBlack.a88
        )
        /// A section heading inside the summary — 312:11129 draws it at 30 %.
        /// The heading stopped being the loudest thing in the block and became
        /// a label over it, so it is quieter than what it names, not bolder.
        public static let headingNSColor = Primitive.inkNSColor(
            dark: Primitive.AlphaWhite.a30, light: Primitive.AlphaBlack.a30
        )
        /// The caret. Full-strength ink: a 1 pt line at 95 % reads as grey.
        public static let caret = Tokens.dualNSColor(
            dark: Primitive.AlphaWhite.nsColor(Primitive.AlphaWhite.a100),
            light: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a100)
        )
        /// Selection. Quiet enough to read through — the action bar is what
        /// says «this is selected», the wash only says where.
        public static let selectionFill = Tokens.dualNSColor(
            dark: Primitive.AlphaWhite.nsColor(Primitive.AlphaWhite.a20),
            light: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a12)
        )

        // MARK: Selection action bar

        /// A control the pointer summoned, not a bar the app raised over the
        /// text — hence a row under the selection rather than a strip at an
        /// edge, and hence it leaves the moment the selection does.
        /// Measured off Figma 91:993 at 1×, where the body's 22 pt leading gives
        /// the scale: the bar is 40 tall, its items 32, so the padding is 4 on
        /// every side. No border — separation is glass + shadow.
        public enum Bar {
            public static let height = Space.s40
            public static let radius = Radius.xs
            /// Equal inset on every side: 4 → 32 pt item inside 40 pt bar.
            public static let padding = Space.s4
            public static let itemGap = Space.s2
            /// Same gap on both sides of every divider — one number, not
            /// «around a group» that stacks with item padding unevenly.
            public static let groupGap = Space.s4
            public static let itemHeight = Space.s32
            /// Horizontal pad inside every control (menu, B/I, «Короче»).
            /// Kept identical so the bar's left edge and right edge match.
            public static let itemHPadding = Space.s8
            public static let itemRadius = Radius.xxs
            public static let itemIconSize: CGFloat = 12
            public static let dividerHeight = Space.s16
            /// Between the last line of the selection and the bar's top edge.
            public static let anchorGap = Space.s8
            /// Drop under the bar. Same blur in both themes; opacity carries the
            /// difference — black at 70 % reads as a stain on light paper and as
            /// almost nothing on dark glass.
            public static let shadowRadius: CGFloat = 28
            public static let shadowY = Space.s4
            public static let menuChevronSize: CGFloat = 9
            public static let menuChevronGap = Space.s4

            public static let divider = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                      light: Primitive.AlphaBlack.a10)
            /// 95 % white at rest — the bar is a tool over dark glass, and 55 %
            /// reads as disabled. Hover keeps the same ink; the pill fill is
            /// what moves.
            public static let label = Paint.Text.primary
            /// White 7 % over the bar — the «Подробнее» pill the comp draws.
            public static let itemHoverFill = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                            light: Primitive.AlphaBlack.a7)
            public static let itemOnFill = Primitive.ink(dark: Primitive.AlphaWhite.a12,
                                                         light: Primitive.AlphaBlack.a10)
            public static let shadow = Tokens.dual(
                dark: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a80),
                light: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a28)
            )

            /// 12, measured: «Обычный» is 55 pt wide in the comp, which is this
            /// size and no other. The chrome around it is 14 — the bar is
            /// smaller than what it sits on, which is what keeps it a tool
            /// rather than a second interface over the text.
            public static let labelType = Typography.Label.smRegular
                .lineHeight(16)
                .trimmed(Typography.railWeightTrim)

            // MARK: Appearing and leaving

            /// The bar does not travel between selections. Selecting somewhere
            /// else is not the same bar moving — it is one bar's job finishing
            /// and another's starting, and a control sliding across the text
            /// under the pointer is the app taking a turn nobody gave it.
            public static let fadeOut = Motion.Step.t90
            public static let fadeIn = Motion.Step.t120
            /// The new bar waits for the old one to be gone. Without the pause
            /// the two cross-fade, which is the sliding it replaces, softer.
            public static let fadeInDelay = Motion.Step.t60
        }

        // MARK: Meeting switcher (⌥Tab)

        /// The panel is the action bar's brother: same plate (`SummonedPlate`),
        /// same corner, same drop, and the rows are the rail's rows at the rail's
        /// width.
        ///
        /// **Its own paddings since 2026-08-26.** The rail's row became one
        /// clipped line 32 pt tall; the switcher's is still a wrapping paragraph
        /// of two voices, and it has to stay one until that surface is redesigned
        /// too. These are the numbers the rail had before it moved.
        public enum Switcher {
            public static let rowHPadding: CGFloat = 14
            public static let rowVPadding = Space.s12
            /// The list is *whole*, so it has to stop somewhere. Six or seven rows
            /// at the rail's line height: enough that the walk has visible context
            /// below it, short enough that the panel stays a HUD and not a second
            /// window over the one you are reading.
            public static let maxHeight: CGFloat = 320
            /// The step: the pill stays where it is and the list slides under it.
            /// Faster than the rail's own reflow (0.28) — that one answers a
            /// meeting arriving, this one answers a key, and a key that repeats.
            ///
            /// Единственное движение в приложении, которое отвечает клавише, и
            /// клавише повторяющейся — то есть единственное исключение из
            /// правила в `Motion`. Оно взвешено: без хода списка панель за свою
            /// секунду не успевает сказать, откуда ушли и куда идут, а сказать
            /// это — вся её работа.
            public static let step = Motion.Step.t180
            /// Called by a key, gone when the key comes up. Same order of
            /// magnitude as the action bar's fade, for the same reason.
            public static let fade = Motion.Step.t120
            /// How long ⌥Tab has to be held before the panel is worth showing.
            /// A tap-and-release is a switch, not a browse: it should land on the
            /// next meeting without a plate flashing over the window on the way.
            public static let appearDelay: Double = 0.2
            /// Four more than the action bar's. That bar is a row of 32 pt controls
            /// and 4 is the whole gap it needs; here the plate holds *paragraphs*,
            /// three lines deep, and at 4 they sat against the glass.
            public static let padding = Bar.padding + Space.s4
            /// Concentric with the row's own corner: the plate's radius is the
            /// row's plus the gap the row is inset by. Any other number and the
            /// two arcs stop being parallel — visible on exactly the row that is
            /// highlighted, which is the one being looked at.
            public static let radius = Tokens.Sidebar.meetingRadius + padding
        }

        // MARK: The summary arriving

        /// Soft typewriter on the `NSTextView` — appear and dismiss.
        ///
        /// Plays when the model wrote this (new summary or rewritten fragment),
        /// nowhere else. Duration scales with character count and clamps.
        public enum Reveal {
            /// Wide soft head — a short ramp reads as glyphs popping.
            public static let softChars: Double = 28
            public static let appearSecondsPerChar: Double = 0.022
            public static let appearMin: Double = 0.55
            public static let appearMax: Double = 2.2
            /// Dismiss is snappier — the old words get out of the way.
            public static let dismissSecondsPerChar: Double = 0.01
            public static let dismissMin: Double = 0.2
            public static let dismissMax: Double = 0.5
        }

        /// The fragment the model is being asked about, while it thinks.
        ///
        /// Dimmed first, then swept. At 95 % white a band of light has nothing
        /// to add — the shimmer was there and invisible. Dropping the glyphs to
        /// 55 % gives the sweep somewhere to travel, and the dip itself says
        /// «этот кусок сейчас не ваш».
        public enum Rewriting {
            public static let dimmed = Primitive.inkNSColor(
                dark: Primitive.AlphaWhite.a55, light: Primitive.AlphaBlack.a55
            )
        }

        // MARK: Type

        public enum Typo {
            /// 14 / 18 regular — the meeting's name in the *recording* pane's
            /// header. The finished meeting carries its name in the body now.
            public static let headerTitle = Sidebar.Typo.meetingTitle
            /// 22 / 24 regular — the meeting's name, in the body — 312:11129.
            public static let paneTitle = Typography.Style(
                size: 22, lineHeight: 24, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 13 / 22 regular — everything that is read rather than scanned.
            public static let body = Typography.Style(
                size: 13, lineHeight: 22, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// The lead is no longer a face of its own — 312:11129 draws the
            /// opening paragraph exactly like the rest of the text. It stays a
            /// *kind* because the parser's round trip stands on it
            /// (`SummaryDocument.promotingLead`); it just stopped shouting.
            public static let lead = body
            public static let leadTracking: CGFloat = 0
            /// 12 / 14 regular — a section heading inside the summary. Was
            /// 14 / 22 bold: the comps turned it from a title into a label.
            public static let sectionTitle = Typography.Style(
                size: 12, lineHeight: 14, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            public static let sectionTracking: CGFloat = 0
            /// 12 / 14 and 12 / 16 — the attribute row over the title.
            public static let meta = Typography.Style(
                size: 12, lineHeight: 14, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            public static let metaWide = Typography.Style(
                size: 12, lineHeight: 16, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 11 / 14 regular — the speaker and timecode over a remark.
            public static let transcriptMeta = Sidebar.Typo.meta
            /// Реплика — 14 / 22.
            ///
            /// Было 12 / 18, «транскрипт длинный, его просматривают». Отменено:
            /// один и тот же текст живёт в двух местах — живой строкой во время
            /// встречи и расшифровкой после, — и переход между ними при разном
            /// кегле читается как перерисовка встречи, а не как её уточнение.
            /// Читаемость важнее компактности: это речь, а не список.
            ///
            /// С 2026-08-27 это **своё** число, а не `= body`. Саммари ушло на
            /// 13 по своему макету; расшифровку по этому макету не снимали, и
            /// тащить её за саммари значило бы поменять поверхность, о которой
            /// решения не принимали. Живая строка и расшифровка по-прежнему
            /// равны друг другу — а именно это и было обещано выше.
            public static let transcriptBody = Typography.Style(
                size: 14, lineHeight: 22, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
        }
    }

    /// Модалка публикации по ссылке — Figma `summary/share-link`
    /// (298:26607 — публикация, 298:26275 — опубликовано).
    ///
    /// Плита здесь та же, что у модалки создания проекта (`Projects.Modal`):
    /// 360, скругление 20, стекло `rgba(16,16,16,0.96)`, рамка в 10 %. Числа
    /// повторены, а не одолжены: «токены шеринга берут ширину у проектов» —
    /// связь, которой в макете нет, и она уже однажды стоила страницы настроек,
    /// одолжившей меру у саммари. Заводить общий блок под две модалки рано;
    /// появится третья — вынести.
    public enum Share {

        // MARK: Плита

        public static let width = Projects.Modal.width
        public static let radius: CGFloat = 20
        public static let padding = Space.s20
        /// Между шапкой и телом.
        public static let blockGap = Space.s20
        /// Внутри тела: превью → строка срока → подвал.
        public static let bodyGap = Space.s12
        /// Между кнопкой и подписью под ней; в опубликованном — между кнопками.
        public static let footerGap = Space.s8
        public static let blur: CGFloat = 16
        public static let scrimBlur: CGFloat = 6

        // MARK: Части

        /// Превью саммари — то, что увидит открывший ссылку.
        public static let previewHeight: CGFloat = 200
        public static let previewRadius = Radius.xs
        /// Строка «Срок жизни ссылки»: содержимое 32 в поле 52 (298:26618).
        public static let rowHeight = Space.s32
        public static let rowVPadding = Space.s10
        public static let rowGap = Space.s8
        public static let rowLineGap = Space.s2
        /// Кнопка и поле ссылки.
        public static let controlHeight = Space.s32
        public static let controlRadius = Radius.xs
        public static let controlHPadding = Space.s10
        public static let linkVPadding = Space.s4
        public static let linkIconWidth = Space.s16
        public static let iconSize: CGFloat = 13

        /// Подпись под кнопкой — две строки по 14 (298:26631). Названа
        /// числом, а не выведена из шрифта: SF на 12 pt рисует 15, и высота
        /// плиты уехала бы на три точки. Плита от этого не прыгает, когда
        /// вместо обещания встаёт причина в одну строку.
        public static let footnoteHeight: CGFloat = 28

        /// Затухание длинной ссылки — доля ширины, как в строке рельса.
        /// В макете градиент начинается на 67,391 % и уходит в ноль к краю.
        public static let linkFadeStart = 0.67391

        // MARK: Краски

        public static let plate = Projects.Modal.plate
        public static let plateBorder = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                      light: Primitive.AlphaBlack.a10)
        /// Скрим под плитой — 60 % с размытием 6.
        public static let scrim = Tokens.dual(
            dark: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a60),
            light: Primitive.AlphaBlack.nsColor(Primitive.AlphaBlack.a60)
        )
        public static let title = Paint.Text.primary
        public static let quiet = Sidebar.chromeIcon
        public static let rowTitle = Paint.Text.primary
        public static let linkFill = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                   light: Primitive.AlphaBlack.a7)
        public static let linkText = Primitive.ink(dark: Primitive.AlphaWhite.a90,
                                                   light: Primitive.AlphaBlack.a88)
        /// Заливка главной кнопки — `#e5e5e5`, а не чистый белый: пилюля
        /// «Поделиться» в панели белая, а кнопка в модалке на стекле чуть
        /// глуше, и в макете это два разных значения.
        public static let actionFill = Tokens.dual(
            dark: NSColor(srgbRed: 229 / 255, green: 229 / 255, blue: 229 / 255, alpha: 1),
            light: NSColor(srgbRed: 26 / 255, green: 26 / 255, blue: 26 / 255, alpha: 1)
        )
        public static let actionLabel = Paint.Text.primaryInverse
        public static let actionDisabledFill = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                             light: Primitive.AlphaBlack.a10)
        public static let actionDisabledLabel = Sidebar.chromeIcon

        // MARK: Тип

        public enum Typo {
            /// 15 / 20 — заголовок модалки.
            public static let title = Typography.Style(
                size: 15, lineHeight: 20, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 13 / 16 — название строки и текст ссылки.
            public static let row = Pane.Typo.body.lineHeight(16)
            /// 12 / 14 — вторая строка и подпись под кнопкой.
            public static let quiet = Settings.Typo.subtitle
            /// 12 / 16 — надписи кнопок.
            public static let action = Pane.Typo.metaWide
        }
    }

    /// Настройки — состояние правой панели, а не отдельное окно.
    ///
    /// Разделы — Figma `settings` (254:3399), девять экранов одной формы: слева
    /// колонка рельса с шестью разделами, справа страница.
    ///
    /// Страница устроена из трёх вещей и больше ни из чего: заголовок раздела,
    /// тихий заголовок группы и карточка с ячейками. Плашка вернулась — до
    /// 2026-08-26 её не было принципиально (иерархия расстоянием, PR-005), но
    /// с разделами страница коротка, а ячейки в ней разнородны, и без карточки
    /// «Ваше имя» и «Тема приложения» читались одним списком без границы.
    public enum Settings {

        // MARK: Страница — 254:1412

        /// Потолок ширины страницы — своё число, не одолженное. До 2026-08-27
        /// здесь стояло `Pane.summaryMaxWidth`, и это было правдой ровно пока
        /// саммари и настройки мерились одинаково. Саммари уезжает на меру
        /// своего макета; настройки остаются на 640, потому что с
        /// `pageHPadding` 36 это и есть ширина, на которой сняты карточки.
        public static let maxWidth: CGFloat = 640
        public static let pageHPadding: CGFloat = 36
        public static let pageVPadding = Space.s28
        /// Между заголовком, группами и карточками — один шаг на всё.
        public static let blockGap = Space.s20

        // MARK: Группа

        /// Заголовок группы → её карточка.
        public static let headerBottomGap = Space.s8
        /// Отступ заголовка слева. Меньше внутреннего отступа карточки (14):
        /// заголовок стоит *над* ней, а не в ней.
        public static let headerLeadingInset = Space.s8

        /// Карточка группы — `Settings Section` (254:1925).
        public static let cardFill = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                   light: Primitive.AlphaBlack.a7)
        public static let cardRadius = Radius.lg
        public static let cardHPadding: CGFloat = 14
        /// Собственного вертикального отступа у карточки почти нет — его несут
        /// сами ячейки, и от края карточки до первой строки ровно столько же,
        /// сколько между двумя строками внутри.
        public static let cardVPadding = Space.s2
        public static let divider = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                  light: Primitive.AlphaBlack.a7)
        /// `h-px` макета (254:1935) — точка, а не волосок в полточки.
        public static let dividerHeight: CGFloat = 1

        // MARK: Ячейка

        public static let cellVPadding = Space.s10
        /// Между тем, что настраивается, и тем, чем это делают.
        public static let cellGap = Space.s8
        /// Заголовок ячейки → его тихая вторая строка.
        public static let cellLineGap = Space.s2
        /// Ячейка во всю ширину (промпт, теги): заголовок → содержимое.
        public static let stackGap = Space.s8

        // MARK: Контролы правого слота

        /// Одна высота на все: выключатель, выбор, поле и кнопка обязаны стоять
        /// на одной линии, иначе строки настроек шатаются друг относительно друга.
        public static let controlHeight = Space.s32
        public static let controlRadius = Radius.xxs
        public static let controlHPadding = Space.s10
        public static let controlGap = Space.s8
        /// Поле и поле-команда — 164 в макете (254:1931). Не «сколько влезет»:
        /// правый край группы обязан остаться прямым, что бы в поле ни лежало.
        public static let fieldWidth: CGFloat = 164
        public static let fieldFill = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                    light: Primitive.AlphaBlack.a7)
        public static let fieldBorder = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                      light: Primitive.AlphaBlack.a7)
        /// Кнопка — заливка вдвое тише поля: у поля есть содержимое, у кнопки
        /// только слово (254:2156).
        public static let buttonFill = Primitive.ink(dark: Primitive.AlphaWhite.a5,
                                                     light: Primitive.AlphaBlack.a5)
        public static let buttonHoverFill = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                          light: Primitive.AlphaBlack.a10)

        /// Выключатель — 40 × 24, бегунок 20 (254:1998).
        public enum Switch {
            public static let width: CGFloat = 40
            public static let height = Space.s24
            public static let knob = Space.s20
            public static let padding = Space.s2
            public static let radius = Radius.full
            public static let offFill = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                      light: Primitive.AlphaBlack.a15)
            public static let onFill = Paint.Status.accent
            public static let knobFill = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a100)
        }

        /// Тег личного словаря — 254:2173.
        public enum Tag {
            public static let height = Space.s24
            public static let radius = Radius.xxs
            public static let hPadding = Space.s6
            public static let gap = Space.s2
            public static let listGap = Space.s4
            public static let fill = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                   light: Primitive.AlphaBlack.a10)
            public static let addBorder = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                        light: Primitive.AlphaBlack.a10)
        }

        // MARK: Paint

        public static let header = Primitive.ink(dark: Primitive.AlphaWhite.a30,
                                                 light: Primitive.AlphaBlack.a42)
        public static let title = Paint.Text.primary
        public static let subtitle = Primitive.ink(dark: Primitive.AlphaWhite.a40,
                                                   light: Primitive.AlphaBlack.a48)
        /// Вторая строка бывает пяти родов, и до 2026-08-20 все пять красились
        /// одним цветом — поэтому «Не запущен» читалось как справка.
        public static let subtitleValue = subtitle
        public static let subtitleProgress = Paint.Text.secondary
        public static let subtitleWarning = Paint.Status.warning
        public static let subtitleFailure = Paint.Status.record
        /// Галочка «сделано» — тихая. Акцент принадлежит несделанному.
        public static let check = subtitle
        public static let value = Paint.Text.primary
        /// Подсказка в поле и хвостовой глиф: крестик, шеврон, копирование.
        public static let controlHint = subtitle
        public static let buttonLabel = Paint.Text.primary
        /// Единственная кнопка строки, без которой настройка не работает.
        public static let buttonAccentFill = Paint.Status.accent
        public static let buttonAccentLabel = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a100)
        /// «Очистить» — единственное необратимое действие на этих экранах.
        public static let destructive = Paint.Status.destructive

        // MARK: Type

        public enum Typo {
            /// 17 / 24 — заголовок раздела.
            public static let page = Typography.Style(
                size: 17, lineHeight: 24, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 11 / 14 — заголовок группы. Тот же, что у даты в рельсе.
            public static let header = Sidebar.Typo.sectionHeader
            /// 13 / 16 — то, что настраивается.
            public static let title = Sidebar.Typo.navLabel
            /// 12 / **15** — тихая вторая строка ячейки.
            ///
            /// В макете 14 (254:1929), и это число, которого шрифт не умеет:
            /// SF Pro на 12 pt рисует строку 15 (⌈11.60⌉ + ⌈2.53⌉), а 14.13 —
            /// это его сырые метрики, которые Figma округляет вниз. Просить 14
            /// значит просить бокс теснее, чем ложится начертание, — то самое,
            /// что `testEveryRailStyleMeasuresTheLineHeightItDeclares` называет
            /// ошибкой. Цена — одна точка на ячейку с подписью: 53 вместо 52.
            public static let subtitle = Typography.Style(
                size: 12, lineHeight: 15, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 12 / 16 — всё, что стоит в правом слоте: значение, поле, кнопка.
            /// Один кегль, потому что читают их в паре с заголовком слева, а не
            /// друг с другом.
            public static let control = Typography.Style(
                size: 12, lineHeight: 16, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 13 / 16 — длинный текст в ячейке во всю ширину (промпт).
            public static let body = Sidebar.Typo.navLabel
        }
    }

    /// Раздел «Проекты» — Figma `projects` (254:3400).
    ///
    /// Хром страницы у него настроечный (`Settings.pageHPadding` и соседи): это
    /// одна и та же колонка панели, и заголовок 17 / 24 в ней стоит на том же
    /// месте. Своё здесь — сетка карточек, кнопка с белой заливкой и модалка;
    /// ни того, ни другого, ни третьего в приложении до сих пор не было.
    public enum Projects {

        // MARK: Сетка — 255:5081

        public static let columns = 2
        public static let gridGap = Space.s10
        /// Панель навигации → сетка.
        public static let barGap = Space.s16

        // MARK: Карточка — 255:5082

        /// Высота названа, а не выведена из содержимого: карточки стоят сеткой,
        /// и ряд, у которого высота от текста, ломает строй на первом же
        /// проекте без описания.
        public static let cardHeight: CGFloat = 156
        public static let cardRadius = Radius.md
        public static let cardHPadding = Space.s16
        public static let cardVPadding = Space.s12
        /// Заголовок → описание.
        public static let cardGap = Space.s8
        /// Сколько строк описания видно. Макет отводит ему 42 pt при строке 14
        /// (255:5089) — три строки, и обрезка тут не жадность, а строй: подпись
        /// внизу карточки обязана стоять на одной высоте у всех восьми.
        public static let aboutLines = 3
        public static let cardFill = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                   light: Primitive.AlphaBlack.a7)
        public static let cardHoverFill = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                        light: Primitive.AlphaBlack.a10)
        public static let title = Primitive.ink(dark: Primitive.AlphaWhite.a90,
                                                light: Primitive.AlphaBlack.a88)
        /// Насколько приглушена архивная карточка. Она стоит в конце сетки и
        /// обязана читаться как «убрано», но остаться нажимаемой: вернуть проект
        /// из архива можно только её меню.
        public static let archivedOpacity: Double = 0.45
        /// Описание и подпись — один тихий цвет на оба.
        public static let quiet = Primitive.ink(dark: Primitive.AlphaWhite.a40,
                                                light: Primitive.AlphaBlack.a48)

        // MARK: Кнопка действия — 255:5078

        /// Скругление 8, а не настроечные 6: у кнопок этого экрана свой размер
        /// (255:5078), и рядом с карточкой в 12 шесть читается как обрубок.
        public static let actionRadius = Radius.xs
        public static let actionHeight = Space.s32
        public static let actionHPadding = Space.s10
        /// Внутренний воздух вокруг надписи — макетный `px-[2px]`.
        public static let actionLabelInset = Space.s2
        /// Единственная заливка в приложении, которая инвертирует фон целиком.
        /// Акцентная (`Settings.buttonAccentFill`) здесь не подходит: на этом
        /// экране акцент один — «Новый проект», и синий он делит с тумблерами.
        public static let actionFill = Tokens.dual(dark: .white, light: .black)
        public static let actionLabel = Paint.Text.primaryInverse
        public static let quietActionLabel = quiet
        /// Заливка меню сортировки — тише кнопки, но не пустая: это выбор, а не
        /// действие (255:5132).
        public static let sortFill = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                   light: Primitive.AlphaBlack.a10)

        // MARK: Пусто — 255:5215

        public enum Empty {
            /// 36 pt — знак стоит один посреди панели, и это его размер, а не
            /// размер иконки в строке.
            public static let markSize: CGFloat = 36
            /// Знак → блок текста, блок текста → кнопка.
            public static let gap = Space.s24
            /// Заголовок → объяснение.
            public static let textGap = Space.s12
            /// Мера текста — 417 в макете (255:5215) при панели 577. Без неё
            /// объяснение растягивается во всю колонку и перестаёт читаться
            /// тремя короткими строками, ради которых его так и написали.
            public static let measure: CGFloat = 417
        }

        // MARK: Модалка — 261:9361

        public enum Modal {
            public static let width: CGFloat = 360
            /// 20 (261:9361). Числа нет в шкале скруглений, и это не описка
            /// макета: у плиты, которая накрывает окно, скругление окна, а не
            /// карточки. Стоит литералом, а не подгонкой из шкалы, чтобы шкала
            /// не выросла ради одного места.
            public static let radius: CGFloat = 20
            public static let padding = Space.s20
            /// Между шапкой, полями и подвалом — один шаг.
            public static let blockGap = Space.s20
            /// Подпись поля → само поле.
            public static let labelGap = Space.s6
            public static let fieldHeight = Space.s32
            public static let fieldRadius = Radius.xs
            public static let fieldHPadding = Space.s10
            public static let fieldVPadding = Space.s8
            /// Внутреннее поле `TextEditor`, которое он ставит сам.
            public static let editorInset: CGFloat = 5
            /// Высота поля описания названа макетом (261:10120).
            public static let editorHeight: CGFloat = 135
            /// Сколько знаков влезает в описание. Число из макета («0/200»);
            /// оно же и предел, а не только подсказка.
            public static let aboutLimit = 200
            public static let fill = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                   light: Primitive.AlphaBlack.a7)
            public static let border = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                     light: Primitive.AlphaBlack.a10)
            public static let plate = Tokens.dual(
                dark: NSColor(srgbRed: 16 / 255, green: 16 / 255, blue: 16 / 255, alpha: 0.96),
                light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96)
            )
            public static let label = Primitive.ink(dark: Primitive.AlphaWhite.a30,
                                                    light: Primitive.AlphaBlack.a42)
            /// Тень плиты — два слоя из макета (261:9361): широкий ореол и
            /// смещённый вниз. SwiftUI кладёт по одной тени на модификатор,
            /// поэтому их два и здесь.
            public static let haloRadius: CGFloat = 24
            public static let dropRadius: CGFloat = 16
            public static let dropY: CGFloat = 4
            public static let shadow = Tokens.dual(
                dark: NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 0.25),
                light: NSColor(calibratedWhite: 0, alpha: 0.18)
            )
            /// Затемнение под плитой. Плотнее, чем кажется нужным: фон здесь
            /// почти чёрный, и слабая вуаль на нём не читается вовсе — в макете
            /// за плитой карточки едва различимы.
            public static let scrim = Tokens.dual(
                dark: NSColor(calibratedWhite: 0, alpha: 0.6),
                light: NSColor(calibratedWhite: 0, alpha: 0.3)
            )
        }

        // MARK: Экран проекта — 256:6954 / 256:7467

        public enum Screen {
            /// Имя проекта → описание (256:7663).
            public static let headerGap = Space.s10
            /// Описание → «Показать больше».
            public static let aboutGap = Space.s12
            /// Мера текста шапки. 500 при колонке 577: описание проекта читают,
            /// а не сканируют, и строка в 577 для 13 pt длинна.
            public static let aboutMeasure: CGFloat = 500
            /// Сколько строк описания видно, пока не развернули.
            public static let aboutLines = 3
            /// Шапка → полоса вкладок.
            public static let tabsGap = Space.s40
            /// Полоса вкладок → список.
            public static let listGap = Space.s16
            /// Между вкладками. Двойка, а не восьмёрка: вкладки — один предмет
            /// с четырьмя положениями, а не четыре кнопки.
            public static let tabGap = Space.s2

            /// Оба списка — карточка настроек (`SettingsCard`): та же заливка 7 %,
            /// то же скругление 14, те же волосяные линии между строками. Поле
            /// по бокам разное и снято с макета.
            public static let meetingCardHPadding = Space.s16
            public static let personCardHPadding: CGFloat = 14
            /// Строка списка — 12 сверху и снизу (256:8832, 256:7571).
            public static let rowVPadding = Space.s12
            /// Между двумя строками текста внутри строки списка.
            public static let rowLineGap = Space.s2
            /// Между частями тихой строки: «Название · Вчера, 22 августа».
            public static let metaGap = Space.s4
            /// Мера строки-темы. Та же 500, что у описания.
            public static let rowMeasure: CGFloat = 500

            /// Между группами встреч.
            public static let groupGap = Space.s24
            /// Заголовок группы → её карточка.
            public static let groupHeaderGap = Space.s8
            /// Отступ заголовка группы слева — как у заголовка группы настроек.
            public static let groupHeaderInset = Space.s8

            /// Кружок человека — квадрат со скруглением 6, а не круг (256:7672).
            public static let avatarSide = Space.s32
            public static let avatarRadius = Radius.xxs
            public static let avatarGap = Space.s10
            public static let avatarFill = Primitive.ink(dark: Primitive.AlphaWhite.a5,
                                                         light: Primitive.AlphaBlack.a5)

            public static let rowHoverFill = Primitive.ink(dark: Primitive.AlphaWhite.a5,
                                                           light: Primitive.AlphaBlack.a5)
            public static let rowRadius = Radius.xs
        }

        // MARK: Решения и задачи — 297:25130 / 297:25206

        /// Карточка атомов устроена иначе, чем список встреч: строки разделены
        /// **воздухом, а не линиями** (297:25130 — `gap-16`, поля 14), потому что
        /// пункт бывает в четыре строки и волосяная линия между такими читается
        /// как таблица.
        public enum Atom {
            public static let cardPadding: CGFloat = 14
            public static let cardRadius = Radius.lg
            /// Между пунктами.
            public static let rowGap = Space.s16
            /// Маркер → текст, текст → хвостовые значки.
            public static let markerGap = Space.s10
            public static let markerSide = Space.s16
            /// Текст → чип ответственного.
            public static let chipGap = Space.s8
            /// Правое поле текста: он не должен доезжать до значков.
            public static let textInset = Space.s12
            /// Между хвостовыми значками.
            public static let actionGap = Space.s8
            /// Плюс → «Добавить…». **Тот же шаг, что у пункта**: строка
            /// добавления стоит на той же сетке, что и пункты над ней, и её
            /// текст обязан начинаться на одной с ними вертикали (297:25164,
            /// 297:25227 — обе `gap-[10px]` при значке в 16). Здесь стояло 6, и
            /// это была ошибка чтения, а не решение.
            public static let addGap = markerGap
            /// Заголовок группы → карточка; между группами.
            public static let groupHeaderGap = Space.s8
            public static let groupGap = Space.s24

            /// Сделанная задача — текст гаснет до 20 %, а не зачёркивается:
            /// зачёркнутое в четыре строки не читается вовсе.
            public static let doneText = Primitive.ink(dark: Primitive.AlphaWhite.a20,
                                                       light: Primitive.AlphaBlack.a28)
            /// Чип сделанной — тот же чип, приглушённый.
            public static let doneChipOpacity: Double = 0.4

            /// Чип ответственного — 297:25136.
            public enum Chip {
                public static let height = Space.s24
                public static let radius = Radius.xxs
                public static let hPadding = Space.s6
                public static let gap = Space.s4
                public static let fill = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                       light: Primitive.AlphaBlack.a10)
            }

            /// «+ Добавить ответственного» — 297:25147.
            ///
            /// Рост, скругление и боковое поле те же, что у чипа: кнопка встаёт
            /// на его место и обязана занимать его габарит. Разное — материал:
            /// у чипа заливка, здесь контур. Чип называет факт, кнопка просит
            /// действия, и одинаковая плотность слепила бы их в один ряд.
            public enum AddAssignee {
                public static let height = Chip.height
                public static let radius = Chip.radius
                public static let hPadding = Chip.hPadding
                /// Плюс → надпись. Уже чипового: там между именем и крестиком 4.
                public static let gap = Space.s2
                /// Воздух вокруг надписи внутри кнопки — макетный `px-[2px]`.
                public static let labelInset = Space.s2
                public static let border = Primitive.ink(dark: Primitive.AlphaWhite.a10,
                                                         light: Primitive.AlphaBlack.a10)
            }
        }

        // MARK: Type

        public enum Typo {
            /// 13 / 16 — имя проекта. Тот же кегль, что у названия встречи в
            /// рельсе: это то же самое — имя вещи, на которую нажимают.
            public static let title = Sidebar.Typo.navLabel
            /// 12 / **15** — описание и подпись карточки.
            ///
            /// В макете 14, и это то же число, которого шрифт не умеет, что и в
            /// настройках: SF Pro на 12 pt рисует строку 15. Просить 14 — просить
            /// бокс теснее начертания.
            public static let body = Settings.Typo.subtitle
            /// 12 / 16 — надписи кнопок и меню сортировки.
            public static let action = Settings.Typo.control
            /// 15 / 20 — заголовок модалки. Между заголовком раздела (17) и
            /// строкой (13): плита меньше страницы.
            public static let modalTitle = Typography.Style(
                size: 15, lineHeight: 20, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 11 / 14 — подпись над полем и счётчик знаков.
            public static let label = Sidebar.Typo.meta
            /// 17 / 24 — имя проекта на его экране. Тот же, что у заголовка
            /// раздела: это заголовок страницы и есть.
            public static let screenTitle = Settings.Typo.page
            /// 13 / 22 — описание проекта на его экране (256:7544). Кегель
            /// строки, интерлиньяж абзаца: это единственный на экране текст,
            /// который читают подряд.
            public static let screenBody = Typography.Style(
                size: 13, lineHeight: 22, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 11 / 14 — заголовок группы встреч. Тот же, что у даты в рельсе.
            public static let groupHeader = Sidebar.Typo.sectionHeader
        }
    }

    /// The one plate the app opens with — Figma `setup` (50:1223).
    ///
    /// It replaced six. What is left is what macOS itself has to be asked, and
    /// the sentence that says why; the calendar and the name moved into the rail
    /// (`RailPrompt`), where they cost nobody a screen.
    /// Экран пустого архива (`FirstRunView`). Свои числа, а не настроечные: это
    /// не плита в 500 pt, а окно целиком, и то, что на плите было полем, здесь
    /// стало бы дырой.
    public enum FirstRun {
        /// Крупнее, чем на плите настройки (20): там марка открывает короткую
        /// колонку, здесь — стоит одна посреди окна, и на этом расстоянии 20
        /// читается как значок, который забыли убрать.
        public static let markSize: CGFloat = 26
        /// Марка → заголовок. Шире настроечных 16 по той же причине.
        public static let markGap = Space.s28
        /// Заголовок → подзаголовок. Теснее соседних промежутков: это одна мысль
        /// в два голоса, а не два блока.
        public static let subtitleGap = Space.s20
        /// Подзаголовок → кнопка.
        public static let actionGap = Space.s28
        /// По бокам «Начать запись». Кнопка обнимает надпись, а не тянется.
        public static let actionHPadding = Space.s20
        /// Мера заголовка. Без неё он разъезжается на всю ширину окна в одну
        /// строку, и вопрос перестаёт читаться как вопрос.
        public static let measure: CGFloat = 420
    }

    public enum Setup {
        /// The plate grew with the centred layout (2026-08-07) so it reads as a
        /// relative of the first-run screen rather than a system alert. Two
        /// numbers, and both are safe to move: nothing here is a breakpoint, and
        /// `OnboardingPanelController` takes its content size from them.
        public static let width: CGFloat = 500
        /// Figma 130:2165 plus one row (2026-08-20: «Доступ к приложениям»).
        /// Adds up exactly: 58 + (20 mark + 16 + 78 headline) + 28 + 224 rows +
        /// 28 + (36 button + 8 + 28 caption) + 58 = 582.
        public static let height: CGFloat = 582
        /// The comps say 20; the plate takes the top step of the scale, which now
        /// sits at 14. The rule in this file is that an off-scale literal snaps
        /// rather than mints a step, and the whole scale tightening by 4 is a
        /// decision about corners in general — not something this one plate opts
        /// out of by keeping the drawn number.
        public static let radius = Radius.lg
        /// The plate has no titlebar row. Everything lives in one column inset
        /// from all four edges — mark, sentence, rows, and the button at the foot.
        ///
        /// Not square, and off the scale in both directions, because both numbers
        /// are load-bearing rather than decorative (Figma 130:2165 — the comp
        /// nests 50 + 20 to get the 70). The horizontal one sets the measure to
        /// 360, which is what breaks the headline into three short lines instead
        /// of two long ones; the vertical one is what makes the plate read as a
        /// card rather than a dialogue with its content against the walls.
        public static let insetH: CGFloat = 70
        public static let insetV: CGFloat = 58
        /// Mark → sentence. The mark is the opening of the sentence, not a block
        /// beside it, so this is the tightest gap in the column.
        public static let markGap = Space.s16
        /// Headline → rows, and rows → button: the same silence on both sides of
        /// the list, which is what lets the list read as the middle of three
        /// blocks rather than as a tail of the headline.
        public static let listGap = Space.s28
        /// Button → the line about the model. Eight, because the line is not a
        /// fourth block: it belongs to the button and says what pressing it does.
        public static let captionGap = Space.s8

        /// A permission row: 12 above and below its 32 pt content.
        public static let cellVPadding = Space.s12
        public static let cellHeight = Space.s32
        /// The grant pill and the switch share a column so the row does not shift
        /// when a pill becomes a tick.
        public static let controlWidth: CGFloat = 89
        public static let controlHeight = Space.s32
        public static let controlRadius = Radius.xxs
        public static let controlHPadding = Space.s10
        /// «Начать» — full width at the foot of the plate.
        public static let actionHeight: CGFloat = 36
        public static let actionRadius = Radius.xxs

        /// The mark opens the column — 20 pt, centred over the sentence it
        /// introduces. It shrank when the plate grew (Figma 130:2165) and that is
        /// the right way round: the bigger the plate, the more a large mark reads
        /// as a splash screen. It is not one; it is the signature on a short note.
        public static let markSize: CGFloat = 20
        /// Full-strength ink, like the sentence it introduces. The mark is part
        /// of what the plate says, not chrome around it — the 40 % it wore while
        /// it lived in a titlebar was the colour of a window control.
        public static let mark = Paint.Text.primary
        /// Seconds for one turn of the mark, counter-clockwise.
        ///
        /// Twelve, against the two seconds the nav row spins at. That one is a
        /// reaction to the pointer and stops when the pointer leaves; this one
        /// never stops, and anything quick enough to read as *motion* becomes a
        /// spinner — which would say the screen is waiting on something. It is
        /// not. It is a mark that happens to turn.
        public static let markTurn: Double = 12

        public static let title = Paint.Text.primary
        public static let cellTitle = Paint.Text.primary
        /// The quiet second line of a cell — 50 % in the comps, half a step under
        /// the rail's own 55 % because it sits directly under a 95 % line.
        public static let cellSubtitle = Primitive.ink(dark: Primitive.AlphaWhite.a50,
                                                       light: Primitive.AlphaBlack.a50)
        /// The line about the model, under the button — the app's own tertiary
        /// ink, which is already the 30 % the comp draws. A step quieter than a
        /// cell's second line: that one explains a control you are looking at,
        /// this one states a consequence you are not being asked about.
        public static let caption = Paint.Text.tertiary
        public static let controlFill = Paint.Bg.surface
        public static let controlHoverFill = Paint.Bg.selected
        public static let controlLabel = Paint.Text.primary

        public enum Typo {
            /// 22 / 26 semibold, −0.22 — the one sentence the plate makes.
            public static let title = Typography.Style(
                size: 22, lineHeight: 26, weight: .semibold,
                weightTrim: Typography.railWeightTrim
            )
            public static let titleTracking: CGFloat = -0.22
            /// 13 / 16 regular — both lines of a cell.
            public static let cell = Typography.Style(
                size: 13, lineHeight: 16, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 12 / 16 regular — «Разрешить». A step under the row it sits in:
            /// the row is the sentence, the pill is the answer to it.
            public static let grant = Typography.Style(
                size: 12, lineHeight: 16, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 13 / 16 — «Дальше». Same face as the row above it: the plate
            /// says which line is the answer by putting it in a control, not by
            /// weighting the words inside one.
            public static let action = cell
            /// The line about the model under the button — the rail's 11 / 14,
            /// not a style of its own. Same job in both places: the smallest,
            /// quietest thing on a surface, and one face for the whole app.
            public static let caption = Sidebar.Typo.meta
        }
    }

    /// The block that docks at the foot of the rail — Figma 91:794 / 91:882.
    ///
    /// Two questions that are not permissions, asked where the answer is visibly
    /// for something: the calendar, then the name. One at a time, with a «1/2»
    /// so the block says how long it is.
    public enum RailPrompt {
        public static let inset = Space.s12
        public static let bottomInset = Space.s12
        /// Comps say 20 — snapped, for the reason on `Setup.radius`.
        public static let radius = Radius.lg
        public static let padding = Space.s12
        /// Between the head (title / subtitle / counter) and the control.
        public static let blockGap = Space.s12
        /// Between the text block and the counter beside it.
        public static let counterGap = Space.s8
        public static let controlHeight: CGFloat = 36
        public static let controlRadius = Radius.xxs
        public static let controlHPadding = Space.s10
        /// The field's own inner inset, and the gap to the ⏎ glyph.
        public static let fieldTextInset = Space.s2
        public static let fieldGlyphGap = Space.s2
        public static let fieldGlyphSize: CGFloat = 13

        /// Blur behind the block, so the list reads through it as texture.
        public static let backdropBlur: CGFloat = 16

        /// Same wash as a selected row, over the blur. **Not** the comps' opaque
        /// `#101010 @ 92 %`: over Propeller's glass that would stop the window
        /// being a window exactly where the block sits.
        public static let fill = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                               light: Primitive.AlphaBlack.a7)
        public static let border = Sidebar.border
        public static let title = Sidebar.meetingTitle
        public static let subtitle = Setup.cellSubtitle
        public static let counter = Sidebar.meetingPreview
        public static let controlFill = Paint.Bg.surface
        public static let controlHoverFill = Paint.Bg.selected
        public static let controlLabel = Paint.Text.primary
        public static let fieldPlaceholder = Paint.Text.tertiary
        public static let fieldGlyph = Sidebar.chromeIcon

        public enum Typo {
            /// 13 / 16 regular — head lines, counter, and the button's label.
            public static let head = Setup.Typo.cell
            /// 14 / 18 regular — what is typed into the field, and its placeholder.
            public static let field = Sidebar.Typo.navLabel
        }
    }

    public enum Pill {
        public static let height: CGFloat = 36
        public static let hPadding: CGFloat = 14
        public static let vPadding: CGFloat = Space.s8
        public static let radius: CGFloat = Radius.full
        public static let iconGap: CGFloat = Space.s4
        public static let rowGap: CGFloat = Space.s8
    }

    /// Back-compat aliases — prefer `Tokens.Paint.Text.*`.
    public enum Ink {
        public static let primary = Paint.Text.primary
        public static let secondary = Paint.Text.secondary
        public static let tertiary = Paint.Text.tertiary
        public static let quaternary = Paint.Text.quaternary
    }

    // MARK: - 7. Typography
    // Three roles: Heading (titles), Label (UI), Body (reading: summary / transcript).

    public enum Typography {
        /// How much to take off the weight axis so AppKit's stem darkening
        /// stops out-inking the comps. See `Style.weightTrim`.
        ///
        /// Measured, not guessed, and it is worth knowing how little it buys:
        /// at identical size and glyph width, AppKit lays down **1.29×** the ink
        /// Figma does. This trim takes that to 1.25. The rest is not weight — it
        /// is grayscale antialiasing with stem darkening, which is what macOS
        /// does for light text in a transparent window and what every native app
        /// looks like. (Editors that look thinner — Cursor, VS Code — are
        /// Electron and rasterise text themselves.)
        ///
        /// Closing the remaining gap on this axis would need roughly −0.5, which
        /// is not a correction but a different face. Set this to 0 to see the
        /// system untouched.
        public static let railWeightTrim: CGFloat = -0.08

        public struct Style: Equatable, Sendable {
            public let size: CGFloat
            public let lineHeight: CGFloat
            public let weight: Font.Weight

            /// A nudge along SF Pro's continuous weight axis, on AppKit's
            /// −1…1 scale where regular is 0 and medium is 0.23.
            ///
            /// This is a *rasterisation* correction, not a type decision. Drawn
            /// at the same size and the same weight, AppKit lays down about 29 %
            /// more ink than Figma does — measured, at identical glyph widths —
            /// because light-on-dark text in a transparent window gets grayscale
            /// antialiasing with stem darkening, and Figma's rasteriser does
            /// not. The metrics are right and the colour is right; the strokes
            /// are simply fatter.
            ///
            /// Trimming the axis is the only lever that does not lie about the
            /// type: the style still says its named weight, and a hair comes
            /// off the stems to land where the design does. Set it to 0 to see
            /// exactly what the system would draw.
            public var weightTrim: CGFloat = 0

            public init(
                size: CGFloat,
                lineHeight: CGFloat,
                weight: Font.Weight,
                weightTrim: CGFloat = 0
            ) {
                self.size = size
                self.lineHeight = lineHeight
                self.weight = weight
                self.weightTrim = weightTrim
            }

            public var nsWeight: NSFont.Weight {
                switch weight {
                case .semibold: return .semibold
                case .medium: return .medium
                case .bold: return .bold
                case .light: return .light
                default: return .regular
                }
            }

            public var nsFont: NSFont {
                Typography.systemFont(
                    size: size, weight: nsWeight, weightTrim: weightTrim
                )
            }

            public var font: Font { Font(nsFont) }

            /// The line height text actually gets laid out at.
            ///
            /// CoreText rounds ascent and descent away from zero *before* adding
            /// them, so SF Pro at 12 pt draws a 15 pt line (⌈11.60⌉ + ⌈2.53⌉),
            /// not the 14.13 its raw metrics suggest. Deriving leading from the
            /// raw numbers overshoots by up to a point on every line — which is
            /// invisible on one label and a row and a half of drift down a list.
            public var renderedLineHeight: CGFloat {
                ceil(nsFont.ascender) + ceil(-nsFont.descender) + ceil(nsFont.leading)
            }

            /// Extra for SwiftUI `.lineSpacing` (may be negative when LH is tight).
            public var lineSpacingExtra: CGFloat { lineHeight - renderedLineHeight }

            /// Same face and size, more (or less) room between lines.
            ///
            /// A wrapping label needs a taller line box than the single-line one
            /// it shares a size with — the sidebar's 12 pt meeting titles run to
            /// three lines at 16 pt leading, the 12 pt nav labels never wrap.
            /// Re-leading beats minting `smMediumTall` next to `smMedium`.
            public func lineHeight(_ value: CGFloat) -> Style {
                Style(size: size, lineHeight: value, weight: weight, weightTrim: weightTrim)
            }

            /// Same size and leading, a different face weight. For the one place
            /// a label has to out-read its neighbour without changing size —
            /// «Вернуть» beside the time it replaces.
            public func weight(_ value: Font.Weight) -> Style {
                Style(size: size, lineHeight: lineHeight, weight: value,
                      weightTrim: weightTrim)
            }

            /// Same style, a nudge off the weight axis. See `weightTrim`.
            public func trimmed(_ trim: CGFloat) -> Style {
                Style(size: size, lineHeight: lineHeight, weight: weight,
                      weightTrim: trim)
            }
        }

        /// Titles. Semibold. One size — the only heading the app draws.
        public enum Heading {
            /// 36 / 34 (95%)
            public static let lg = Style(size: 36, lineHeight: 34, weight: .semibold)
        }

        /// UI copy — mostly single-line. One weight: regular.
        ///
        /// Medium is gone from the scale on purpose. It was carried by four
        /// steps and said nothing the colour ramp was not already saying: the
        /// search palette weighted its field, its result titles, its dates and
        /// its «Ничего не найдено» alike, which is a weight applied to a whole
        /// screen rather than to anything within it. Hierarchy here is colour
        /// and size; the one place that genuinely needs to out-read its
        /// neighbour still has `Style.weight(_:)` at the call site.
        public enum Label {
            /// 14 / 18
            public static let mdRegular = Style(size: 14, lineHeight: 18, weight: .regular)
            /// 12 / 16 — one leading for the 12 pt step.
            ///
            /// Was 12 / 14 beside a 12 / 16 minted by `.lineHeight(16)` in three
            /// places: the same size with two line boxes, chosen by whichever
            /// token a call site happened to reach for. The difference is
            /// invisible on one line and a wrap apart on two, so the taller box
            /// wins — it is the one the wrapping call sites needed.
            public static let smRegular = Style(size: 12, lineHeight: 16, weight: .regular)
            /// 10 / 12
            public static let xsRegular = Style(size: 10, lineHeight: 12, weight: .regular)

            /// Pill / CTA label — regular 14/18.
            public static let pill = mdRegular
        }

        /// Long-form reading: summary, transcript, notes. 14 / 22.
        public enum Body {
            public static let md = Style(size: 14, lineHeight: 22, weight: .regular)
        }

        fileprivate static func systemFont(
            size: CGFloat, weight: NSFont.Weight, weightTrim: CGFloat = 0
        ) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard weightTrim != 0 else { return base }
            // The weight trait is continuous on −1…1, so the axis can be
            // moved by less than the gap between two named weights.
            let desc = base.fontDescriptor.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue + weightTrim]
            ])
            return NSFont(descriptor: desc, size: size) ?? base
        }
    }
}

extension View {
    /// Apply a Propeller text style (font + line height).
    public func typo(
        _ style: Tokens.Typography.Style,
        monospacedDigit: Bool = false
    ) -> some View {
        let font = monospacedDigit ? style.font.monospacedDigit() : style.font
        return self
            .font(font)
            .lineSpacing(style.lineSpacingExtra)
    }

    /// `typo`, plus the height the style actually asks for.
    ///
    /// `.lineSpacing` puts space *between* lines and nothing around the block,
    /// so a label styled 12 / 16 measures 15 pt tall on one line and 47 on
    /// three — every block is short by exactly one `lineSpacingExtra`, whatever
    /// its line count. Left uncorrected, a meeting row comes out 50 pt instead
    /// of the designed 52, and eight of them drift the list by a row and a half.
    ///
    /// Splitting the shortfall above and below is what CSS calls half-leading,
    /// and it is what Figma's `leading-[16px]` does — so the first baseline
    /// lands where the comps put it, not two points high.
    ///
    /// Use this wherever the *box* matters: rows, list items, anything whose
    /// height is designed. Plain `typo` is still right for text that simply
    /// flows.
    public func typoBlock(
        _ style: Tokens.Typography.Style,
        monospacedDigit: Bool = false
    ) -> some View {
        typo(style, monospacedDigit: monospacedDigit)
            .padding(.vertical, max(0, style.lineSpacingExtra) / 2)
    }
}

/// The setup plate's headline, drawn through AppKit.
///
/// SwiftUI's `.lineSpacing` puts room *between* lines and cannot be told «26 pt
/// lines, whatever the face does» — which is what a wrapping 22 pt headline with
/// a designed line box needs. A paragraph style can, so the title goes through a
/// text field. Tracking rides along for the same reason: `.kern` is an attribute,
/// not a modifier.
enum SetupText {
    static func title(_ string: String, alignment: NSTextAlignment = .left) -> StyledLabel {
        let style = Tokens.Setup.Typo.title
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = style.lineHeight
        paragraph.maximumLineHeight = style.lineHeight
        paragraph.alignment = alignment
        return StyledLabel(attributed: NSAttributedString(string: string, attributes: [
            .font: style.nsFont,
            .paragraphStyle: paragraph,
            .kern: Tokens.Setup.Typo.titleTracking,
            // The pair, not a white: the plate follows the system theme like
            // everything else, and an `NSColor` literal here would not.
            .foregroundColor: Tokens.Primitive.inkNSColor(
                dark: Tokens.Primitive.AlphaWhite.a95,
                light: Tokens.Primitive.AlphaBlack.a92
            ),
        ]))
    }
}

struct StyledLabel: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = attributed
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = attributed
        field.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let proposed = proposal.width ?? .infinity
        let width = (proposed.isFinite && proposed > 0) ? proposed : nsView.intrinsicContentSize.width
        nsView.preferredMaxLayoutWidth = width
        let fit = nsView.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }
}
