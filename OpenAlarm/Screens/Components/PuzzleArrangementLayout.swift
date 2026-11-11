import SwiftUI

/// Places three subviews (lead, puzzle, trail) stacked or side by side. It picks the
/// arrangement that gives the puzzle the larger cells in the measured space. One layout
/// serves both arrangements, so rotation and fold changes keep the subviews' identity
/// and state.
struct PuzzleArrangementLayout: Layout {
    enum Puzzle {
        /// A square grid with `count` x `count` cells.
        case grid(count: Int, maxSide: CGFloat)
        /// A keypad with `columns` x `rows` keys.
        case keypad(columns: Int, rows: Int, maxWidth: CGFloat, maxKeyHeight: CGFloat)
    }

    enum Shortfall {
        /// The lead gets less height and is hidden as a last resort. The puzzle never scrolls.
        case shrinkLead
        /// The puzzle keeps the minimum cell size and the content grows past the budget,
        /// so an enclosing scroll view can scroll it.
        case overflow
    }

    var puzzle: Puzzle
    var spacing: CGFloat
    var cellSpacing: CGFloat
    var minimumCell: CGFloat
    /// The side-by-side arrangement reserves up to this share of the width for the lead column.
    var columnShare: CGFloat
    var shortfall: Shortfall
    /// The space to fill when the parent does not propose a height, for example a scroll view.
    var budget: CGSize?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let space = space(for: proposal)
        let plan = plan(in: space, subviews: subviews)
        let height = proposal.height.map { $0.isFinite } == true || budget != nil
            ? max(space.height, shortfall == .overflow ? plan.contentHeight : 0)
            : plan.contentHeight
        return CGSize(width: space.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let space = budget ?? bounds.size
        let plan = plan(in: space, subviews: subviews)
        let lead = subviews[0]
        let puzzleView = subviews[1]
        let trail = subviews[2]

        if plan.isSideBySide {
            let groupWidth = plan.columnWidth + spacing + plan.puzzleSize.width
            let originX = bounds.minX + max(0, (bounds.width - groupWidth) / 2)
            let columnHeight = plan.leadHeight + gap(after: plan.leadHeight, before: plan.trailHeight) + plan.trailHeight
            var y = bounds.midY - columnHeight / 2
            let columnMidX = originX + plan.columnWidth / 2

            lead.place(
                at: CGPoint(x: columnMidX, y: y),
                anchor: .top,
                proposal: ProposedViewSize(width: plan.columnWidth, height: plan.leadHeight)
            )
            y += plan.leadHeight + gap(after: plan.leadHeight, before: plan.trailHeight)
            trail.place(
                at: CGPoint(x: columnMidX, y: y),
                anchor: .top,
                proposal: ProposedViewSize(width: plan.columnWidth, height: plan.trailHeight)
            )
            puzzleView.place(
                at: CGPoint(x: originX + plan.columnWidth + spacing, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(plan.puzzleSize)
            )
        } else {
            var y = bounds.minY + max(0, (bounds.height - plan.contentHeight) / 2)
            lead.place(
                at: CGPoint(x: bounds.midX, y: y),
                anchor: .top,
                proposal: ProposedViewSize(width: plan.columnWidth, height: plan.leadHeight)
            )
            y += plan.leadHeight + gap(after: plan.leadHeight)
            puzzleView.place(
                at: CGPoint(x: bounds.midX, y: y),
                anchor: .top,
                proposal: ProposedViewSize(plan.puzzleSize)
            )
            y += plan.puzzleSize.height + gap(after: plan.trailHeight)
            trail.place(
                at: CGPoint(x: bounds.midX, y: y),
                anchor: .top,
                proposal: ProposedViewSize(width: plan.columnWidth, height: plan.trailHeight)
            )
        }
    }

    // MARK: - Planning

    private struct Plan {
        var isSideBySide: Bool
        var columnWidth: CGFloat
        var leadHeight: CGFloat
        var trailHeight: CGFloat
        var puzzleSize: CGSize
        var cell: CGFloat
        var contentHeight: CGFloat
    }

    private func space(for proposal: ProposedViewSize) -> CGSize {
        if let budget { return budget }
        func finite(_ value: CGFloat?) -> CGFloat? {
            guard let value, value.isFinite else { return nil }
            return value
        }
        return CGSize(
            width: finite(proposal.width) ?? puzzleMaxWidth,
            height: finite(proposal.height) ?? .greatestFiniteMagnitude / 4
        )
    }

    private func plan(in space: CGSize, subviews: Subviews) -> Plan {
        let stacked = stackedPlan(in: space, subviews: subviews)
        let sideBySide = sideBySidePlan(in: space, subviews: subviews)
        // Prefer the familiar stacked arrangement unless side by side gives larger cells.
        return sideBySide.cell > stacked.cell + 0.5 ? sideBySide : stacked
    }

    private func stackedPlan(in space: CGSize, subviews: Subviews) -> Plan {
        let width = min(space.width, puzzleMaxWidth)
        var leadHeight = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let trailHeight = subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil)).height

