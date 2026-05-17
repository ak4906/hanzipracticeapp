//
//  FlowLayout.swift
//  hanzipracticeapp
//
//  Tiny custom SwiftUI `Layout` that flows subviews left-to-right and
//  wraps to a new line when they overflow the proposed width. Used
//  where we need individually tappable hanzi/words inside an example
//  sentence — a plain `HStack` doesn't wrap, and `Text` with an
//  `AttributedString` can't host per-token Buttons.
//

import SwiftUI

struct FlowLayout: Layout {
    /// Horizontal gap between items on the same line.
    var hSpacing: CGFloat = 2
    /// Vertical gap between wrapped lines.
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let frames = arrange(proposal: proposal, subviews: subviews)
        let totalWidth = frames.map { $0.maxX }.max() ?? 0
        let totalHeight = frames.map { $0.maxY }.max() ?? 0
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout Void) {
        let frames = arrange(proposal: proposal, subviews: subviews)
        for (idx, frame) in frames.enumerated() {
            subviews[idx].place(
                at: CGPoint(x: bounds.minX + frame.minX,
                            y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width,
                                            height: frame.height)
            )
        }
    }

    /// Compute one frame per subview given the proposed width.
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [CGRect] {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            // Wrap to the next line if this item doesn't fit on the
            // current one (and we're not already at the start of a
            // fresh line — a single oversized item should still
            // render rather than infinite-loop).
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y,
                                 width: size.width, height: size.height))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
