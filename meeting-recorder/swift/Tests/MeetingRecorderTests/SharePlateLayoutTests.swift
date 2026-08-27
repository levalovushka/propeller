import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Числа макета `summary/share-link`. Плита собрана из отступов, и сумма — это
/// ровно то, что в макете названо высотой: 428 у неопубликованной и 196 у
/// опубликованной. Проверять сумму дешевле и надёжнее, чем каждый зазор
/// отдельно: ошибка в любом слагаемом ломает её.
final class SharePlateLayoutTests: XCTestCase {

    @MainActor
    func testTheComposePlateIsTheHeightTheCompsDrew() {
        XCTAssertEqual(height(of: .compose), 428, accuracy: 0.5)
    }

    @MainActor
    func testThePublishedPlateIsTheHeightTheCompsDrew() {
        let url = URL(string: "https://propeller.report/s/abc#k=def")!
        XCTAssertEqual(height(of: .published(url)), 196, accuracy: 0.5)
    }

    func testThePlateIsTheWidthTheCompsDrew() {
        XCTAssertEqual(Tokens.Share.width, 360)
        XCTAssertEqual(Tokens.Share.radius, 20)
        XCTAssertEqual(Tokens.Share.padding, 20)
        XCTAssertEqual(Tokens.Share.previewHeight, 200)
        XCTAssertEqual(Tokens.Share.controlHeight, 32)
    }

    // MARK: - Приборы

    @MainActor
    private func height(of mode: SharePlate.Mode) -> CGFloat {
        let plate = SharePlate(
            mode: mode,
            lifetime: .constant("month"),
            lifetimes: [.init(id: "week", title: "Неделя"), .init(id: "month", title: "Месяц")],
            preview: .init(title: "Встреча", meta: "22 авг, 16:30", lines: ["Строка"])
        )
        .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: plate)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }
}