        func puzzleSpace() -> CGSize {
            CGSize(
                width: width,
                height: space.height - leadHeight - trailHeight
                    - gap(after: leadHeight) - gap(after: trailHeight)
            )
        }

        var fit = fitPuzzle(in: puzzleSpace())
        if fit.cell < minimumCell, shortfall == .shrinkLead {
            let needed = puzzleSize(forCell: minimumCell, width: width).height
            let leadBudget = space.height - needed - trailHeight - spacing - gap(after: trailHeight)
            leadHeight = yieldedLeadHeight(leadHeight, budget: leadBudget, lead: subviews[0])
            fit = fitPuzzle(in: puzzleSpace())
        }
        let raw = fit.cell
        if fit.cell < minimumCell, shortfall == .overflow {
            fit = (puzzleSize(forCell: minimumCell, width: width), minimumCell)
        }

        return Plan(
            isSideBySide: false,
            columnWidth: width,
            leadHeight: leadHeight,
            trailHeight: trailHeight,
            puzzleSize: fit.size,
            cell: raw,
            contentHeight: leadHeight + gap(after: leadHeight) + fit.size.height
                + gap(after: trailHeight) + trailHeight
        )
    }

    private func sideBySidePlan(in space: CGSize, subviews: Subviews) -> Plan {
        let leadIdeal = subviews[0].sizeThatFits(.unspecified).width
        let trailIdeal = subviews[2].sizeThatFits(.unspecified).width
        let reserve = min(max(leadIdeal, trailIdeal), max(0, space.width - spacing) * columnShare)
        var fit = fitPuzzle(in: CGSize(width: space.width - spacing - reserve, height: space.height))
        let raw = fit.cell
        if fit.cell < minimumCell, shortfall == .overflow {
            fit = (puzzleSize(forCell: minimumCell, width: fit.size.width), minimumCell)
        }

        let columnWidth = max(0, min(
            space.width - spacing - fit.size.width,
            max(leadIdeal, trailIdeal, fit.size.width)
        ))
        let trailHeight = subviews[2].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        var leadHeight = subviews[0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        let columnHeight = leadHeight + gap(after: leadHeight) + trailHeight
        if columnHeight > space.height, shortfall == .shrinkLead {
            leadHeight = yieldedLeadHeight(
                leadHeight,
                budget: space.height - trailHeight - gap(after: trailHeight),
                lead: subviews[0]
            )
        }

        return Plan(
            isSideBySide: true,
            columnWidth: columnWidth,
            leadHeight: leadHeight,
            trailHeight: trailHeight,
            puzzleSize: fit.size,
            cell: raw,
            contentHeight: max(fit.size.height, leadHeight + gap(after: leadHeight) + trailHeight)
        )
    }

    /// Gives the lead at most `budget`. Below 70% of a single line it is hidden.
    private func yieldedLeadHeight(_ height: CGFloat, budget: CGFloat, lead: LayoutSubview) -> CGFloat {
        let singleLine = lead.sizeThatFits(.unspecified).height
        guard budget >= singleLine * 0.7 else { return 0 }
        return min(height, budget)
    }

    private func gap(after height: CGFloat, before next: CGFloat = 1) -> CGFloat {
        height > 0 && next > 0 ? spacing : 0
    }

    private var puzzleMaxWidth: CGFloat {
        switch puzzle {
        case let .grid(_, maxSide): maxSide
        case let .keypad(_, _, maxWidth, _): maxWidth
        }
    }

    private func fitPuzzle(in space: CGSize) -> (size: CGSize, cell: CGFloat) {
        switch puzzle {
        case let .grid(count, maxSide):
            let side = max(0, min(space.width, space.height, maxSide))
            let cell = (side - cellSpacing * CGFloat(count - 1)) / CGFloat(count)
            return (CGSize(width: side, height: side), cell)
        case let .keypad(columns, rows, maxWidth, maxKeyHeight):
            let width = max(0, min(space.width, maxWidth))
            let keyWidth = (width - cellSpacing * CGFloat(columns - 1)) / CGFloat(columns)
            let keyHeight = max(0, min((space.height - cellSpacing * CGFloat(rows - 1)) / CGFloat(rows), maxKeyHeight))
            let height = keyHeight * CGFloat(rows) + cellSpacing * CGFloat(rows - 1)
            return (CGSize(width: width, height: height), min(keyWidth, keyHeight))
        }
    }

    private func puzzleSize(forCell cell: CGFloat, width: CGFloat) -> CGSize {
        switch puzzle {
        case let .grid(count, _):
            let side = cell * CGFloat(count) + cellSpacing * CGFloat(count - 1)
            return CGSize(width: side, height: side)
        case let .keypad(_, rows, maxWidth, _):
            let height = cell * CGFloat(rows) + cellSpacing * CGFloat(rows - 1)
            return CGSize(width: min(width, maxWidth), height: height)
        }
    }
}

extension TaskMode {
    /// The smallest memory cell or keypad key. The wake-up challenge keeps full touch
    /// targets. The configurator preview may go smaller when its area is short.
    var minimumPuzzleCell: CGFloat {
        switch self {
        case .wake: OASize.minTouchTarget
        case .preview: 28
        }
    }
}
