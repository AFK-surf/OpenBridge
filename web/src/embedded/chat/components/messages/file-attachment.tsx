import { cn } from '@/utils/cn';
import { Menu } from '@/utils/webview-context-menu';
import { useCallback, useEffect, useState } from 'react';
import { ExclamationmarkTriangleFillSFSymbolMedium } from '@/assets/sf-symbols/medium/exclamationmark.triangle.fill';
import { DocumentFillSFSymbolMedium } from '@/assets/sf-symbols/medium/document.fill';
import { isVFSLikeEnvironmentId } from '@/utils/agent-file-url';
import { hasNativeJSBridge } from '@/utils/bridge-runtime';
import {
  preparePreviewAsset,
  previewAttachmentSource,
} from './file-reference-actions';
import { useResolvedUrl } from './use-resolved-url';

export interface FileAttachmentData {
  filename: string;
  contentType: string;
  path?: string;
  url?: string;
  environmentId?: string;
  size: string; // Human-readable size string (e.g., "1.5 MB"), empty for directories
}

/**
 * Request a file thumbnail from Swift native code via WebKit bridge
 * Uses QuickLook to generate a thumbnail for the file at the given path
 * Returns a base64 data URL of the file thumbnail
 */
async function requestFileThumbnail(path: string): Promise<string | null> {
  try {
    const result = await window.jsb?.MessagesBridge?.getFileIcon(path);
    return result ?? null;
  } catch {
    return null;
  }
}

function getFileExtension(filename: string): string {
  const index = filename.lastIndexOf('.');
  if (index < 0 || index === filename.length - 1) {
    return '';
  }
  return filename.slice(index + 1).toLowerCase();
}

function getFriendlyFileType(filename: string, contentType: string): string {
  const ext = getFileExtension(filename);

  switch (ext) {
    case 'md':
    case 'markdown':
    case 'mdown':
    case 'mkd':
      return 'Markdown document';
    case 'pdf':
      return 'PDF document';
    case 'txt':
    case 'log':
      return 'Text document';
    case 'json':
      return 'JSON file';
    case 'png':
      return 'PNG image';
    case 'jpg':
    case 'jpeg':
      return 'JPEG image';
    case 'gif':
      return 'GIF image';
    case 'webp':
      return 'WebP image';
    case 'mp4':
      return 'MP4 video';
    case 'mov':
      return 'QuickTime video';
    case 'mp3':
      return 'MP3 audio';
    case 'wav':
      return 'WAV audio';
  }

  switch (contentType) {
    case 'application/pdf':
      return 'PDF document';
    case 'text/plain':
      return 'Text document';
    case 'application/json':
      return 'JSON file';
    case 'image/png':
      return 'PNG image';
    case 'image/jpeg':
      return 'JPEG image';
    case 'image/gif':
      return 'GIF image';
    case 'image/webp':
      return 'WebP image';
    case 'video/mp4':
      return 'MP4 video';
    case 'audio/mpeg':
      return 'MP3 audio';
  }

  if (!contentType || contentType === 'application/octet-stream') {
    return ext ? `${ext.toUpperCase()} file` : 'File';
  }

  return contentType;
}

export function describeFileReferenceEnvironment(
  environmentId?: string
): string | null {
  const trimmed = environmentId?.trim();
  if (!trimmed || isVFSLikeEnvironmentId(trimmed)) {
    return null;
  }

  const normalized = trimmed.toLowerCase().replace(/_/g, '-');
  if (normalized === 'local-vm' || normalized.startsWith('local-vm-')) {
    return 'safe workspace on this Mac';
  }
  if (normalized === 'cloud-vm') {
    return 'safe workspace on this Mac';
  }
  if (normalized === 'local' || normalized.startsWith('local-')) {
    return 'this Mac';
  }

  return trimmed;
}

export function isWebInaccessibleFileReference({
  environmentId,
  nativeBridgeAvailable,
  path,
  url,
}: {
  environmentId?: string;
  nativeBridgeAvailable: boolean;
  path?: string;
  url?: string;
}): boolean {
  return Boolean(
    path?.trim() &&
    !url?.trim() &&
    !nativeBridgeAvailable &&
    !isVFSLikeEnvironmentId(environmentId)
  );
}

