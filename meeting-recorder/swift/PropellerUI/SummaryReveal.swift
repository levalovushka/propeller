import SwiftUI

/// Где лежит скомпилированный Metal (`TextShimmer`, `disintegrate`, …).
///
/// SwiftPM `.metal` не собирает — библиотека кладётся `build.sh` в ресурсы.
/// Нет файла — шиммер идёт градиентом, dissolve — opacity. Проявление саммари —
/// TextKit typewriter и от шейдеров не зависит.
enum SummaryShader {
    static let library: ShaderLibrary? = {
        guard let url = Bundle.main.url(forResource: "PropellerShaders", withExtension: "metallib"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return ShaderLibrary(url: url)
    }()
}
