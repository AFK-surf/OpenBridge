# Synced Skills Suggested Add Button Light Mode Fix

## Goal
Make the Settings > Synced Skills > Suggested row Add button match the About settings page's standard bordered text-button treatment in light mode, instead of rendering as a dark/black prominent fill.

## Current state
`SuggestedSyncFolderRow` uses a small `.borderedProminent` button with a custom tint derived from `SettingsManager`. When the app accent preference is the default value, this can render as a black filled control in light mode. Existing UI coverage only asserts the sampled button is not near-black, which does not lock in the desired About-style bordered control.

## Proposed changes
- Remove the custom Suggested Add button tint helper and the `.borderedProminent` style.
- Render Suggested Add as `.buttonStyle(.bordered)` with `.controlSize(.small)`, matching About settings text buttons while preserving the label, click behavior, and accessibility identifier.
- Update the Synced Skills UI test to assert the button remains visually non-prominent in light mode by checking the screenshot does not have a dark/opaque filled background, then verify the add action still removes the suggested row.

## If we do not change it
The button can continue to look like a black filled control in light mode, inconsistent with other Settings text buttons and visually heavier than intended.

## Expected result after the change
The Add button appears as a small bordered text button in Suggested rows, consistent with About settings, while adding suggested sync folders still works.

## Acceptance criteria
- Suggested Add button uses bordered, not prominent, styling in code.
- UI test covers light-mode visual regression and add behavior.
- Targeted macOS validation confirms Settings > Synced Skills > Suggested shows the corrected button and clicking Add works.
