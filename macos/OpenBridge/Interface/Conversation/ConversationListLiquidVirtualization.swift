//
//  ConversationListLiquidVirtualization.swift
//  OpenBridge
//
//  Created by OpenBridge on 2026/4/13.
//

import Foundation

enum ConversationListLiquidVirtualization {
    struct Row: Identifiable {
        enum Kind {
            case divider
            case sectionHeader(String)
            case session(SessionListInfo)
            case loadMore
        }

        let id: String
        let minY: CGFloat
        let height: CGFloat
        let kind: Kind

        var maxY: CGFloat {
            minY + height
        }
    }

    struct Layout {
        let rows: [Row]
        let contentHeight: CGFloat

        func visibleRows(
            offset: CGFloat,
            visibleHeight: CGFloat,
            overscan: CGFloat = 160
        ) -> ArraySlice<Row> {
            guard !rows.isEmpty else { return rows[0 ..< 0] }

            let minVisibleY = max(CGFloat.zero, offset - overscan)
            let maxVisibleY = max(minVisibleY, offset + max(visibleHeight, 1) + overscan)
            let startIndex = firstIndexIntersecting(y: minVisibleY)
            let endIndex = firstIndexStarting(after: maxVisibleY)
            return rows[startIndex ..< endIndex]
        }

        private func firstIndexIntersecting(y: CGFloat) -> Int {
            var low = 0
            var high = rows.count

            while low < high {
                let mid = (low + high) / 2
                if rows[mid].maxY < y {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            return min(low, rows.count)
        }

        private func firstIndexStarting(after y: CGFloat) -> Int {
            var low = 0
            var high = rows.count

            while low < high {
                let mid = (low + high) / 2
                if rows[mid].minY <= y {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            return min(low, rows.count)
        }
    }

    static func buildLayout(
        sections: [ConversationListSection],
        style: ConversationListPresentationStyle,
        includesLoadMoreFooter: Bool,
        loadMoreFooterHeight: CGFloat
    ) -> Layout {
        var rows: [Row] = []
        var cursorY = style.verticalPadding

        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0 {
                if style.showsSectionDivider {
                    rows.append(
                        Row(
                            id: "divider-\(sectionIndex)",
                            minY: cursorY,
                            height: style.dividerHeight,
                            kind: .divider
                        )
                    )
                    cursorY += style.dividerHeight
                } else {
                    cursorY += style.sectionSpacing
                }
            }

            rows.append(
                Row(
                    id: "header-\(sectionIndex)-\(section.title)",
                    minY: cursorY,
                    height: style.sectionHeaderHeight,
                    kind: .sectionHeader(section.title)
                )
            )
            cursorY += style.sectionHeaderHeight

            for (itemIndex, session) in section.items.enumerated() {
                rows.append(
                    Row(
                        id: session.id,
                        minY: cursorY,
                        height: style.rowHeight,
                        kind: .session(session)
                    )
                )
                cursorY += style.rowHeight

                if itemIndex < section.items.count - 1 {
                    cursorY += style.rowSpacing
                }
            }
        }

        cursorY += style.verticalPadding

        if includesLoadMoreFooter {
            rows.append(
                Row(
                    id: "load-more",
                    minY: cursorY,
                    height: loadMoreFooterHeight,
                    kind: .loadMore
                )
            )
            cursorY += loadMoreFooterHeight
        }

        return Layout(
            rows: rows,
            contentHeight: max(cursorY, 1)
        )
    }
}
