import { cn } from '@/utils/cn';
import {
  isLikelyLocalFilesystemPath,
  requiresNativeURLResolution,
  resolveAttachmentDisplayURL,
} from '@/utils/agent-file-url';
import { hasNativeJSBridge } from '@/utils/bridge-runtime';
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type CSSProperties,
} from 'react';
import { Spinner } from '../loading/spinner';
import { Menu } from '@/utils/webview-context-menu';
import { EyeSFSymbolMedium } from '@/assets/sf-symbols/medium/eye';
import {
  preparePreviewAsset,
  previewAttachmentSource,
  previewSourceRectForElement,
} from './file-reference-actions';
import {
  fitImagePreviewSize,
  imagePreviewBounds,
  type ImagePreviewBounds,
} from './image-preview-size';

type PreviewButtonTone = 'dark' | 'light';
type NaturalImageSize = { width: number; height: number };

function detectPreviewButtonTone(image: HTMLImageElement): PreviewButtonTone {
  const naturalWidth = image.naturalWidth;
  const naturalHeight = image.naturalHeight;
  if (!naturalWidth || !naturalHeight) {
    return 'dark';
  }

  const sampleWidth = Math.min(
    naturalWidth,
    Math.max(48, Math.round(naturalWidth * 0.24))
  );
  const sampleHeight = Math.min(
    naturalHeight,
    Math.max(48, Math.round(naturalHeight * 0.2))
  );
  const sourceX = Math.max(0, naturalWidth - sampleWidth);
  const sourceY = 0;
  const canvas = document.createElement('canvas');
  canvas.width = sampleWidth;
  canvas.height = sampleHeight;

  const context = canvas.getContext('2d', { willReadFrequently: true });
  if (!context) {
    return 'dark';
  }

  try {
    context.drawImage(
      image,
      sourceX,
      sourceY,
      sampleWidth,
      sampleHeight,
      0,
      0,
      sampleWidth,
      sampleHeight
    );

    const { data } = context.getImageData(0, 0, sampleWidth, sampleHeight);
    if (!data.length) {
      return 'dark';
    }

    let totalLuminance = 0;
    let totalWeight = 0;

    for (let index = 0; index < data.length; index += 4) {
      const alpha = data[index + 3] / 255;
      if (alpha <= 0) {
        continue;
      }

      const red = data[index];
      const green = data[index + 1];
      const blue = data[index + 2];
      totalLuminance += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha;
      totalWeight += alpha;
    }

    if (totalWeight <= 0) {
      return 'dark';
    }

    const averageLuminance = totalLuminance / totalWeight;
    return averageLuminance >= 160 ? 'light' : 'dark';
  } catch {
    return 'dark';
  }
}

