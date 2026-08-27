import Foundation

/// # Ряды состава встречи — Figma `summary/participants` (285:19438)
///
/// Один ответ на вопрос «кого показать под чипом „6 человек“», собранный из
/// четырёх источников разной надёжности. Здесь он потому, что «в списке
/// оказался лишний человек» проверяется тестом, а не разговором.
///
/// ## Ряд — это «кого слышали», а не «кто был»
///
/// Решение владельца 2026-08-27: **список именно про участников; приглашённые
/// значения не имеют и годятся только как запасной способ брать имена.** Это
/// отменяет `plan-people.md` §4.2, где «был» = приглашённые минус вычеркнутые,
/// и цена названа: Ц3 и Ц4 теряют дармовое покрытие на двух третях архива,
/// потому что состав теперь непуст только там, где кого-то назвал журнал,
/// диаризация или человек руками.
///
/// Замер, ради которого правило именно такое (149 транскриптов живого архива,
/// 27 авг): приглашённых 601 на 68 встречах против 381 подписи ленты, и на 50
/// встречах приглашённых **больше**, чем подписей. Показать оба списка значит
/// показать «Полину» и `Speaker 3`, которые вполне могут быть одним человеком:
/// 561 ряд там, где людей вчетверо меньше.
///
/// ## Лестница
///
/// | # | источник | что даёт |
/// |---|---|---|
/// | 1 | владелец | ряд всегда и первым, удалить нельзя |
/// | 2 | плитки звонилки (`CallWindowJournal.roster`) | самый надёжный: 68 живых имён на 19 трассах |
/// | 3 | подписи ленты | имена и **кластеры**: `Speaker 2` — тоже ряд, за ним живой человек |
/// | 4 | руками | добавленные и убранные |
/// | 5 | приглашённые | ряды **только** если шаги 2–4 не дали ничего, кроме владельца |
///
/// Пятая ступень — тот случай, ради которого владелец просил приглашённых
/// оставить: из звонилки не приехало ничего. Когда кластеры есть, приглашённые
/// остаются **кандидатами** (`candidates`), а не рядами: так они попадают
/// внутрь строки-плейсхолдера, и выбор там переписывает ленту
/// (`AppState.reassignSegments`) — чего плоский список приглашённых не умеет.
///
/// ## Чего эта сборка не делает
///
/// - **Не сшивает имя с его переводом.** Свёртка `PersonCanon` соединит
///   «Марину» и «Marina», но «Александр» и «Alexander» — нет, это перевод
///   имени, а не написание. Такое сшивает человек.
/// - **Второе устройство владельца остаётся лишним рядом.** Замер 2026-08-20
///   (трасса `213214`): ноутбук и телефон дают две плитки, «Levon Lobanov» и
///   «Лева Ловушка», и вторая не совпадает ни с именем владельца, ни с его
///   Zoom-именем. Ряд честно убирается руками — и убранное запоминается, иначе
///   он вернулся бы после каждой пересборки.
/// - **Не считает, сколько людей молчало.** У молчавшего следа нет по
///   определению (`plan-people.md` §3.1), и число рядов — это число тех, за кем
///   есть хоть один след.
public enum MeetingRoster {

    /// Откуда ряд взялся. Не для показа — для решений: кандидат не предлагается
    /// дважды, а число в чипе считает ряды, а не источники.
    public enum Origin: String, Equatable, Sendable, Codable {
        /// Владелец. Ровно один такой ряд, и он первый.
        case owner
        /// Плитка в окне звонилки.
        case call
        /// Подпись расшифровки, и это имя, а не заглушка.
        case spoken
        /// Кластер без имени (`Speaker 2`, «Собеседник») — живой человек, чьего
        /// имени мы не знаем.
        case cluster
        /// Добавлен человеком.
        case manual
        /// Приглашённый из календаря. Ряд только на пятой ступени.
        case invited
    }

    public struct Row: Equatable, Sendable, Identifiable {
        /// Написание, которым его показывают.
        public let name: String
        public let origin: Origin
        /// Подпись в ленте, которую этот ряд представляет. По ней «подписать
        /// одним движением» знает, какие реплики переписать
        /// (`AppState.reassignSegments`). nil — ряду в ленте не соответствует
        /// ничего: так выглядит добавленный руками участник, который не говорил.
        public let label: String?

