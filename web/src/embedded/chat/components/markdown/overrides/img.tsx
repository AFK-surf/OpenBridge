import { Menu } from '@/utils/webview-context-menu';
import { cn } from '@/utils/cn';
import {
  useCallback,
  useState,
  type CSSProperties,
  type SyntheticEvent,
} from 'react';
import { fitImagePreviewSize } from '../../messages/image-preview-size';

/**
 * Custom image component with loading animation and error handling.
 */
export const CueStreamdownImg = ({
  src,
  alt,
  className,
  onLoad,
  onError,
  style,
  ...props
}: React.ComponentProps<'img'>) => {
  const [imageLoaded, setImageLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [naturalSize, setNaturalSize] = useState<{
    width: number;
    height: number;
  } | null>(null);

  const handleContextMenu = useCallback(
    (event: React.MouseEvent<HTMLImageElement>) => {
      const menu = Menu.create();
      if (src) {
        menu.pushItem({
          title: 'Save Image',
          icon: Menu.icon.symbol('square.and.arrow.down'),
          onClick: () => {
            window.jsb?.UtilsBridge?.saveImage(src, 'bridge-image');
          },
        });
      }

      menu.popup(event);
    },
    [src]
  );

  const handleLoad = useCallback(
    (event: SyntheticEvent<HTMLImageElement>) => {
      const image = event.currentTarget;
      if (image.naturalWidth > 0 && image.naturalHeight > 0) {
        setNaturalSize({
          width: image.naturalWidth,
          height: image.naturalHeight,
        });
      }
      setImageLoaded(true);
      onLoad?.(event);
    },
    [onLoad]
  );

  const handleError = useCallback(
    (event: SyntheticEvent<HTMLImageElement>) => {
      setError('Failed to load image');
      onError?.(event);
    },
    [onError]
  );

  const previewSize = naturalSize
    ? fitImagePreviewSize(naturalSize.width, naturalSize.height)
    : null;
  const imageStyle = {
    ...style,
    ...(previewSize && naturalSize
      ? {
          width: previewSize.width,
          maxHeight: previewSize.height,
          aspectRatio: `${naturalSize.width} / ${naturalSize.height}`,
        }
      : {}),
  } satisfies CSSProperties;

  // Error state
  if (error) {
    return (
      <div className="inline-flex flex-col items-start bg-red-50 dark:bg-red-900/20 rounded p-4 border border-red-200 dark:border-red-800 max-w-full overflow-hidden">
        <span className="text-sm text-red-600 dark:text-red-400">{error}</span>
        <code className="text-xs text-red-500 dark:text-red-400 mt-1 break-all">
          {src}
        </code>
      </div>
    );
  }

  return (
    <img
      src={src}
      alt={alt || 'Generated image'}
      onContextMenu={handleContextMenu}
      className={cn(
        'inline-block h-auto max-w-full rounded-lg object-contain transition-opacity duration-500 ease-out',
        className,
        imageLoaded ? 'opacity-100' : 'opacity-0'
      )}
      style={imageStyle}
      onLoad={handleLoad}
      onError={handleError}
      {...props}
    />
  );
};
