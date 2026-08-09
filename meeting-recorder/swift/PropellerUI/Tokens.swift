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
            public static let a68: Double = 0.68
            public static let a70: Double = 0.70
            public static let a80: Double = 0.80 // glass wash
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
            /// Поездка окна. Единственное, что двигает сам корпус.
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
        /// Окно едет само — за заметками, и обратно.
        ///
        /// Своя длительность и своя кривая, потому что у AppKit'овского
        /// `setFrame(animate:)` их нет: он считает время от величины прыжка и
        /// ведёт кадр линейно, а линейное движение окна в 280 pt читается как
        /// рывок. Замедление в конце — то, из-за чего край окна кажется
        /// тяжёлым, а не дёрганым.
        public static let windowResize = Step.t320
        /// Кнопка на месте ушедшей колонки. Позже окна на полкорпуса: она
        /// появляется в опустевшем слоте, а не летит вместе с ним.
        public static let notesButtonFade = Step.t180

        /// Как заметки приезжают и уезжают относительно самого окна.
        ///
        /// Не в такт с ним, и это главное. Окно и колонка — два разных события:
        /// сначала появляется место, потом то, что в нём стоит; на обратном
        /// пути наоборот — сначала текст уходит, и только потом край окна
        /// доезжает до кнопки. В такт они читались бы как одно движение,
        /// вскрывающее текст, — то есть как шторка.
        ///
        /// Считано так, чтобы приезд заканчивался **позже** остановки окна, а
        /// уход — **раньше** её; за этим следит `NotesChoreographyTests`.
        public static let notesInkFade = Step.t180
        /// Пауза от начала поездки до начала проявления. Окно успевает открыть
        /// больше половины пути пустым.
        public static let notesInkDelay = Step.t180
        /// И фора чернилам на обратном пути: окно трогается, когда текста уже
        /// почти нет.
        public static let notesInkLead = Step.t120
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
            /// Общий такт. Пепел, слот и соседи стартуют и заканчивают вместе.
            public static let duration = Step.t550

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
    }

    public enum Window {
        public static let contentWidth: CGFloat = 640
        /// Narrowest the content pane may get. The rail adds its own 300 on top
        /// — the window minimum is the sum, derived rather than restated.
        public static let contentPaneMinWidth: CGFloat = 480
        /// Opening pane width — notes stay a button. Must stay below
        /// `Pane.notesCollapseBelow` (760); wider than Figma `thin` (601) so
        /// the summary still reads. ~920 window with the rail.
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
        public static let trafficLightLeading: CGFloat = Space.s24
        public static let trafficLightSpacing: CGFloat = Space.s20
        public static let topBarHeight: CGFloat = 56
        public static let titleBlockHeight: CGFloat = 100
        public static let sectionStackGap: CGFloat = Space.s24
        public static let sectionInnerGap: CGFloat = Space.s8
        public static let rowRadius: CGFloat = Radius.md
        public static let updatePillHeight: CGFloat = Space.s32
        public static let updatePillHPadding: CGFloat = Space.s10
    }

    /// The left rail — Figma `sidebar / Frame 127` (31:4581).
    ///
    /// Every number here was measured off that frame; the comment on each says
    /// where it comes from, because "300" and "11" are the kind of value that
    /// gets rounded to something tidier by the next person who reads it.
    public enum Sidebar {

        // MARK: Layout

        /// Rail width. The content pane is whatever is left.
        public static let width: CGFloat = 300
        public static let minWidth: CGFloat = 240
        public static let maxWidth: CGFloat = 420
        /// Titlebar row: traffic lights and the collapse toggle on the left, search
        /// on the right.
        public static let headerHeight: CGFloat = 48
        /// Inset of that row. Read by the window too, which draws the toggle at
        /// `Tokens.Window.chromeToggleLeading` — one number, so the button cannot
        /// land beside the slot instead of after it.
        public static let headerPadding = Space.s12
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
        /// Between dated meeting groups (`gap-24`).
        public static let groupGap = Space.s24
        /// Soft alpha fade at the top of the meeting list once scrolled — mask
        /// height, not a painted wash. Zero while parked at the top.
        public static let listTopFade = Space.s24
        /// Soft alpha fade at the foot of the meeting list — always on. When a
        /// docked prompt is present the clear zone under this fade grows to the
        /// prompt's measured height; the fade itself stays this tall.
        public static let listBottomFade: CGFloat = 36

        /// Nav rows — `list-item`, h-32 rounded-8.
        public static let navRowHeight = Space.s32
        /// One point less than the meeting rows': the SF Symbol sits about a
        /// point inside its 16 pt box, so 13 puts the *glyph* on the same
        /// margin as the meeting titles below. Snapping this to a round number
        /// of the scale visibly stairsteps the two blocks against each other.
        public static let navRowHPadding: CGFloat = 13
        public static let navRowGap = Space.s4
        public static let navIconSide = Space.s16
        /// Point size of the SF Symbol inside that 16 pt box — the *ink*, not
        /// the box. Measured against the comps: 12 puts the magnifier at 12 × 12.
        public static let navIconSize: CGFloat = 12
        /// Same, for the collapse toggle (`sidebar.left` inks 14 × 11).
        public static let chromeIconSize: CGFloat = 12
        /// `Button text` wrapper — px-2 inside the row.
        public static let navLabelInset = Space.s2

        /// Micro-actions revealed on a meeting row's hover — `state=hover`
        /// (14:3174). Two 16 pt slots, 8 apart, at the trailing end of the time
        /// line. The comps drew `square.and.arrow.down` and `trash`; only the
        /// trash is left — revealing a file is not a routine act on a row.
        public static let rowActionSlot = Space.s16
        public static let rowActionGap = Space.s8
        public static let rowActionIconSize: CGFloat = 12

        /// Meeting rows — `meetingitem`, py-10 rounded-8, 4 pt between lines.
        ///
        /// 14 across, against the comps' 12, for the reason on `bodyHPadding`:
        /// the row keeps the text where it was and takes the two points the
        /// rail's margin gave up, so its fill is wider than its type.
        public static let meetingHPadding: CGFloat = 14
        public static let meetingVPadding = Space.s12
        public static let meetingLineGap = Space.s4
        /// Date header block — inset with the rows it heads, 22 pt from the top
        /// of the date to the top of the first meeting under it.
        public static let sectionHeaderBlockHeight: CGFloat = 22
        /// What is left of that block once the line has taken its share.
        ///
        /// Derived rather than stated as 8, so changing the header's type moves
        /// the gap instead of growing the group — which is how a one-point line
        /// box turns into a one-point shift of every dated section below it.
        public static var sectionHeaderBottomGap: CGFloat {
            max(0, sectionHeaderBlockHeight - Typo.sectionHeader.lineHeight)
        }

        public static let rowRadius = Radius.xs
        /// Meeting rows keep a fuller corner than nav / chrome — one step above
        /// `rowRadius`, so the list item reads softer than the controls around it.
        public static let meetingRadius = Radius.md
        /// Collapse toggle — 32×32 rounded-8, icon 16.
        public static let toggleSide = Space.s32
        public static let toggleIconSide = Space.s16

        /// Traffic-light slot: 76×32 at (12, 8); discs Ø12 at x 24/44/64,
        /// centred on y 24. `SceneWindowChrome` moves the real window buttons here.
        public static let trafficLightSlotWidth: CGFloat = 76
        public static let trafficLightLeading = Space.s24
        public static let trafficLightSpacing = Space.s20
        public static let trafficLightDiameter = Space.s12
        /// Top of the discs, from the top of the window.
        public static let trafficLightTop: CGFloat = 18

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
        /// Selected row wash — white 5 % in Figma.
        public static let rowSelected = Primitive.ink(dark: Primitive.AlphaWhite.a5,
                                                      light: Primitive.AlphaBlack.a5)
        /// Hover. Not in the comps — half of `rowSelected`, so that pointing at a
        /// row can never be mistaken for having chosen it.
        public static let rowHover = Primitive.ink(dark: Primitive.AlphaWhite.a3,
                                                   light: Primitive.AlphaBlack.a3)

        /// Nav label and its icon — one colour, they always move together.
        public static let navLabel = Primitive.ink(dark: Primitive.AlphaWhite.a55,
                                                   light: Primitive.AlphaBlack.a58)
        public static let navLabelSelected = Primitive.ink(dark: Primitive.AlphaWhite.a95,
                                                           light: Primitive.AlphaBlack.a92)
        /// Shortcut hint, revealed on hover.
        public static let navShortcut = Primitive.ink(dark: Primitive.AlphaWhite.a30,
                                                      light: Primitive.AlphaBlack.a42)

        /// «17:30 · 45 мин».
        public static let meetingMeta = Primitive.ink(dark: Primitive.AlphaWhite.a55,
                                                      light: Primitive.AlphaBlack.a55)
        /// The meeting's name — the loud half of the title line.
        public static let meetingTitle = Primitive.ink(dark: Primitive.AlphaWhite.a95,
                                                       light: Primitive.AlphaBlack.a92)
        /// What it was about — the quiet half.
        public static let meetingPreview = Primitive.ink(dark: Primitive.AlphaWhite.a55,
                                                         light: Primitive.AlphaBlack.a55)
        /// «Вчера, 24 августа».
        public static let sectionHeader = Primitive.ink(dark: Primitive.AlphaWhite.a30,
                                                        light: Primitive.AlphaBlack.a42)
        /// Collapse toggle glyph.
        public static let chromeIcon = Primitive.ink(dark: Primitive.AlphaWhite.a40,
                                                     light: Primitive.AlphaBlack.a48)
        /// Brightest point of the processing sweep, painted over `meetingPreview`.
        public static let shimmerPeak = Primitive.ink(dark: Primitive.AlphaWhite.a75,
                                                      light: Primitive.AlphaBlack.a55)

        // MARK: Type

        /// Not `Type` — that spelling collides with metatype syntax at every use site.
        public enum Typo {
            /// 14 / 18 regular — nav row label.
            ///
            /// Same face as the meeting title below it. The rail therefore has
            /// one text size and one weight, and everything is said with colour.
            public static let navLabel = Typography.Style(
                size: 14, lineHeight: 18, weight: .regular,
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
            /// 14 / 18 regular — meeting title + preview, wraps to three lines.
            ///
            /// Same Style as `navLabel`: one face for the whole rail. The line
            /// box is what the rows are built on (padding + N × 18).
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

        /// Soft typewriter on the phase line («Расшифровываем…» → «Суммируем…»).
        /// Shorter than the summary column — statuses are a few words.
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

    
    /// The bar that docks at the foot of the rail — Figma 53:2664.
    ///
    /// Its own group rather than a `Sidebar.*` prefix: a toast is an app-wide
    /// idea that happens to be drawn here first. The older 280 pt card that the
    /// four content-pane alerts used (`Tokens.Toast`, `PropellerToast`) is gone —
    /// they all dock here now, one at a time, out of one queue.
    public enum ToastBar {
        /// Inset from the rail's edges — `left 12, bottom 16` in the comps.
        public static let inset = Space.s12
        public static let bottomInset = Space.s16
        public static let radius = Radius.sm
        /// `pl-12 pr-8` — the trailing side is tighter because a 32 pt
        /// button already carries its own optical margin.
        public static let leadingPadding = Space.s12
        public static let trailingPadding = Space.s8
        public static let vPadding = Space.s10
        /// Text block's own inset inside the bar.
        public static let textInset = Space.s8
        public static let lineGap = Space.s2
        public static let actionGap = Space.s4
        public static let leadingSlot = Space.s16
        /// Blur behind the bar, so the list reads through it as texture.
        public static let backdropBlur: CGFloat = 16

        public static let actionHeight = Space.s32
        public static let actionHPadding = Space.s10
        public static let actionRadius = Radius.xxs
        public static let closeSide = Space.s32
        public static let closeRadius = Radius.xs

        public static let fill = Primitive.ink(dark: Primitive.AlphaWhite.a5,
                                               light: Primitive.AlphaBlack.a5)
        public static let border = Sidebar.border
        public static let title = Sidebar.meetingTitle
        public static let subtitle = Sidebar.meetingPreview
        public static let actionFill = Primitive.ink(dark: Primitive.AlphaWhite.a7,
                                                     light: Primitive.AlphaBlack.a7)
        public static let actionHoverFill = Primitive.ink(dark: Primitive.AlphaWhite.a12,
                                                          light: Primitive.AlphaBlack.a10)
        public static let actionLabel = Sidebar.navLabelSelected
        public static let closeIcon = Sidebar.chromeIcon

        /// 14 / 18 regular — the message.
        public static let titleType = Sidebar.Typo.meetingTitle
        /// 12 / 16 regular — the supporting line, when there is one.
        public static let subtitleType = Typography.Label.smRegular.lineHeight(16)
        /// 12 / 16 medium — the action's label. The one place in the rail
        /// that still uses medium: it is a button, and it has to out-weigh
        /// the sentence it sits beside.
        public static let actionType = Typography.Label.smRegular.lineHeight(16)
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
        /// Room under the last line so a scrolled summary is not hard against
        /// the window edge.
        public static let summaryBottomPadding = Space.s40
        /// Between the lead block and each section.
        public static let summaryBlockGap = Space.s24
        /// Inside a block: title (lead or section heading) to the text under it.
        /// Off the scale — the comps' 7, plus eight so a heading has a clear beat
        /// before the body or bullets that follow.
        public static let summaryLineGap: CGFloat = 7 + Space.s8
        public static let summaryMinWidth: CGFloat = 520
        /// A measure, not a container: past ~640 pt a 14 pt line stops being
        /// comfortable to read, however much room the window has.
        public static let summaryMaxWidth: CGFloat = 640
        /// Bullet indent and the space between list items.
        public static let bulletIndent: CGFloat = 21
        public static let bulletGap = Space.s16

        // MARK: Transcript column (32:5278)

        /// Between remarks. Generous on purpose — a transcript is scanned for
        /// who said what, and the gap is what makes the turns findable.
        public static let transcriptTurnGap = Space.s24
        /// Speaker line to its text.
        public static let transcriptLineGap = Space.s2
        /// Speaker to timecode.
        public static let transcriptMetaGap = Space.s8
        /// Fixed, so the timecodes form a column instead of drifting with names.
        public static let transcriptTimeWidth: CGFloat = 40
        /// Насколько плашка заметки вылезает за её текст.
        ///
        /// Наружу, а не внутрь: заметка стоит в ленте между репликами, и её
        /// строки обязаны начинаться там же, где их строки. Плашка с внутренним
        /// отступом сдвинула бы абзац вправо — подсветка ценой столбца.
        /// Горизонтально шире, чем вертикально, потому что по вертикали её
        /// держат ещё и зазоры между репликами.
        public static let transcriptNotePlateBleedH = Space.s12
        public static let transcriptNotePlateBleedV = Space.s8

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

        // MARK: Notes column (31:4652)

        public static let notesHPadding = Space.s8
        public static let notesVPadding = Space.s10
        public static let notesMinWidth: CGFloat = 240
        /// And a ceiling. The comps give the notes 268 at a 788 pt pane and 280
        /// at 800 — they take the leftover *up to a point*. Without the cap a
        /// wide window hands the notes everything and leaves the summary in its
        /// 520 against the left edge, which is not "centred" by any reading.
        public static let notesMaxWidth: CGFloat = 280
        /// What the notes shrink to when there is no room for the column —
        /// `notes-block` state `*-hidden`, a 52 × 52 button.
        public static let notesCollapsedSide: CGFloat = 52
        /// The summary keeps this much while the notes are open. Measured
        /// across the comps: the column is 520 at both 788 and 800 pt of pane,
        /// and the notes take whatever is left (268 and 280). Below
        /// `summaryMinWidth + notesMinWidth` the notes collapse instead of
        /// squeezing the text — at 601 the comps give the summary 549 and the
        /// notes a button.
        public static let notesCollapseBelow: CGFloat = summaryMinWidth + notesMinWidth
        /// Одна заметка — плашка, буквально строка встречи под ховером: тот же
        /// оттенок, то же скругление, те же отступы, что у групп настроек
        /// (`Settings.plateFill`). Не «похожая», а та же — в одном окне две
        /// разные плашки читаются как два разных приложения.
        ///
        /// До этого заметки были голым текстом с отступами, и подряд идущие
        /// короткие записи сливались в один абзац: где кончилась одна и
        /// началась вторая, было видно только по смыслу.
        public static let notePlateFill = Sidebar.rowHover
        public static let noteRadius = Sidebar.meetingRadius
        public static let noteHPadding = Sidebar.meetingHPadding
        public static let noteVPadding = Sidebar.meetingVPadding
        /// Между плашками. Меньше их внутреннего отступа: зазор обязан читаться
        /// как шов между двумя записями, а не как ещё одна пустая строка.
        public static let noteGap = Space.s8
        /// Шапка колонки: «Заметки» и кнопка, которая её убирает. Высоту задаёт
        /// кнопка, а не заголовок, — иначе 32 pt иконки распирали бы 22 pt
        /// строки и зазор до первой плашки поехал бы.
        public static let notesHeaderHeight = headerButtonSide
        /// Отступ заголовка слева. Как в настройках, чуть меньше внутреннего
        /// отступа плашки: совпадение до пикселя склеило бы их в один блок.
        public static let notesHeaderLeadingInset = Space.s12
        /// Сколько колонка не доезжает до своего места, пока окно едет.
        ///
        /// Одна ширина плашечного отступа. Без неё колонку просто открывал
        /// движущийся край окна — шторка: текст стоит, а по нему ползёт вырез.
        /// Со сдвигом она приезжает вместе с краем и на последних точках
        /// становится на место сама.
        public static let notesArrivalShift = Space.s12

        // MARK: Paint

        public static let title = Sidebar.navLabelSelected
        public static let meta = Sidebar.meetingMeta
        public static let body = Sidebar.navLabelSelected
        public static let placeholder = Sidebar.sectionHeader
        public static let buttonIcon = Sidebar.chromeIcon

        // MARK: The summary as an editor

        /// `body`, for the text storage — see `Primitive.inkNSColor`.
        public static let bodyNSColor = Primitive.inkNSColor(
            dark: Primitive.AlphaWhite.a95, light: Primitive.AlphaBlack.a92
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
            public static let label = Sidebar.navLabelSelected
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
        /// same corner, same drop, and the rows are the rail's own rows at the
        /// rail's own width. So there are only three numbers here — the ones that
        /// are about walking a list rather than about being a summoned tool.
        public enum Switcher {
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
            /// 14 / 18 regular — the meeting's name in the pane header.
            public static let headerTitle = Sidebar.Typo.meetingTitle
            /// 20 / 26 semibold, −0.1 tracking — the one-sentence summary.
            public static let lead = Typography.Style(
                size: 20, lineHeight: 26, weight: .semibold,
                weightTrim: Typography.railWeightTrim
            )
            public static let leadTracking: CGFloat = -0.1
            /// 14 / 22 regular — everything that is read rather than scanned.
            public static let body = Typography.Style(
                size: 14, lineHeight: 22, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
            /// 14 / 22 bold, −0.14 — a section heading inside the summary.
            public static let sectionTitle = Typography.Style(
                size: 14, lineHeight: 22, weight: .bold,
                weightTrim: Typography.railWeightTrim
            )
            public static let sectionTracking: CGFloat = -0.14
            /// 14 / 18 regular — a note.
            public static let note = Sidebar.Typo.meetingTitle
            /// 11 / 14 regular — «Заметки» over the column. The rail's date
            /// header, sideways: same face, same job, same quiet.
            public static let notesHeader = Sidebar.Typo.sectionHeader
            /// 11 / 14 regular — the speaker and timecode over a remark.
            public static let transcriptMeta = Sidebar.Typo.meta
            /// Реплика — тем же кеглем, что и саммари.
            ///
            /// Было 12 / 18, «транскрипт длинный, его просматривают». Отменено:
            /// один и тот же текст теперь живёт в двух местах — живой строкой во
            /// время встречи и расшифровкой после, — и переход между ними при
            /// разном кегле читается как перерисовка встречи, а не как её
            /// уточнение. Читаемость важнее компактности: это речь, а не список.
            public static let transcriptBody = body
            /// 12 / 16 regular — «Добавьте заметку…».
            public static let notePlaceholder = Typography.Style(
                size: 12, lineHeight: 16, weight: .regular,
                weightTrim: Typography.railWeightTrim
            )
        }
    }

    /// Настройки — состояние правой панели, а не отдельное окно.
    ///
    /// Ширина у них саммарийная, и это не совпадение: это та же колонка панели,
    /// просто с другим содержимым, — те же поля, тот же потолок измерения и то
    /// же центрирование в остатке. Число здесь ровно одно (`editorMinHeight`),
    /// всё остальное — псевдонимы к уже нарисованному.
    ///
    /// Группа устроена как день в рельсе: тихий заголовок 11 / 14 и ряд ячеек
    /// под ним. Плашки нет намеренно — иерархия расстоянием и типографикой, а не
    /// рамками (`design/principles.md` §5, PR-005).
    public enum Settings {

        // MARK: Column — мерка саммари

        public static let hPadding = Pane.summaryHPadding
        public static let topPadding = Pane.summaryVPadding
        public static let bottomPadding = Pane.summaryBottomPadding
        public static let maxWidth = Pane.summaryMaxWidth
        /// Тот же пол, что у саммари. Ниже него колонка не сжимается — панель
        /// отдаёт свой минимум (`Window.contentPaneMinWidth`), а не текст.
        public static let minWidth = Pane.summaryMinWidth

        // MARK: Groups

        /// Между группами — тот же шаг, что между днями в рельсе.
        public static let groupGap = Sidebar.groupGap
        /// Заголовок группы → её плашка. Выведен, а не назван: правка кегля
        /// заголовка двигает зазор, а не растит группу.
        public static var headerBottomGap: CGFloat {
            max(0, Sidebar.sectionHeaderBlockHeight - Typo.header.lineHeight)
        }
        /// Отступ заголовка слева. Чуть меньше внутреннего отступа плашки (14):
        /// заголовок стоит *над* ней, а не в ней, и совпадение до пикселя
        /// склеило бы их в один блок.
        public static let headerLeadingInset = Space.s12

        /// Плашка группы — буквально строка встречи под ховером: тот же оттенок,
        /// то же скругление, тот же горизонтальный отступ. Не «похожая», а та же:
        /// список настроек и список встреч живут в одном окне, и две разные
        /// плашки в нём читались бы как два разных приложения.
        public static let plateFill = Sidebar.rowHover
        public static let plateRadius = Sidebar.meetingRadius
        public static let plateHPadding = Sidebar.meetingHPadding
        /// Волосяная линия между ячейками. Собственного вертикального отступа у
        /// плашки нет — его несут сами ячейки, поэтому от края плашки до первой
        /// строки ровно столько же, сколько у строки встречи.
        public static let divider = Sidebar.border

        // MARK: Cells

        public static let cellVPadding = Sidebar.meetingVPadding
        /// Между тем, что настраивается, и тем, чем это делают.
        public static let cellGap = Space.s16
        /// Заголовок ячейки → его тихая вторая строка.
        public static let cellLineGap = Space.s2
        /// Заголовок → элемент, который стоит **под** ним: поле, редактор, путь.
        public static let stackGap = Space.s8
        /// Столбец управления: выключатель и всплывающий список обязаны стоять
        /// на одной высоте, иначе строки настроек шатаются друг относительно друга.
        public static let controlHeight = Space.s32

        // MARK: Fields

        public static let fieldHeight = Space.s32
        public static let fieldRadius = Radius.xxs
        public static let fieldHPadding = Space.s10
        public static let fieldFill = Paint.Bg.surface
        public static let fieldBorder = Sidebar.border
        /// Промпт — единственное поле, которое читают целиком, а не правят
        /// одним словом. Высота фиксирована, а не растёт по содержимому: промпт
        /// длиной в экран утащил бы вниз всё, что под ним, а дальше он всё
        /// равно скроллится внутри себя.
        public static let editorHeight: CGFloat = 400

        // MARK: Buttons — пилюля установочной плашки, та же самая

        public static let buttonHeight = Setup.controlHeight
        public static let buttonRadius = Setup.controlRadius
        public static let buttonHPadding = Setup.controlHPadding
        public static let buttonFill = Setup.controlFill
        public static let buttonHoverFill = Setup.controlHoverFill
        public static let buttonLabel = Setup.controlLabel

        // MARK: Paint

        public static let header = Sidebar.sectionHeader
        public static let title = Sidebar.meetingTitle
        public static let subtitle = Setup.cellSubtitle
        /// То, что настройка сообщает, а не спрашивает: версия, движок, объём.
        public static let value = Sidebar.meetingMeta

        // MARK: Type

        public enum Typo {
            /// 11 / 14 — заголовок группы. Тот же, что у даты в рельсе.
            public static let header = Sidebar.Typo.sectionHeader
            /// 14 / 18 — то, что настраивается.
            public static let title = Sidebar.Typo.navLabel
            /// 13 / 16 — тихая вторая строка ячейки.
            public static let subtitle = Setup.Typo.cell
            /// 14 / 18 — показание справа и текст в поле: и то и другое читают
            /// в паре с заголовком слева, значит кегль у них общий.
            public static let value = Sidebar.Typo.navLabel
            public static let field = Sidebar.Typo.navLabel
            public static let button = Setup.Typo.grant
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
        /// Figma 130:2165. Adds up exactly: 58 + (20 mark + 16 + 78 headline) +
        /// 28 + 168 rows + 28 + (36 button + 8 + 28 caption) + 58 = 526.
        public static let height: CGFloat = 526
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
            /// 13 / 16 medium — «Дальше», the only weighted label on the plate.
            public static let action = cell.weight(.medium)
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

        /// Titles. Semibold. LH% 95→105 as size drops.
        public enum Heading {
            /// 36 / 34 (95%)
            public static let lg = Style(size: 36, lineHeight: 34, weight: .semibold)
            /// 28 / 28 (~100%)
            public static let md = Style(size: 28, lineHeight: 28, weight: .semibold)
            /// 22 / 23 (105%)
            public static let sm = Style(size: 22, lineHeight: 23, weight: .semibold)
        }

        /// UI copy — mostly single-line. Regular or medium.
        public enum Label {
            /// 14 / 18
            public static let mdRegular = Style(size: 14, lineHeight: 18, weight: .regular)
            public static let mdMedium = Style(size: 14, lineHeight: 18, weight: .medium)
            /// 12 / 14
            public static let smRegular = Style(size: 12, lineHeight: 14, weight: .regular)
            public static let smMedium = Style(size: 12, lineHeight: 14, weight: .medium)
            /// 10 / 12
            public static let xsRegular = Style(size: 10, lineHeight: 12, weight: .regular)
            public static let xsMedium = Style(size: 10, lineHeight: 12, weight: .medium)

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
