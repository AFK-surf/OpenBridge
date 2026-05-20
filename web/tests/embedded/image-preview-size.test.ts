import { describe, expect, it } from 'vitest';
import { fitImagePreviewSize } from '../../src/embedded/chat/components/messages/image-preview-size';

describe('fitImagePreviewSize', () => {
  it('keeps images at their natural size when they are inside the preview bounds', () => {
    expect(fitImagePreviewSize(400, 300)).toMatchObject({
      width: 400,
      height: 300,
      scale: 1,
    });
  });

  it('scales oversized images down to fit the maximum preview bounds', () => {
    expect(fitImagePreviewSize(1436, 1240)).toMatchObject({
      width: 602,
      height: 520,
    });
  });

  it('scales tiny images up to satisfy the minimum preview bounds', () => {
    expect(fitImagePreviewSize(80, 60)).toMatchObject({
      width: 160,
      height: 120,
    });
  });

  it('preserves aspect ratio and lets max bounds win for very tall images', () => {
    expect(fitImagePreviewSize(300, 1200)).toMatchObject({
      width: 130,
      height: 520,
    });
  });
});
