import SwiftUI

/// A flow layout (HStack that wraps to additional rows when content exceeds
/// the container width). Used for ruby-annotated subtitle tokens so that
/// long sentences wrap instead of pushing the broadcast window wider.
///
/// Each row is horizontally centered. Within a row, items are bottom-aligned
/// so the main glyphs (which sit at the bottom of each VStack token) all
/// share a single baseline.
struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        let rows = arrangeRows(subviews: subviews, containerWidth: containerWidth)
        let totalHeight = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        let maxRowWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangeRows(subviews: subviews, containerWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2  // center each row
            for item in row.items {
                let yOffset = row.height - item.size.height  // bottom-align in row
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + yOffset),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct RowItem {
        let index: Int
        let size: CGSize
    }
    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrangeRows(subviews: Subviews, containerWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let isFirstInRow = rows[rows.count - 1].items.isEmpty
            let extra: CGFloat = isFirstInRow ? 0 : horizontalSpacing
            let proposedWidth = rows[rows.count - 1].width + extra + size.width
            if proposedWidth > containerWidth && !isFirstInRow {
                rows.append(Row())
            }
            let lastIdx = rows.count - 1
            rows[lastIdx].items.append(RowItem(index: i, size: size))
            if rows[lastIdx].items.count == 1 {
                rows[lastIdx].width = size.width
            } else {
                rows[lastIdx].width += horizontalSpacing + size.width
            }
            rows[lastIdx].height = max(rows[lastIdx].height, size.height)
        }
        return rows
    }
}