export function shouldRenderFileReferenceFallback(content: {
  url?: string | null;
  fileRef?: {
    path?: string | null;
    environmentId?: string | null;
  } | null;
}): boolean {
  return Boolean(
    !content.url &&
    content.fileRef?.path &&
    !isVFSLikeEnvironmentId(content.fileRef.environmentId)
  );
}

export function buildFileAccessRequestMessage({
  environmentId,
  environmentLabel,
  filename,
  path,
}: {
  environmentId?: string;
  environmentLabel?: string | null;
  filename: string;
  path: string;
}): string {
  const environmentLine =
    environmentLabel && environmentId && environmentLabel !== environmentId
      ? `${environmentLabel} (${environmentId})`
      : (environmentLabel ?? environmentId ?? 'unknown environment');

  return [
    'Please provide a complete, accessible version of this file attachment.',
    '',
    `File: ${filename}`,
    `Location: ${path}`,
    `Environment: ${environmentLine}`,
    '',
    'The current Bridge web view only has this incomplete file reference and cannot access the file. Please either attach/export a downloadable copy, or provide the complete information needed to access it here.',
  ].join('\n');
}

/**
 * Hook to fetch file thumbnail from Swift bridge using QuickLook
 */
function useFileThumbnail(path?: string): string | null {
  const [iconUrl, setIconUrl] = useState<string | null>(null);

  useEffect(() => {
    if (!path) {
      setIconUrl(null);
      return;
    }

    let cancelled = false;

    requestFileThumbnail(path).then(url => {
      if (!cancelled) {
        setIconUrl(url);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [path]);

  return iconUrl;
}

/**
 * File attachment card component
 */
export const FileAttachmentCard = ({
  filename,
  contentType,
  path,
  url,
  environmentId,
  size,
  className,
  onRequestFileAccess,
  ...props
}: {
  filename: string;
  contentType: string;
  path?: string;
  url?: string;
  environmentId?: string;
  size?: string;
  className?: string;
  onRequestFileAccess?: (message: string) => void | Promise<void>;
} & React.HTMLAttributes<HTMLDivElement>) => {
  const sourcePath = path?.trim() || undefined;
  const sourceUrl = url?.trim() || undefined;
  const nativeBridgeAvailable = hasNativeJSBridge();
  const [accessRequestState, setAccessRequestState] = useState<
    'idle' | 'sending' | 'sent'
  >('idle');
  const iconUrl = useFileThumbnail(sourcePath);
  const resolvedUrl = useResolvedUrl({
    src: sourceUrl,
    filePath: sourcePath,
    environmentId,
  });
  const fileType = getFriendlyFileType(filename, contentType);
  const canPreview = Boolean(
    resolvedUrl || (sourcePath && nativeBridgeAvailable)
  );
  const isUnavailableInWeb = isWebInaccessibleFileReference({
    environmentId,
    nativeBridgeAvailable,
    path: sourcePath,
    url: sourceUrl,
  });
  const environmentLabel = describeFileReferenceEnvironment(environmentId);

  useEffect(() => {
    if (!resolvedUrl) {
      return;
    }
    preparePreviewAsset(resolvedUrl, filename, contentType);
  }, [contentType, filename, resolvedUrl]);

  const handleContextMenu = useCallback(
    (event: React.MouseEvent<HTMLDivElement>) => {
      if (!canPreview) {
        return;
      }

      const menu = Menu.create().pushItem({
        title: 'Preview',
        icon: iconUrl
          ? Menu.icon.dataUrl(iconUrl)
          : Menu.icon.symbol('document'),
        onClick: () => {
          void previewAttachmentSource(resolvedUrl, {
            fileName: filename,
            mimeType: contentType,
            fallbackPath: sourcePath,
            environmentId,
          });
        },
      });

      menu.popup(event);
    },
    [
      canPreview,
      contentType,
      environmentId,
      filename,
      iconUrl,
      resolvedUrl,
      sourcePath,
    ]
  );

  const handlePreview = useCallback(() => {
    if (!canPreview) {
      return;
    }

    void previewAttachmentSource(resolvedUrl, {
      fileName: filename,
      mimeType: contentType,
      fallbackPath: sourcePath,
      environmentId,
    });
  }, [
    canPreview,
    contentType,
    environmentId,
    filename,
    resolvedUrl,
    sourcePath,
  ]);

  const handleRequestAccess = useCallback(
    async (event: React.MouseEvent<HTMLButtonElement>) => {
      event.preventDefault();
      event.stopPropagation();

      if (!sourcePath || accessRequestState !== 'idle') {
        return;
      }

      const message = buildFileAccessRequestMessage({
        environmentId,
        environmentLabel,
        filename,
        path: sourcePath,
      });

      setAccessRequestState('sending');
      try {
        if (onRequestFileAccess) {
          await onRequestFileAccess(message);
        } else {
          await window.jsb?.MessagesBridge?.sendMessage(message);
        }
        setAccessRequestState('sent');
      } catch (error) {
        console.error('Failed to request accessible file:', error);
        setAccessRequestState('idle');
      }
    },
    [
      accessRequestState,
      environmentId,
      environmentLabel,
      filename,
      onRequestFileAccess,
      sourcePath,
    ]
  );

  return (
    <div
      onContextMenu={handleContextMenu}
      onClick={canPreview ? handlePreview : undefined}
      className={cn(
        'p-3 min-w-[40%] max-w-full w-full text-left',
        'flex items-center gap-3',
        'rounded-lg border',
        'transition-colors',
        isUnavailableInWeb
          ? 'border-warning-fg/20 bg-warning-bg'
          : 'border-border bg-surface-card',
        canPreview
          ? 'cursor-pointer hover:bg-fill-soft active:bg-fill-medium'
          : 'cursor-default',
        className
      )}
      {...props}
    >
      <div className="shrink-0 w-8 h-8 flex items-center justify-center">
        {isUnavailableInWeb ? (
          <ExclamationmarkTriangleFillSFSymbolMedium
            className="text-xl text-warning-fg"
            aria-hidden="true"
          />
        ) : iconUrl ? (
          <img src={iconUrl} alt="" className="w-8 h-8 object-contain" />
        ) : (
          <DocumentFillSFSymbolMedium
            className="text-[22px] text-text-secondary"
            aria-hidden="true"
          />
        )}
      </div>
      <div className="flex-1 min-w-0 overflow-hidden">
        <div className="font-medium text-sm truncate">{filename}</div>
        <div className="text-xs text-text-secondary whitespace-nowrap">
          {fileType} {size && `• ${size}`}
        </div>
        {isUnavailableInWeb && sourcePath && (
          <div className="mt-1 space-y-1 text-[11px] leading-4">
            <div className="truncate text-text-secondary" title={sourcePath}>
              Location: {sourcePath}
            </div>
            {environmentLabel && (
              <div
                className="truncate text-text-secondary"
                title={environmentId}
              >
                Environment: {environmentLabel}
              </div>
            )}
            <div className="font-medium text-warning-fg">
              Content incomplete — file unavailable.
            </div>
            <div className="text-text-tertiary">
              Open Bridge in that environment, or ask the agent to provide a
              downloadable copy.
            </div>
            <button
              type="button"
              onClick={handleRequestAccess}
              disabled={accessRequestState !== 'idle'}
              className={cn(
                'mt-1 inline-flex h-6 items-center rounded-md border border-warning-fg/25 px-2',
                'text-[11px] font-medium leading-none text-warning-fg',
                'transition-colors hover:bg-warning-fg/10 active:bg-warning-fg/15',
                'disabled:cursor-default disabled:opacity-70',
                accessRequestState === 'sent' &&
                  'border-border bg-fill-soft text-text-tertiary hover:bg-fill-soft active:bg-fill-soft'
              )}
            >
              {accessRequestState === 'sent'
                ? 'Request sent'
                : accessRequestState === 'sending'
                  ? 'Sending request...'
                  : 'Ask agent to make accessible'}
            </button>
          </div>
        )}
      </div>
    </div>
  );
};
