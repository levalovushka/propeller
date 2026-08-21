import Foundation

/// # Кто подписал конспект переполняющей встречи — модель или код
///
/// Документ длинной встречи пишет **единый автор**: свод модели из собранных
/// фактов (решение владельца 2026-08-15, `tools/recap-lab/OPTIMIZATION.md`,
/// «Финал»). Связность — свойство одного автора: покрытие суммируется из
/// пунктов, читаемость — нет, и три независимых сигнала (суд читаемости 2,10
/// против 3,25, релизное решение 14.08, глаза владельца на макетах 15.08)
/// сказали одно и то же про сборку из фрагментов.
///
/// Но у свода есть режим схлопывания, ради которого сборку и вводили (A5.1):
/// `13k-h` отдал 4 пункта против 9 у механики, `13k-b` — 5 против 8. Поэтому
/// сборка остаётся — **невидимой линейкой и запасным выходом**: она считается
/// на тех же фактах, читателю не показывается и забирает документ, только если
/// свод объективно пуст.
///
/// Два условия отбирают документ у автора, и оба — про потерю, не про вкус:
///
/// - **свод схлопнут после ретрая** — порог токенов (`recapMinReplyTokens`,
///   800). Он и делает основную работу: оба случая A5.1 пришли на 351 и 465
///   токенов, то есть были бы пойманы им и без второго условия;
/// - **в своде меньше половины пунктов сборки**
///   (`RecapGenerationPolicy.digestMinBulletShare`) — вторая сеть, для ответа,
///   который длину набрал и содержание всё равно выбросил.
///
/// Почему доля именно половина, а не две трети как у `RecapLint.Shape`: сборка —
/// не эталон документа, а свалка находок. На живой фикстуре
/// (`Tests/Fixtures/recap-assembly/expected-live.md`, одна встреча) она даёт 14
/// буллетов, а автор сливает близкие формулировки и часть находок уносит в
/// прозу «Итога» — насколько ниже при этом падает его счёт, **не замерено**.
/// Строгий порог на неизмеренной величине отбирал бы документ у автора на
/// здоровых прогонах, то есть отменял бы само решение.
public enum RecapDigestGuard {

    /// Кто написал документ, который уехал читателю.
    public enum Author: String, Equatable, Sendable {
        /// Свод модели — счастливый путь, у документа есть «Итог».
        case digest
        /// Механическая сборка `RecapAssembly` — страховка.
        case assembly
    }

    /// Почему сборка отобрала документ — короткое слово, а не фраза.
    ///
    /// Отдельно от `reason`: тот пишется человеку в лог и несёт числа
    /// («в своде 3 пунктов против 14 в сборке»), то есть в телеметрии дал бы
    /// новое значение почти на каждой встрече. Калибруется же ровно одна из
    /// причин — `bulletShare`; без этого разреза «сборка победила N раз» не
    /// говорит, трогать ли порог.
    public enum Cause: String, Equatable, Sendable {
        /// Свода нет вовсе: модель не ответила или ответ пуст.
        case digestEmpty
        /// Порог токенов — свод остался коротким и после повтора.
        case collapsed
        /// `digestMinBulletShare` — длину набрал, содержание выбросил.
        case bulletShare
    }

    public struct Decision: Equatable, Sendable {
        public let author: Author
        public let recap: String
        /// Почему сборка отобрала документ у автора. `nil` — автор победил.
        public let reason: String?
        /// То же самое словом из закрытого списка — для телеметрии. `nil` там же,
        /// где `nil` у `reason`.
        public let cause: Cause?

        public init(
            author: Author, recap: String, reason: String?, cause: Cause? = nil
        ) {
            self.author = author
            self.recap = recap
            self.reason = reason
            self.cause = cause
        }
    }

    /// `collapsed` — итог политики ретрая (`CallStats.collapsed`), то есть
    /// «схлопнут **после** повтора». Схлопнувшийся первый ответ, который повтор
    /// починил, документа не теряет.
    public static func decide(digest: String, collapsed: Bool, assembly: String) -> Decision {
        let digestText = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        let assemblyText = assembly.trimmingCharacters(in: .whitespacesAndNewlines)

        func fallback(_ reason: String, _ cause: Cause) -> Decision {
            // Отбирать документ нечем: сборка пуста. Тогда свод — единственное,
            // что есть, и пустоту дальше по конвейеру ловит `emptyResponse`.
            guard !assemblyText.isEmpty else {
                return Decision(author: .digest, recap: digestText, reason: nil)
            }
            return Decision(
                author: .assembly, recap: assemblyText, reason: reason, cause: cause
            )
        }

        if digestText.isEmpty { return fallback("свод пуст", .digestEmpty) }
        if collapsed { return fallback("свод схлопнут после ретрая", .collapsed) }

        let digestBullets = RecapLint.shape(of: digestText).bullets
        let assemblyBullets = RecapLint.shape(of: assemblyText).bullets
        if assemblyBullets > 0,
           Double(digestBullets) < RecapGenerationPolicy.digestMinBulletShare * Double(assemblyBullets) {
            return fallback(
                "в своде \(digestBullets) пунктов против \(assemblyBullets) в сборке",
                .bulletShare
            )
        }

        return Decision(author: .digest, recap: digestText, reason: nil)
    }
}
