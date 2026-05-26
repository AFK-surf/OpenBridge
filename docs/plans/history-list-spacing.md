# History List Spacing Plan

## Goal
Fix the small-window Bridge history popup so adjacent conversation rows no longer visually collide when a row is hovered.

## Current State
- The macOS 26 small-window header uses `ConversationHistoryLiquidActionGroup` with the `.liquidPopup` conversation list style.
- Liquid popup conversation rows are spaced tightly, and non-virtualized rows are not forced to the same layout height as their hover/active background.
- In dense lists, an active row background and the next hovered row background can visually collide because the background extends outside the row's allocated geometry.

## Proposed Changes
1. Keep the data flow, selection, rename/delete/share actions, shortcuts, and accessibility identifiers unchanged.
2. Restore the previous compact `.liquidPopup` row height while keeping hover backgrounds contained: 36px rows, 0px adjacent row gaps, and 12px section gaps.
3. Keep each compact history item to one visible title line by hiding the gray last-message preview text.
4. Force non-virtualized `.liquidPopup` item rows to use the same fixed row height that the background and virtualization layout use.
5. Keep the legacy `.menu` style unchanged.
6. Add regression coverage for the liquid popup row metrics, preview visibility, inter-section spacing, and virtualization layout gaps.
7. Validate the popup in a small-window history scenario and capture a screenshot.

## What Happens If We Do Not Change It
Hovering a conversation row in the small-window history popup can still overlap or crowd adjacent rows, making the list feel broken and increasing mis-click risk.

## Expected Result After Change
Each history item keeps its hover/active background inside its own row box. Adjacent item backgrounds meet without an inserted gap and without visual overlap.

## Acceptance Criteria
- `.liquidPopup` adjacent rows have a 0px layout gap while each hover/active background stays contained in its own row box.
- `.liquidPopup` rows do not render the gray last-message preview text.
- Legacy `.menu` row metrics remain unchanged.
- Virtualized and non-virtualized liquid list rows use the previous compact height while keeping hover/active backgrounds inside that row box.
- Section headers keep a clear gap from the previous section's final row background.
- Existing row actions and selection behavior remain unchanged.
- Automated coverage passes or any environment blocker is explicitly reported.
- Manual small-window visual validation produces a screenshot showing separated hover rows.
