export type ImagePreviewBounds = {
  minWidth: number;
  minHeight: number;
  maxWidth: number;
  maxHeight: number;
};

export type ImagePreviewSize = {
  width: number;
  height: number;
  scale: number;
};

export const imagePreviewBounds: ImagePreviewBounds = {
  minWidth: 160,
  minHeight: 120,
  maxWidth: 640,
  maxHeight: 520,
};

export function fitImagePreviewSize(
  naturalWidth: number,
  naturalHeight: number,
  bounds: ImagePreviewBounds = imagePreviewBounds
): ImagePreviewSize | null {
  if (
    !isPositiveFiniteNumber(naturalWidth) ||
    !isPositiveFiniteNumber(naturalHeight)
  ) {
    return null;
  }

  const maxScale = Math.min(
    bounds.maxWidth / naturalWidth,
    bounds.maxHeight / naturalHeight
  );
  let scale = 1;

  if (maxScale < 1) {
    scale = maxScale;
  } else if (
    naturalWidth < bounds.minWidth ||
    naturalHeight < bounds.minHeight
  ) {
    const minScale = Math.max(
      bounds.minWidth / naturalWidth,
      bounds.minHeight / naturalHeight
    );
    scale = Math.min(minScale, maxScale);
  }

  return {
    width: Math.max(1, Math.round(naturalWidth * scale)),
    height: Math.max(1, Math.round(naturalHeight * scale)),
    scale,
  };
}

function isPositiveFiniteNumber(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}