        public var id: String { (label ?? "") + "\u{1}" + name }
        /// Владельца из состава встречи не убирают: без него «я сделаю» теряет
        /// исполнителя (`plan-people.md` §6).
        public var isRemovable: Bool { origin != .owner }

        public init(name: String, origin: Origin, label: String?) {
            self.name = name
            self.origin = origin
            self.label = label
        }
    }

    /// Всё, из чего собирается состав одной встречи. Тексты уже прочитаны —
    /// ходить на диск это место не умеет.
    public struct Input: Equatable, Sendable {
        /// Имена плиток звонилки, от тяжёлых к легким (`CallWindowJournal.roster`).
        public var call: [String]
        /// Подписи ленты, включая плейсхолдеры
        /// (`RecapDocument.participants` их выбрасывает, поэтому не она).
        public var spoken: [String]
        /// `CalendarMeta.attendees`.
        public var invited: [String]
        /// `Preferences.ownerName`. Пустое — законное состояние: человек мог не
        /// проходить вопрос об имени.
        public var ownerName: String
        /// `Preferences.ownerZoomName` — как владелец назвал себя в звонилке.
        /// Без него его же плитка становится отдельным участником: свёртка
        /// «Levon Lobanov» и «Левон» не соединяет, и это замер, а не догадка —
        /// в каждой из 19 трасс лежит первое, а в префах второе.
        public var ownerZoomName: String?
        /// Что человек добавил руками.
        public var added: [String]
        /// Что человек убрал руками — ключи рядов (`MeetingRoster.key`).
        public var removed: [String]

        public init(
            call: [String] = [],
            spoken: [String] = [],
            invited: [String] = [],
            ownerName: String = "",
            ownerZoomName: String? = nil,
            added: [String] = [],
            removed: [String] = []
        ) {
            self.call = call
            self.spoken = spoken
            self.invited = invited
            self.ownerName = ownerName
            self.ownerZoomName = ownerZoomName
            self.added = added
            self.removed = removed
        }
    }

    /// Ключ ряда: у имени — свёртка `PersonCanon`, у плейсхолдера — сама подпись.
    ///
    /// Ключи разные, потому что свёртка выбрасывает цифры: `Speaker 2` и
    /// `Speaker 3` сложились бы в один `speaker`, и убранный второй кластер
    /// уносил бы третий вместе с собой.
    public static func key(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SourceAwareSpeaker.isPlaceholder(trimmed)
            ? trimmed.lowercased()
            : PersonCanon.fold(trimmed)
    }

    /// Годятся ли приглашённые этой встречи хоть на что-нибудь.
    ///
    /// Порог — `MeetingHotwords.maximumAttendees`, а не своё число: «рассылка, а
    /// не встреча» — одна идея, и второй константы на неё в этом коде быть не
    /// должно. `plan-people.md` §7.1 называет границу «больше восьми», хотовордам
    /// шипнули двенадцать; расхождение выбрано в пользу уже работающего, и
    /// сторона ошибки безопасная — кандидат это предложение, а не утверждение.
    /// В живом архиве порог отсекает 4 встречи из 53, включая приглашение на
    /// 107 адресов.
    public static func invitedUsable(_ invited: [String]) -> Bool {
        !invited.isEmpty && invited.count <= MeetingHotwords.maximumAttendees
    }

