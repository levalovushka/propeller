import SwiftUI

/// Lays subviews out left-to-right, wrapping onto a new line when the next one
/// no longer fits — like text, but every item stays its own view.
///
/// The karaoke transcript needs this: a phrase has to be individually clickable
/// (click it, hear it) while the remark still reads as flowing prose. Styling
/// ranges inside a single `Text` cannot do that — attributed ranges are not hit
/// targets, and a `link` attribute overrides the karaoke colours.
///
/// An item wider than the line is proposed the full width and wraps internally.
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 4, lineSpacing: CGFloat = 3) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(
            width: width.isFinite ? width : (rows.map(\.width).max() ?? 0),
            height: height
        )
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    // MARK: - Line breaking

    private struct Item {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            // Propose the full line width so an over-long phrase wraps inside
            // itself instead of running off the edge.
            let size = subview.sizeThatFits(
                ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
            )
            if x > 0, x + spacing + size.width > maxWidth {
                row.width = x
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
                x = 0
            }
            if x > 0 { x += spacing }
            row.items.append(Item(index: index, x: x, size: size))
            x += size.width
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty {
            row.width = x
            rows.append(row)
        }
        return rows
    }
}
