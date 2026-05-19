export const resolveActivityCenterAnchorHeight = ({
  previousAnchorHeight,
  measuredVisibleHeight,
  isOpen,
}: {
  previousAnchorHeight: number;
  measuredVisibleHeight: number;
  isOpen: boolean;
}) => {
  if (measuredVisibleHeight <= 0) {
    return 0;
  }

  if (isOpen) {
    return measuredVisibleHeight;
  }

  if (!isOpen && previousAnchorHeight > 0) {
    return previousAnchorHeight;
  }

  return measuredVisibleHeight;
};

export const shouldPadActivityCenterSafeArea = ({
  anchorHeight,
  measuredVisibleHeight,
}: {
  anchorHeight: number;
  measuredVisibleHeight: number;
}) => anchorHeight <= 0 || measuredVisibleHeight >= anchorHeight - 0.5;

export const resolveActivityCenterExitY = ({
  anchorHeight,
  safeArea,
  exitOffset = 20,
}: {
  anchorHeight: number;
  safeArea: number;
  exitOffset?: number;
}) => {
  if (anchorHeight <= 0) {
    return `calc(100% + ${exitOffset}px)`;
  }

  return anchorHeight + safeArea + exitOffset;
};