    /// Состав встречи рядами.
    public static func rows(_ input: Input) -> [Row] {
        var out: [Row] = []
        var index: [String: Int] = [:]

        // Владелец: имя для показа и всё, что в данных его означает.
        let given = input.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerDisplay = given.isEmpty ? SourceAwareSpeaker.defaultOwnerName : given
        var ownerKeys: Set<String> = [
            key(ownerDisplay), key(SourceAwareSpeaker.defaultOwnerName),
        ]
        if let zoom = input.ownerZoomName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !zoom.isEmpty {
            ownerKeys.insert(key(zoom))
        }
        // Владельца вычеркнуть нельзя — значит и попытка вычеркнуть его молча
        // не действует, а не роняет ряд.
        let removed = Set(input.removed.map(key)).subtracting(ownerKeys)

        // Какой подписью ленты представлен ключ. Первая встреченная: лента
        // упорядочена, и первая подпись человека — та, под которой его найдут
        // глазами раньше всего.
        var labelOf: [String: String] = [:]
        for label in input.spoken {
            let k = key(label)
            guard !k.isEmpty, labelOf[k] == nil else { continue }
            labelOf[k] = label.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Слова состава звонилки → участник, если слово принадлежит ровно
        // одному (`PersonCanon.soleOwners`). Так «Полина» из ленты сходится с
        // «Polina Kremenets» из плитки, чего свёртка целого имени не умеет.
        //
        // **Плитки здесь авторитет, а лента и добавленное сверяются с ними** — и
        // асимметрия обязательна: у симметричного правила ответа нет вовсе,
        // потому что «Полина» с равным правом и «Polina Kremenets», и другая
        // Полина. Без трассы (96 % встреч, замер по телеметрии) сверять не с
        // чем, и тогда имена не склеиваются вообще — это верная сторона ошибки.
        let anchors = PersonCanon.soleOwners(roster: input.call)

        /// Ключ ряда-плитки, за которым стоит это имя, если такой ровно один.
        func anchor(_ name: String) -> String? {
            var hit: String?
            for word in PersonCanon.words(of: name) {
                guard let owner = anchors[PersonCanon.fold(word)] else { continue }
                let ownerKey = key(owner)
                // Два разных участника претендуют на одно имя — не наш случай.
                if let hit, hit != ownerKey { return nil }
                hit = ownerKey
            }
            return hit
        }

        /// - Parameter spellingWins: перебивает ли этот источник уже
        ///   записанное написание. Побеждает лента: канон — то, что читатель
        ///   найдёт в расшифровке глазами (то же правило, что у `PersonCanon` и
        ///   `ProjectRoster`).
        func offer(_ raw: String, origin: Origin, label: String?, spellingWins: Bool) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            var k = key(name)
            if index[k] == nil, !SourceAwareSpeaker.isPlaceholder(name),
               let anchored = anchor(name) {
                k = anchored
            }
            guard !k.isEmpty, !removed.contains(k) else { return }
            if let at = index[k] {
                let known = out[at]
                out[at] = Row(
                    name: spellingWins ? name : known.name,
                    origin: known.origin,
                    label: known.label ?? label
                )
                return
            }
            index[k] = out.count
            out.append(Row(name: name, origin: origin, label: label))
        }

        // 1. Владелец — всегда и первым. Его подпись в ленте ставит микрофон,
        //    факт сильнее всего остального.
        let ownerLabel = ownerKeys.compactMap { labelOf[$0] }.first
        for k in ownerKeys { index[k] = 0 }
        out.append(Row(name: ownerDisplay, origin: .owner, label: ownerLabel))

        // 2. Плитки звонилки. Порядок их — по весу, и он сохраняется.
        for name in input.call {
            offer(name, origin: .call, label: labelOf[key(name)], spellingWins: false)
        }

        // 3. Лента: имена и кластеры. Кластер — такой же ряд: за ним живой
        //    человек, чьего имени мы не знаем, а спросили «сколько», не «кто».
        for label in input.spoken {
            let placeholder = SourceAwareSpeaker.isPlaceholder(label)
            offer(
                label,
                origin: placeholder ? .cluster : .spoken,
                label: label,
                spellingWins: !placeholder
            )
        }

        // 4. Руками. Добавленный человек — ряд без подписи в ленте: он был, но
        //    его речь не атрибутирована. Связывание — отдельное действие.
        for name in input.added {
            offer(name, origin: .manual, label: nil, spellingWins: true)
        }

        // 5. Приглашённые — только когда показывать больше нечего.
        if out.count == 1, invitedUsable(input.invited) {
            for name in input.invited {
                offer(name, origin: .invited, label: nil, spellingWins: false)
            }
        }

        return out
    }

    /// Кого предложить, когда человек называет кластер или добавляет участника.
    ///
    /// Здесь приглашённые и работают: не рядом, а предложением. Уже стоящие в
    /// составе не предлагаются — выбрать человека, который уже в списке, значит
    /// склеить два ряда, и это другое действие.
    ///
    /// `known` — люди из остального архива («с кем созванивался раньше»); их
    /// собирает вызывающий, потому что для этого нужен весь архив.
    public static func candidates(_ input: Input, known: [String] = []) -> [String] {
        let taken = Set(rows(input).map { key($0.name) })
        var out: [String] = []
        var seen = Set<String>()
        for raw in (invitedUsable(input.invited) ? input.invited : []) + known {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(name)
            guard !name.isEmpty, !k.isEmpty, !taken.contains(k),
                  !SourceAwareSpeaker.isPlaceholder(name), seen.insert(k).inserted
            else { continue }
            out.append(name)
        }
        return out
    }
}