export const AttachmentImage = ({
  src,
  fileName,
  mimeType,
  sourcePath,
  environmentId,
  className,
  style,
  previewBounds = imagePreviewBounds,
  ...props
}: {
  className?: string;
  src?: string | null;
  fileName?: string;
  mimeType?: string;
  sourcePath?: string;
  environmentId?: string;
  previewBounds?: ImagePreviewBounds;
} & React.HTMLAttributes<HTMLElement>) => {
  const [status, setStatus] = useState<'loading' | 'loaded' | 'error'>(
    'loading'
  );
  const [resolvedSrc, setResolvedSrc] = useState<string | null>(null);
  const [previewButtonTone, setPreviewButtonTone] =
    useState<PreviewButtonTone>('dark');
  const [naturalSize, setNaturalSize] = useState<NaturalImageSize | null>(null);
  const figureRef = useRef<HTMLElement | null>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);

  // Resolve remote URLs or local file refs into a browser-displayable source.
  useEffect(() => {
    let cancelled = false;

    const resolveUrl = async () => {
      const candidateSource = src?.trim();
      const localPath = sourcePath?.trim();
      const displaySource = resolveAttachmentDisplayURL({
        src: candidateSource,
        filePath: localPath,
        environmentId,
      });

      if (!candidateSource && !localPath) {
        if (!cancelled) {
          setStatus('error');
        }
        return;
      }

      // Data URLs don't need resolution
      if (displaySource?.startsWith('data:')) {
        setResolvedSrc(displaySource);
        return;
      }

      if (!hasNativeJSBridge()) {
        if (!cancelled) {
          if (displaySource) {
            setResolvedSrc(displaySource);
            return;
          }
          setStatus('error');
        }
        return;
      }

      if (displaySource && requiresNativeURLResolution(displaySource)) {
        try {
          const resolved =
            await window.jsb?.MessagesBridge?.getStorageDownloadUrl(
              displaySource
            );
          if (!cancelled) {
            if (resolved) {
              setResolvedSrc(resolved);
              return;
            }
            setStatus('error');
          }
        } catch (err) {
          console.error(
            '[AttachmentImage] Failed to resolve authenticated attachment URL:',
            err
          );
          if (!cancelled) {
            setStatus('error');
          }
        }
        return;
      }

      if (displaySource) {
        if (!cancelled) {
          setResolvedSrc(displaySource);
        }
        return;
      }

      const localSource =
        (candidateSource && isLikelyLocalFilesystemPath(candidateSource)
          ? candidateSource
          : undefined) ?? localPath;

      if (
        localSource &&
        (!candidateSource || isLikelyLocalFilesystemPath(candidateSource))
      ) {
        try {
          const resolved =
            await window.jsb?.MessagesBridge?.getLocalImageDataURL(localSource);
          if (!cancelled) {
            if (resolved) {
              setResolvedSrc(resolved);
              return;
            }
            setStatus('error');
          }
          return;
        } catch (err) {
          console.error(
            '[AttachmentImage] Failed to resolve local image path:',
            err
          );
          if (!cancelled) {
            setStatus('error');
          }
          return;
        }
      }

      if (!candidateSource) {
        if (!cancelled) {
          setStatus('error');
        }
        return;
      }

      if (!cancelled) {
        setResolvedSrc(candidateSource);
      }
    };

    setStatus('loading');
    setResolvedSrc(null);
    setPreviewButtonTone('dark');
    setNaturalSize(null);
    resolveUrl();

    return () => {
      cancelled = true;
    };
  }, [environmentId, sourcePath, src]);

  // Data URLs (base64) don't need lazy loading
  const isDataUrl = resolvedSrc?.startsWith('data:') ?? false;

  const handleLoad = useCallback(() => {
    setStatus('loaded');

    const image = imageRef.current;
    if (!image) {
      return;
    }

    if (image.naturalWidth > 0 && image.naturalHeight > 0) {
      setNaturalSize({
        width: image.naturalWidth,
        height: image.naturalHeight,
      });
    }
    setPreviewButtonTone(detectPreviewButtonTone(image));
    if (resolvedSrc) {
      preparePreviewAsset(resolvedSrc, fileName, mimeType);
    }
  }, [fileName, mimeType, resolvedSrc]);

  const handleError = () => setStatus('error');

  const previewSourceRect = useCallback(() => {
    return previewSourceRectForElement(imageRef.current ?? figureRef.current);
  }, []);

  const handlePreviewClick = useCallback(
    (event: React.MouseEvent<HTMLButtonElement>) => {
      event.preventDefault();
      event.stopPropagation();

      if (!resolvedSrc && !sourcePath) {
        return;
      }

      void previewAttachmentSource(resolvedSrc, {
        fileName,
        mimeType,
        fallbackPath: sourcePath,
        environmentId,
        sourceRect: previewSourceRect(),
      });
    },
    [
      environmentId,
      fileName,
      mimeType,
      previewSourceRect,
      resolvedSrc,
      sourcePath,
    ]
  );

  const handleContextMenu = useCallback(
    (event: React.MouseEvent<HTMLElement>) => {
      const menu = Menu.create();
      if (resolvedSrc || sourcePath) {
        menu.pushItem({
          title: 'Preview',
          icon: Menu.icon.symbol('document.viewfinder'),
          onClick: () => {
            void previewAttachmentSource(resolvedSrc, {
              fileName,
              mimeType,
              fallbackPath: sourcePath,
              environmentId,
              sourceRect: previewSourceRect(),
            });
          },
        });
      }

      if (resolvedSrc) {
        if (resolvedSrc || sourcePath) {
          menu.pushSeparator();
        }
        menu.pushItem({
          title: 'Save Image',
          icon: Menu.icon.symbol('square.and.arrow.down'),
          onClick: () => {
            window.jsb?.UtilsBridge.saveImage(resolvedSrc, 'bridge-image');
          },
        });
      }

      menu.popup(event);
    },
    [
      environmentId,
      fileName,
      mimeType,
      previewSourceRect,
      resolvedSrc,
      sourcePath,
    ]
  );

  const previewSize = naturalSize
    ? fitImagePreviewSize(naturalSize.width, naturalSize.height, previewBounds)
    : null;
  const imageStyle =
    previewSize && naturalSize
      ? ({
          width: previewSize.width,
          maxHeight: previewSize.height,
          aspectRatio: `${naturalSize.width} / ${naturalSize.height}`,
        } satisfies CSSProperties)
      : undefined;
  const figureStyle = {
    minWidth: previewBounds.minWidth,
    minHeight: previewBounds.minHeight,
    ...style,
    ...(previewSize ? { width: previewSize.width } : {}),
  } satisfies CSSProperties;

  return (
    <figure
      ref={node => {
        figureRef.current = node;
      }}
      onContextMenu={handleContextMenu}
      className={cn(
        'group/image overflow-hidden rounded-lg border border-black/10 dark:border-white/20 relative',
        'inline-flex max-w-full items-center justify-center bg-black/5 dark:bg-white/5',
        className
      )}
      style={figureStyle}
      data-source-path={sourcePath}
      {...props}
    >
      {(resolvedSrc || sourcePath) && status === 'loaded' && (
        <button
          type="button"
          onClick={handlePreviewClick}
          className={cn(
            'max-w-4/5 truncate',
            'absolute right-3 top-3 z-20 inline-flex items-center gap-1.5 rounded-full px-2.5 py-1.5',
            'text-[11px] font-medium leading-none shadow-sm ring-1 transition-all duration-150',
            'opacity-0 pointer-events-none group-hover/image:opacity-100 group-hover/image:pointer-events-auto',
            'group-focus-within/image:opacity-100 group-focus-within/image:pointer-events-auto',
            'backdrop-blur-md',
            previewButtonTone === 'light'
              ? 'bg-white/55 text-black ring-black/10 shadow-black/10 hover:bg-white/65'
              : 'bg-black/35 text-white ring-white/15 shadow-black/25 hover:bg-black/45'
          )}
          aria-label="Preview image"
        >
          <EyeSFSymbolMedium className="text-[10px] shrink-0" />
          <span className="truncate flex-1">Preview</span>
        </button>
      )}

      {/* Loading placeholder */}
      {status === 'loading' && (
        <div className="absolute inset-0 flex items-center justify-center bg-black/5 dark:bg-black/40">
          <Spinner />
        </div>
      )}

      {/* Error state */}
      {status === 'error' && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-1 text-gray-400 dark:text-gray-500 text-xs p-2">
          <svg
            className="w-6 h-6"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"
            />
          </svg>
          <span>Image unavailable</span>
        </div>
      )}

      {/* Actual image - only render when URL is resolved */}
      {resolvedSrc && (
        <img
          ref={node => {
            imageRef.current = node;
          }}
          src={resolvedSrc}
          alt="Uploaded attachment"
          className={cn(
            'attachment-image',
            'block h-auto max-w-full object-contain transition-opacity duration-200',
            status !== 'loaded' && 'opacity-0'
          )}
          style={imageStyle}
          loading={isDataUrl ? undefined : 'lazy'}
          decoding="async"
          onLoad={handleLoad}
          onError={handleError}
        />
      )}
    </figure>
  );
};
