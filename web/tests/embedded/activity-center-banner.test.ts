import { describe, expect, it } from 'vitest';
import {
  resolveActivityCenterAnchorHeight,
  resolveActivityCenterExitY,
  shouldPadActivityCenterSafeArea,
} from '../../src/embedded/chat/components/messages/activity-center/layout';

describe('ActivityCenterBanner layout anchoring', () => {
  it('keeps the expanded anchor height while the banner is collapsing', () => {
    expect(
      resolveActivityCenterAnchorHeight({
        previousAnchorHeight: 240,
        measuredVisibleHeight: 36,
        isOpen: false,
      })
    ).toBe(240);
  });

  it('grows the anchor when open content becomes taller', () => {
    expect(
      resolveActivityCenterAnchorHeight({
        previousAnchorHeight: 120,
        measuredVisibleHeight: 180,
        isOpen: true,
      })
    ).toBe(180);
  });

  it('shrinks the anchor when open content becomes shorter', () => {
    expect(
      resolveActivityCenterAnchorHeight({
        previousAnchorHeight: 240,
        measuredVisibleHeight: 120,
        isOpen: true,
      })
    ).toBe(120);
  });

  it('does not expose bottom safe-area padding after top-anchored collapse', () => {
    expect(
      shouldPadActivityCenterSafeArea({
        anchorHeight: 240,
        measuredVisibleHeight: 36,
      })
    ).toBe(false);
  });

  it('pushes a top-anchored collapsed banner below the viewport on exit', () => {
    expect(
      resolveActivityCenterExitY({ anchorHeight: 240, safeArea: 60 })
    ).toBe(320);
  });
});
