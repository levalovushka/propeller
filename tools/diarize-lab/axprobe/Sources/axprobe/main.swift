// axprobe — отдаёт ли клиент Zoom список участников и активного спикера через
// «Универсальный доступ» (Accessibility, AX).
//
// Зачем. Granola на macOS подписывает реплики именами, читая активного спикера
// прямо из окна Zoom Workplace через это разрешение — без API, без роли хоста,
// без облака (docs.granola.ai, «Speaker tags in Zoom»). Если у нас так же
// получится, это закрывает и кластеризацию, и наименование сразу: Zoom — 33 из 37
// встреч архива с известной платформой. Пробу надо было завести до любых выводов,
// потому что заявление конкурента — не замер.
//
// Инструмент разработчика, в приложение не уезжает. Ничего не пишет и никуда не
// ходит: только читает дерево интерфейса и печатает, что нашёл.
//
//   axprobe trust                 # выдано ли разрешение этому процессу
//   axprobe tree [--depth 6]      # дерево окон Zoom: роли, заголовки, значения
//   axprobe find <строка>         # узлы, чей текст содержит строку (имя участника)
//   axprobe watch [--seconds 30]  # что меняется раз в 0.5 с — так ищется подсветка
//                                 # активного спикера
//
// Разрешение выдаётся **вызывающему** процессу, а не Zoom. Из терминала это
// значит: разрешение нужно тому приложению, из которого проба запущена.

import ApplicationServices
import AppKit
import Foundation

// MARK: - Ввод

let argv = Array(CommandLine.arguments.dropFirst())
// Запущено как .app — аргументов нет, и тогда режим один: снять отчёт.
// Обёртки-скрипта в бандле быть не должно: TCC привязывает право к процессу,
// который дёргает AX, и лишний `bash` в середине ломает привязку — проверено,
// первый заход дал `AXIsProcessTrusted() = false` при выданном доступе.
let command = argv.first ?? "report"

func flag(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: "--" + name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Разрешение и цель

/// Zoom держит несколько процессов; интерфейс встречи — в основном (`zoom.us`),
/// а окно-плитка участников исторически жило и в `CptHost`. Берём все, чьё имя
/// начинается на zoom, и смотрим каждый.
func zoomApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        let id = ($0.bundleIdentifier ?? "").lowercased()
        let name = ($0.localizedName ?? "").lowercased()
        return id.contains("zoom") || name.contains("zoom")
    }
}

/// Попросить доступ системным диалогом.
///
/// Добавлять пробу в список руками оказалось ненадёжно: пункт добавляется, а
/// право не появляется, и `AXIsProcessTrusted()` молча возвращает false —
/// ни диалога, ни записи в `tccd`, потому что эта функция только читает
/// состояние. Штатный путь — спросить: тогда macOS сама заводит приложение в
/// списке и показывает тумблер.
func askForTrust() -> Bool {
    if AXIsProcessTrusted() { return true }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
    return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
}

func requireTrust() {
    guard askForTrust() else {
        print("""
              РАЗРЕШЕНИЯ НЕТ. AXIsProcessTrusted() = false.

              «Универсальный доступ» выдаётся тому приложению, из которого запущена
              проба, а не самой пробе и не Zoom. Из терминала это терминал (или
              агент), и до выдачи AX-вызовы будут возвращать пустоту, а не ошибку, —
              поэтому дальше идти бессмысленно, результат был бы «Zoom ничего не
              отдаёт», и он был бы ложным.

              Системные настройки → Конфиденциальность и безопасность →
              Универсальный доступ.
              """)
        exit(2)
    }
}

// MARK: - Обход дерева

