import Foundation

/// Куда на общей шкале ложится очередной буфер захвата.
///
/// # Почему не «просто дописать в конец»
///
/// Ровно так и делалось, и это стоило нам эхоподавления. Буферы
/// ScreenCaptureKit складывались подряд, как будто ни один не опоздал и ни один
/// не пропал; когерентность дорожек в речевой полосе вышла **0.04** при 0.70 у
/// синтетики с идеальным выравниванием. Контроль показал причину: та же
/// синтетика с дрожанием ±3 мс даёт 0.01. То есть дописывание в конец само по
/// себе и есть дрожание — оно накапливает каждый пропущенный кадр как сдвиг
/// всего, что дальше (`docs/ECHO_AND_MIX_EXPERIMENTS.md`, дефект M6).
///
/// Теперь у каждого буфера есть `mSampleTime` часов агрегата, и место кадра
/// считается от него, а не от того, сколько мы успели записать.
///
/// # Почему один курсор на обе дорожки
///
/// Потому что дорожка теперь одна — микрофон и тап приходят одним буфером
/// одного устройства. Раздельные курсоры смогли бы разъехаться, а нам нужно,
/// чтобы это было невыразимо.
public struct CapturePlacement: Equatable {

    /// Сколько кадров тишины дописать перед буфером: столько часы насчитали,
    /// а мы не получили.
    public let silenceFrames: Int
    /// Сколько кадров отрезать с начала буфера: этот кусок уже записан.
    public let skipFrames: Int
    /// Сколько кадров буфера реально пойдёт на диск.
    public let writeFrames: Int
    /// Шкалу пришлось привязать заново — часы прыгнули так, что доверять
    /// разнице нельзя (перезапуск устройства, смена агрегата).
    public let reanchored: Bool

    public init(silenceFrames: Int, skipFrames: Int, writeFrames: Int, reanchored: Bool) {
        self.silenceFrames = silenceFrames
        self.skipFrames = skipFrames
        self.writeFrames = writeFrames
        self.reanchored = reanchored
    }

    /// Идеальный случай: буфер встал ровно туда, куда часы и обещали.
    public var isContinuous: Bool {
        silenceFrames == 0 && skipFrames == 0 && !reanchored
    }

    /// Ничего писать не надо — буфер целиком дубль уже записанного.
    public var isEmpty: Bool { writeFrames == 0 && silenceFrames == 0 }
}

/// Позиция записи на общей шкале, в кадрах от первого захваченного кадра.
public struct CaptureCursor {

    /// Дальше какого расхождения разница между часами и записью перестаёт быть
    /// пропуском и становится враньём. Пропуск в пару секунд бывает по-честному
    /// (устройство переподключилось), десять минут — нет: значит часы
    /// перезапустились с нуля, и добивать это тишиной означало бы вписать в
    /// запись десять минут, которых не было.
    public static let maxPadSeconds: Double = 30

    public private(set) var framesWritten: Int = 0
    /// `mSampleTime`, которого мы ждём от следующего буфера. Nil до первого.
    public private(set) var expectedSampleTime: Double?
    /// Сколько раз шкалу пришлось привязывать заново. Ноль — здоровая запись;
    /// это же число уезжает в отчёт, потому что «сколько раз за встречу поехали
    /// часы» — вопрос, на который до сих пор отвечать было нечем.
    public private(set) var reanchorCount: Int = 0
    /// Сколько кадров тишины дописано за пропуски. Прямая мера того, сколько
    /// звука встречи мы не получили.
    public private(set) var paddedSilenceFrames: Int = 0
    /// Сколько кадров отброшено как повтор.
    public private(set) var droppedOverlapFrames: Int = 0

    private let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 1
    }

    /// Пропуск/наложение меньше полукадра — это округление, а не событие.
    private static let tolerance: Double = 0.5

    /// Куда положить буфер, начинающийся в `sampleTime` и длиной `frameCount`.
    ///
    /// Курсор двигается сам: вызов и есть запись.
    public mutating func place(sampleTime: Double, frameCount: Int) -> CapturePlacement {
        guard frameCount > 0 else {
            return CapturePlacement(silenceFrames: 0, skipFrames: 0, writeFrames: 0, reanchored: false)
        }
        guard sampleTime.isFinite else {
            // Часов у буфера нет — дописываем в конец и честно помечаем это
            // как привязку заново: тишина лучше, чем сдвиг всего дальнейшего.
            return appendBlind(frameCount: frameCount)
        }

        guard let expected = expectedSampleTime else {
            // Первый буфер задаёт нулевую отметку записи.
            expectedSampleTime = sampleTime + Double(frameCount)
            framesWritten += frameCount
            return CapturePlacement(
                silenceFrames: 0, skipFrames: 0, writeFrames: frameCount, reanchored: false
            )
        }

        let delta = sampleTime - expected

        if abs(delta) < Self.tolerance {
            expectedSampleTime = sampleTime + Double(frameCount)
            framesWritten += frameCount
            return CapturePlacement(
                silenceFrames: 0, skipFrames: 0, writeFrames: frameCount, reanchored: false
            )
        }

        if delta > 0 {
            let gap = Int(delta.rounded())
            guard Double(gap) <= Self.maxPadSeconds * sampleRate else {
                return appendBlind(frameCount: frameCount, sampleTime: sampleTime)
            }
            paddedSilenceFrames += gap
            framesWritten += gap + frameCount
            expectedSampleTime = sampleTime + Double(frameCount)
            return CapturePlacement(
                silenceFrames: gap, skipFrames: 0, writeFrames: frameCount, reanchored: false
            )
        }

        // Наложение: часть буфера (или он весь) описывает уже записанное время.
        let overlap = Int((-delta).rounded())
        guard overlap < frameCount else {
            // Буфер целиком в прошлом. Если он там *далеко* — часы прыгнули
            // назад, и продолжать по ним нельзя.
            if Double(overlap) > Self.maxPadSeconds * sampleRate {
                return appendBlind(frameCount: frameCount, sampleTime: sampleTime)
            }
            droppedOverlapFrames += frameCount
            return CapturePlacement(
                silenceFrames: 0, skipFrames: frameCount, writeFrames: 0, reanchored: false
            )
        }
        droppedOverlapFrames += overlap
        let write = frameCount - overlap
        framesWritten += write
        expectedSampleTime = sampleTime + Double(frameCount)
        return CapturePlacement(
            silenceFrames: 0, skipFrames: overlap, writeFrames: write, reanchored: false
        )
    }

    /// Заново привязать шкалу к текущему концу записи: дальше считаем от него.
    /// Это делает и явный перезапуск захвата (сменилось устройство вывода), и
    /// прыжок часов, которому нельзя верить.
    public mutating func reanchor() {
        expectedSampleTime = nil
        reanchorCount += 1
    }

    /// Вставить в запись честный пропуск — столько времени захват не работал.
    /// Возвращает количество кадров, чтобы вызывающий записал ровно столько
    /// тишины: без этого всё, что после перезапуска, уехало бы влево.
    @discardableResult
    public mutating func padGap(seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let frames = min(Int((seconds * sampleRate).rounded()), Int(Self.maxPadSeconds * sampleRate))
        paddedSilenceFrames += frames
        framesWritten += frames
        return frames
    }

    private mutating func appendBlind(frameCount: Int, sampleTime: Double? = nil) -> CapturePlacement {
        reanchorCount += 1
        expectedSampleTime = sampleTime.map { $0 + Double(frameCount) }
        framesWritten += frameCount
        return CapturePlacement(
            silenceFrames: 0, skipFrames: 0, writeFrames: frameCount, reanchored: true
        )
    }
}
