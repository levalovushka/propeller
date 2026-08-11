import Foundation

/// # Что в микрофоне не объясняется дальней стороной
///
/// Гейт решает **до** отправки, текста у него ещё нет, а прежний вопрос «кто из
/// дорожек громче» отвечать не может: собственный голос владельца в его же
/// микрофоне на 4–6 dB тише эха дальней стороны (замер 2026-08-11,
/// `20260811_121526` и `20260811_114818`). Уровень тапа задаёт приложение
/// звонка, уровень микрофона — усиление входа; величины несравнимые.
///
/// Инвариантный к усилению вопрос — **предсказуем ли микрофон референсом**. Эхо
/// это задержанная и отфильтрованная комнатой копия системного стема, то есть
/// линейно с ним связанная; своя речь не связана ничем. Дорожки у нас выровнены
/// кадр в кадр (`ProcessTapCapture`), поэтому когерентность считать законно.
///
/// # Почему по ячейкам, а не по средней энергии
///
/// Одно число на окно не годится, и это замер, а не вкус. Доля энергии
/// микрофона, объяснённая референсом, на реальных встречах: чистое эхо 0.64,
/// эхо со своей речью на −5 dB — 0.57. Различить нельзя: среднее по энергии
/// определяют самые громкие ячейки, а они принадлежат эху.
///
/// Речь разрежена во времени и частоте, поэтому считать надо **ячейки**: доля
/// громких ячеек время-частота, у которых когерентности нет. На тех же данных
/// (окна 2 с, 711 окон с эхом, 124 чистых окна владельца):
///
/// | что в окне | доля громких ячеек без когерентности |
/// |---|---|
/// | только эхо | **0.05** (p90 0.31) |
/// | эхо + владелец −10 dB | 0.22 |
/// | эхо + владелец −5 dB | 0.29 |
/// | эхо + владелец 0 dB | 0.37 |
/// | только владелец | **0.74** |
///
/// Шестикратный разрыв между «только эхо» и рабочим уровнем двойного разговора —
/// это и есть сигнал, которого у сравнения громкостей не было.
///
/// # Чего этот тип **не** делает
///
/// Не подавляет эхо. Проверено на этих же стемах: когерентный постфильтр даёт
/// 8.8–10.3 dB подавления при потере 2.4 dB на своей речи — и движку это
/// безразлично, из подавленной дорожки распознаётся 95.4 % слов дальней стороны
/// против 97.5 % из исходной (замер 2026-08-11, `gigastt transcribe` по трём
/// дорожкам одного окна). Чтобы ASR замолчал, нужно 20–30 dB, а линейно на
/// реальной встрече столько не снять: когерентность в речевой полосе там ~0.5, а
/// не 0.91–0.97, как в пробе `tools/echo-probe` с тестовым сигналом. Поэтому
/// эхо здесь только **обнаруживается**, а с экрана его убирает `EchoDedup`.
public struct EchoCoherence: Sendable {

    /// Кадр 128 мс: задержка эха замерена в 30–34 мс (STATE.md M6), и окно должно
    /// быть заметно длиннее её, иначе задержанная копия попадает в соседний кадр
    /// и когерентности не видно.
    public static let frameCount = 2048
    /// Шаг 32 мс. Кадры перекрываются: на границе слова иначе теряется как раз то
    /// окно, ради которого всё считается.
    public static let hopCount = 512
    /// Память рекурсивного усреднения спектров. 0.75 — это ~4 кадра, 128 мс:
    /// столько живёт один слог, и дольше усреднять значит смазать двойной
    /// разговор в эхо.
    public static let smoothing: Float = 0.75
    /// Речевая полоса. Та же, в которой мерена когерентность захвата.
    public static let bandLowHz: Float = 200
    public static let bandHighHz: Float = 3500
    /// Ниже этой когерентности ячейка считается необъяснённой.
    public static let coherenceCeiling: Float = 0.3
    /// Во сколько раз ячейка должна быть громче медианы своего кадра, чтобы
    /// голосовать. Тише — это пол спектра, и он есть всегда.
    public static let loudFactor: Float = 4

    /// Сколько ячеек в порции голосовало и сколько из них дальняя сторона не
    /// объясняет. Счётчики, а не доля: решение принимается по **целой порции**
    /// (2 с), и складывать доли пятидесятимиллисекундных окон значило бы
    /// усреднять шум.
    public struct Cells: Equatable, Sendable {
        public let loud: Int
        public let unexplained: Int

        public static let none = Cells(loud: 0, unexplained: 0)

        public init(loud: Int, unexplained: Int) {
            self.loud = loud
            self.unexplained = unexplained
        }
    }

    private let bins: Range<Int>
    private let fft: RealFFT

    private var mic: [Float] = []
    private var system: [Float] = []
    private var sxx: [Float]
    private var syy: [Float]
    private var sxyRe: [Float]
    private var sxyIm: [Float]
    private var seeded = false
    /// Переиспользуется под медиану кадра: 423 значения тридцать раз в секунду —
    /// незачем каждый раз просить память.
    private var scratch: [Float] = []

    public init(sampleRate: Float = 16_000) {
        let resolution = sampleRate / Float(Self.frameCount)
        let low = max(1, Int((Self.bandLowHz / resolution).rounded()))
        let high = min(Self.frameCount / 2, Int((Self.bandHighHz / resolution).rounded()))
        bins = low..<max(low + 1, high)
        fft = RealFFT(count: Self.frameCount)
        let half = Self.frameCount / 2 + 1
        sxx = [Float](repeating: 0, count: half)
        syy = [Float](repeating: 0, count: half)
        sxyRe = [Float](repeating: 0, count: half)
        sxyIm = [Float](repeating: 0, count: half)
        scratch.reserveCapacity(bins.count)
    }