func copyAttr(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ attr: String) -> String? {
    guard let v = copyAttr(element, attr) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (copyAttr(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

struct Node {
    var role: String
    var title: String?
    var value: String?
    var label: String?
    var help: String?
    /// `AXDescription` и `AXRoleDescription` читаются потому, что имя участника
    /// на видеоплитке живёт именно там, а не в заголовке: первый заход печатал
    /// четыре атрибута, видел «AXImage без текста» и делал ложный вывод, что
    /// плитки безымянны.
    var desc: String?
    var roleDesc: String?
    var depth: Int

    /// Весь текст узла — по нему ищутся имена и подсветка.
    var text: String {
        [title, value, label, help, desc, roleDesc].compactMap { $0 }.joined(separator: " | ")
    }

    var line: String {
        String(repeating: "  ", count: depth) + role + (text.isEmpty ? "" : "  « \(text) »")
    }
}

func node(_ element: AXUIElement, depth: Int) -> Node {
    Node(
        role: string(element, kAXRoleAttribute as String) ?? "?",
        title: string(element, kAXTitleAttribute as String),
        value: string(element, kAXValueAttribute as String),
        label: string(element, "AXLabel"),
        help: string(element, kAXHelpAttribute as String),
        desc: string(element, kAXDescriptionAttribute as String),
        roleDesc: string(element, kAXRoleDescriptionAttribute as String),
        depth: depth
    )
}

/// Обход в глубину с потолком, чтобы не залипнуть на списке из тысяч ячеек.
func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int, _ visit: (Node) -> Void) {
    guard depth <= maxDepth, budget > 0 else { return }
    budget -= 1
    let n = node(element, depth: depth)
    visit(n)
    for child in children(element) {
        walk(child, depth: depth + 1, maxDepth: maxDepth, budget: &budget, visit)
    }
}

func windows(of app: NSRunningApplication) -> [AXUIElement] {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    return (copyAttr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
}

func allNodes(maxDepth: Int, budgetPerWindow: Int = 4000) -> [(app: String, window: String, node: Node)] {
    var out: [(String, String, Node)] = []
    for app in zoomApps() {
        let name = app.localizedName ?? app.bundleIdentifier ?? "?"
        let wins = windows(of: app)
        if wins.isEmpty {
            out.append((name, "— окон не отдаёт —", Node(role: "", title: nil, value: nil, label: nil, help: nil, desc: nil, roleDesc: nil, depth: 0)))
            continue
        }
        for w in wins {
            let title = string(w, kAXTitleAttribute as String) ?? "(без заголовка)"
            var budget = budgetPerWindow
            walk(w, depth: 0, maxDepth: maxDepth, budget: &budget) { out.append((name, title, $0)) }
        }
    }
    return out
}


// MARK: - Кто говорит

/// Все атрибуты узла строкой — включая те, что не входят в четвёрку `Node`.
func fullAttrs(_ e: AXUIElement) -> [String: String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(e, &names) == .success,
          let list = names as? [String] else { return [:] }
    var out: [String: String] = [:]
    for a in list {
        // Дети и родители — структура, а не состояние; кадры дрожат от анимаций.
        if ["AXChildren", "AXParent", "AXWindow", "AXTopLevelUIElement",
            "AXChildrenInNavigationOrder", "AXSections", "AXFrame",
            "AXPosition", "AXSize", "AXActivationPoint"].contains(a) { continue }
        guard let v = copyAttr(e, a) else { continue }
        if let s = v as? String { out[a] = s }
        else if let n = v as? NSNumber { out[a] = n.stringValue }
        else if let arr = v as? [Any] { out[a] = "[\(arr.count)]" }
    }
    return out
}

/// Строки панели участников: узел `AXRow` внутри окна встречи, а имя — первый
/// текстовый потомок. Ключ — имя: панель переставляет строки, и ключ по позиции
/// даёт ложные изменения (проверено, первый заход весь состоял из них).
func participantRows() -> [(name: String, row: AXUIElement)] {
    var out: [(String, AXUIElement)] = []
    for app in zoomApps() {
        for w in windows(of: app) {
            // Фильтр по заголовку окна снят намеренно: он завязан на язык
            // клиента и на то, как Zoom называет окно в этой версии. Ищем
            // строки в любом окне — панель участников живёт там, где живёт.
            var budget = 20000
            walkElements(w, depth: 0, maxDepth: 25, budget: &budget) { e, _ in
                let role = string(e, kAXRoleAttribute as String) ?? ""
                // Строка панели участников — `AXRow`; плитка с аватаркой или
                // видео — `AXTabGroup` (замечание владельца: состав на плитках
                // тот же, что в панели, и панель тогда не обязана быть открыта).
                guard role == "AXRow" || role == "AXTabGroup" else { return }
                var nameBudget = 200
                var found: String?
                walkElements(e, depth: 0, maxDepth: 6, budget: &nameBudget) { child, _ in
                    guard found == nil else { return }
                    let r = string(child, kAXRoleAttribute as String) ?? ""
                    if r == "AXStaticText",
                       let t = string(child, kAXValueAttribute as String)
                        ?? string(child, kAXTitleAttribute as String) {
                        found = t
                    } else if let d = string(child, kAXDescriptionAttribute as String), d.count > 2 {
                        found = d
                    }
                }
                if let name = found { out.append((name, e)) }
            }
        }
    }
    return out
}

/// Обход, отдающий сам элемент, а не снимок.
func walkElements(_ e: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int,
                  _ visit: (AXUIElement, Int) -> Void) {
    guard depth <= maxDepth, budget > 0 else { return }
    budget -= 1
    visit(e, depth)
    for c in children(e) { walkElements(c, depth: depth + 1, maxDepth: maxDepth, budget: &budget, visit) }
}

/// Снимок состояния каждого участника: имя → «все атрибуты строки и потомков».
func speakingSnapshot() -> [String: [String: String]] {
    var out: [String: [String: String]] = [:]
    for (name, row) in participantRows() {
        var merged: [String: String] = [:]
        var budget = 400
        walkElements(row, depth: 0, maxDepth: 8, budget: &budget) { e, depth in
            let role = string(e, kAXRoleAttribute as String) ?? "?"
            for (k, v) in fullAttrs(e) { merged["\(depth).\(role).\(k)"] = v }
        }
        out[name] = merged
    }
    return out
}

/// Геометрия плитки участника и её место среди соседей.
///
/// Активный спикер у Zoom выражен раскладкой, а не текстом: в режиме «Динамик»
/// его плитка становится большой, в галерее плитки переставляются. Первый заход
/// исключил `AXFrame`/`AXSize` как «дрожь от анимаций» — и выкинул ровно тот
/// сигнал, который искал. Площадь округляется, чтобы дрожь не считалась
/// событием, а порядок берётся среди детей одного родителя.
func tileGeometry() -> [String: String] {
    var out: [String: String] = [:]
    for app in zoomApps() {
        for w in windows(of: app) {
            var budget = 20000
            var order = 0
            walkElements(w, depth: 0, maxDepth: 25, budget: &budget) { e, _ in
                let role = string(e, kAXRoleAttribute as String) ?? ""
                guard role == "AXRow" || role == "AXTabGroup" else { return }
                guard let d = string(e, kAXDescriptionAttribute as String)
                        ?? string(e, kAXValueAttribute as String) else { return }
                let name = d.split(separator: ",").first.map(String.init) ?? d
                order += 1
                var size = "?"
                if let v = copyAttr(e, kAXSizeAttribute as String) {
                    var cg = CGSize.zero
                    if AXValueGetValue(v as! AXValue, .cgSize, &cg) {
                        // Шаг 40 pt: смена «маленькая ↔ большая» это сотни точек,
                        // а анимация внутри одного состояния — единицы.
                        size = "\(Int(cg.width / 40) * 40)×\(Int(cg.height / 40) * 40)"
                    }
                }
                out[name] = "место \(order), размер \(size)"
            }
        }
    }
    return out
}

func runSpeaking(seconds: Double, say: (String) -> Void) {
    say("=== кто говорит: ключ по имени, все атрибуты строки, \(Int(seconds)) с")
    let start = speakingSnapshot()
    say("участников в панели: \(start.count) — \(start.keys.sorted().joined(separator: ", "))")
    if start.isEmpty {
        say("панель участников закрыта или окно встречи не найдено")
        return
    }
    var changes: [String: Set<String>] = [:]
    var samples = 0
    let deadline = Date().addingTimeInterval(seconds)
    var previous = start
    var geo = tileGeometry()
    say("раскладка на старте: " + geo.map { "\($0.key) — \($0.value)" }.sorted().joined(separator: "; "))
    var geoChanges: [String] = []
    while Date() < deadline {
        samples += 1
        let now = speakingSnapshot()
        for (name, attrs) in now {
            guard let was = previous[name] else { continue }
            for (k, v) in attrs where was[k] != nil && was[k] != v {
                changes[name, default: []].insert("\(k): «\(was[k]!)» → «\(v)»")
            }
        }
        previous = now
        let nowGeo = tileGeometry()
        for (name, v) in nowGeo where geo[name] != nil && geo[name] != v {
            geoChanges.append("\(name): \(geo[name]!) → \(v)")
        }
        geo = nowGeo
        Thread.sleep(forTimeInterval: 0.4)
    }
    say("проходов \(samples)")
    say("\n--- раскладка")
    if geoChanges.isEmpty {
        say("раскладка не менялась — активный спикер через геометрию не выражен")
    } else {
        say("изменений раскладки \(geoChanges.count):")
        for c in geoChanges.prefix(30) { say("   \(c)") }
    }
    if changes.isEmpty {
        say("НИ ОДНОГО меняющегося атрибута ни у одного участника —")
        say("подсветка говорящего через AX не выражена")
        return
    }
    for (name, set) in changes.sorted(by: { $0.key < $1.key }) {
        say("\n\(name): менялось \(set.count)")
        for c in set.sorted().prefix(12) { say("   \(c)") }
    }
}

// MARK: - Команды

func runTrust() {
    let trusted = AXIsProcessTrusted()
    print("AXIsProcessTrusted() = \(trusted)")
    let apps = zoomApps()
    print("процессов Zoom найдено: \(apps.count)")
    for a in apps {
        print("  pid \(a.processIdentifier)  \(a.localizedName ?? "?")  \(a.bundleIdentifier ?? "?")")
    }
    if !trusted {
        print("\nбез разрешения дерево будет пустым, и это не ответ про Zoom, а ответ про нас")
        exit(2)
    }
    if apps.isEmpty {
        print("\nZoom не запущен — запусти клиент, лучше со встречей")
    }
}

func runTree() {
    requireTrust()
    let depth = Int(flag("depth") ?? "6") ?? 6
    let nodes = allNodes(maxDepth: depth)
    guard !nodes.isEmpty else { die("Zoom не запущен или окон не отдаёт") }
    var lastKey = ""
    var withText = 0
    for (app, window, n) in nodes {
        let key = app + "\u{1}" + window
        if key != lastKey {
            print("\n=== \(app) · окно «\(window)»")
            lastKey = key
        }
        if n.role.isEmpty { continue }
        if !n.text.isEmpty { withText += 1 }
        print(n.line)
    }
    print("\nузлов всего \(nodes.count), из них с текстом \(withText)")
}

func runFind() {
    requireTrust()
    guard let needle = argv.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
        die("нужна строка: axprobe find Илья")
    }
    let depth = Int(flag("depth") ?? "12") ?? 12
    let hits = allNodes(maxDepth: depth).filter {
        $0.node.text.localizedCaseInsensitiveContains(needle)
    }
    print("совпадений с «\(needle)»: \(hits.count)")
    for (app, window, n) in hits {
        print("  \(app) · «\(window)» · \(n.role) « \(n.text) »")
    }
}

/// Ищет то, что меняется само: подсветка активного спикера — это изменение
/// атрибута у узла участника, а не отдельное поле.
func runWatch() {
    requireTrust()
    let seconds = Double(flag("seconds") ?? "30") ?? 30
    let depth = Int(flag("depth") ?? "12") ?? 12
    var seen: [String: String] = [:]
    var changes = 0
    let deadline = Date().addingTimeInterval(seconds)
    print("смотрю \(Int(seconds)) с, шаг 0,5 с — говорите по очереди")
    while Date() < deadline {
        for (app, window, n) in allNodes(maxDepth: depth) where !n.role.isEmpty {
            let key = "\(app)|\(window)|\(n.depth)|\(n.role)|\(n.title ?? "")"
            let now = n.text
            if let was = seen[key], was != now {
                changes += 1
                print("  Δ \(n.role) « \(was) » → « \(now) »")
            }
            seen[key] = now
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    print("изменений: \(changes); узлов под наблюдением: \(seen.count)")
}

/// Прогон целиком с отчётом в файл — режим для .app.
///
/// Разрешение «Универсального доступа» выдаётся вызывающему процессу. У пробы,
/// запущенной из терминала, это терминал: выдавать AX терминалу — значит выдать
/// его всему, что из него когда-либо запустят. Поэтому проба умеет быть
/// приложением: свой пункт в списке, свой отзыв, отчёт в файл — ровно как
/// `--tap-probe` в самом Пропеллере.
func runReport() {
    let out = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("diarize-lab-corpus/axprobe-report.txt")
    var lines: [String] = []
    func say(_ s: String) { lines.append(s); print(s) }

    let trusted = askForTrust()
    say("axprobe · \(Date())")
    say("AXIsProcessTrusted() = \(trusted)")
    let apps = zoomApps()
    say("процессов Zoom: \(apps.count)")
    for a in apps { say("  pid \(a.processIdentifier) \(a.localizedName ?? "?") \(a.bundleIdentifier ?? "?")") }

    if trusted, !apps.isEmpty {
        // Сколько окон отдаёт каждый процесс — включая ноль. Первая версия
        // отчёта такие процессы пропускала молча, и «CptHost ничего не отдал»
        // выглядело как «CptHost не проверяли».
        say("")
        for app in apps {
            let n = windows(of: app).count
            say("окон у \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")): \(n)")
        }
        // Все атрибуты окна: нестандартные видно только так.
        for app in apps {
            for w in windows(of: app) {
                let title = string(w, kAXTitleAttribute as String) ?? "(без заголовка)"
                var names: CFArray?
                if AXUIElementCopyAttributeNames(w, &names) == .success,
                   let list = names as? [String] {
                    say("атрибуты окна «\(title)»: " + list.joined(separator: ", "))
                }
            }
        }
        let nodes = allNodes(maxDepth: 25, budgetPerWindow: 20000)
        say("узлов в дереве: \(nodes.count), с текстом: \(nodes.filter { !$0.node.text.isEmpty }.count)")
        var lastKey = ""
        for (app, window, n) in nodes where !n.role.isEmpty {
            let key = app + "\u{1}" + window
            if key != lastKey { say("\n=== \(app) · окно «\(window)»"); lastKey = key }
            say(n.line)
        }
    } else {
        say("дерево не читалось: " + (trusted ? "Zoom не запущен" : "нет разрешения — системный диалог показан"))
    }

    if trusted, !apps.isEmpty {
        say("")
        runSpeaking(seconds: Double(ProcessInfo.processInfo.environment["AXPROBE_WATCH"] ?? "20") ?? 20, say: say)
    }

    try? FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    print("\n→ \(out.path)")
}

switch command {
case "trust": runTrust()
case "tree": runTree()
case "find": runFind()
case "watch": runWatch()
case "report": runReport()
default: die("axprobe trust | tree [--depth N] | find <строка> | watch [--seconds N] | report")
}
