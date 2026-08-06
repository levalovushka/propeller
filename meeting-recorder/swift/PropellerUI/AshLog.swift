import Foundation
import os

/// Диагностика пепла. Читается снаружи:
/// `log show --last 5m --predicate 'subsystem == "com.propeller.ash"' --info`
///
/// Живёт отдельным файлом, потому что путь идёт через три слоя — рельс,
/// растеризацию и Metal, — и вопрос «где именно оборвалось» иначе стоит
/// сборки на каждую гипотезу.
enum AshLog {
    static let log = Logger(subsystem: "com.propeller.ash", category: "dissolve")
}