    /// Очередная порция захвата, обе дорожки одного кадра.
    ///
    /// Возвращает голоса завершившихся кадров. Пустой ответ — обычное дело: до
    /// первого полного кадра и на каждой порции, которой не хватило шага.
    public mutating func note(mic newMic: [Float], system newSystem: [Float]) -> Cells {
        // Системной дорожки нет вовсе (микрофонный путь) — сравнивать не с чем, и
        // молчать об этом нельзя: гейт обязан считать, что замера не было.
        guard !newSystem.isEmpty, newMic.count == newSystem.count else { return .none }
        mic.append(contentsOf: newMic)
        system.append(contentsOf: newSystem)

        var loud = 0
        var unexplained = 0
        while mic.count >= Self.frameCount {
            let frame = tally()
            loud += frame.loud
            unexplained += frame.unexplained
            mic.removeFirst(Self.hopCount)
            system.removeFirst(Self.hopCount)
        }
        return Cells(loud: loud, unexplained: unexplained)
    }

    public mutating func reset() {
        mic.removeAll(keepingCapacity: true)
        system.removeAll(keepingCapacity: true)
        for i in sxx.indices {
            sxx[i] = 0; syy[i] = 0; sxyRe[i] = 0; sxyIm[i] = 0
        }
        seeded = false
    }

    // MARK: - Один кадр

    private mutating func tally() -> Cells {
        let x = fft.spectrum(of: Array(system[0..<Self.frameCount]))
        let y = fft.spectrum(of: Array(mic[0..<Self.frameCount]))

        let alpha = Self.smoothing
        for i in bins {
            let px = x.re[i] * x.re[i] + x.im[i] * x.im[i]
            let py = y.re[i] * y.re[i] + y.im[i] * y.im[i]
            // Взаимный спектр: Y · conj(X).
            let re = y.re[i] * x.re[i] + y.im[i] * x.im[i]
            let im = y.im[i] * x.re[i] - y.re[i] * x.im[i]
            if seeded {
                sxx[i] = alpha * sxx[i] + (1 - alpha) * px
                syy[i] = alpha * syy[i] + (1 - alpha) * py
                sxyRe[i] = alpha * sxyRe[i] + (1 - alpha) * re
                sxyIm[i] = alpha * sxyIm[i] + (1 - alpha) * im
            } else {
                sxx[i] = px; syy[i] = py; sxyRe[i] = re; sxyIm[i] = im
            }
        }
        seeded = true

        scratch.removeAll(keepingCapacity: true)
        for i in bins { scratch.append(syy[i]) }
        scratch.sort()
        let median = scratch[scratch.count / 2]
        guard median > 0 else { return .none }
        let threshold = median * Self.loudFactor

        var loud = 0
        var unexplained = 0
        for i in bins where syy[i] > threshold {
            loud += 1
            let denominator = sxx[i] * syy[i]
            let coherence = denominator > 0
                ? (sxyRe[i] * sxyRe[i] + sxyIm[i] * sxyIm[i]) / denominator
                : 0
            if coherence < Self.coherenceCeiling { unexplained += 1 }
        }
        return Cells(loud: loud, unexplained: unexplained)
    }
}

/// Спектр действительного сигнала. Своя реализация, а не Accelerate: тип живёт в
/// `PropellerPure`, где всё должно быть проверяемо тестом и одинаково считаться
/// в приложении и на стенде, а стоит это 11 тысяч операций на кадр — тридцать
/// кадров в секунду на две дорожки.
struct RealFFT {
    struct Spectrum {
        var re: [Float]
        var im: [Float]
    }

    private let count: Int
    private let levels: Int
    private let window: [Float]
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    init(count: Int) {
        precondition(count > 0 && count & (count - 1) == 0, "радикс-2 требует степень двойки")
        self.count = count
        levels = Int(log2(Double(count)))
        // Ханн: без окна утечка соседних бинов сама создаёт «когерентность».
        window = (0..<count).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(count)) }
        cosTable = (0..<count / 2).map { cos(2 * .pi * Float($0) / Float(count)) }
        sinTable = (0..<count / 2).map { sin(2 * .pi * Float($0) / Float(count)) }
        var reversed = [Int](repeating: 0, count: count)
        for i in 0..<count {
            var value = 0
            var index = i
            for _ in 0..<levels {
                value = (value << 1) | (index & 1)
                index >>= 1
            }
            reversed[i] = value
        }
        self.reversed = reversed
    }

    /// Бины 0…count/2 включительно. Остальные — зеркало, и спрашивать их незачем.
    func spectrum(of samples: [Float]) -> Spectrum {
        precondition(samples.count == count)
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        for i in 0..<count { re[reversed[i]] = samples[i] * window[i] }

        var size = 2
        while size <= count {
            let half = size / 2
            let step = count / size
            for start in stride(from: 0, to: count, by: size) {
                var twiddle = 0
                for i in start..<(start + half) {
                    let j = i + half
                    let c = cosTable[twiddle]
                    let s = -sinTable[twiddle]
                    let tre = re[j] * c - im[j] * s
                    let tim = re[j] * s + im[j] * c
                    re[j] = re[i] - tre
                    im[j] = im[i] - tim
                    re[i] += tre
                    im[i] += tim
                    twiddle += step
                }
            }
            size <<= 1
        }
        return Spectrum(re: Array(re[0...count / 2]), im: Array(im[0...count / 2]))
    }
}
