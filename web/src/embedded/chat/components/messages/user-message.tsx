import {
  useCallback,
  useEffect,
  useRef,
  type HTMLAttributes,
  type MouseEvent,
} from 'react';
import type {
  SessionHistoryMessage,
  SessionHistoryMessageContent,
} from '../../types/history';
import { cn } from '@/utils/cn';
import { animate } from 'motion';
import {
  FileAttachmentCard,
  shouldRenderFileReferenceFallback,
} from './file-attachment';
import { AttachmentImage } from './attachment-image';
import { LinkifiedText } from '../linkified-text';
import { MaskedScrollArea } from '../masked-scrollarea';
import { collectUserMessageContent, CopyButton, copyUserMessage } from './copy';
import { CueStreamdownAudio } from '../markdown/overrides/audio';
import { CueStreamdownVideo } from '../markdown/overrides/video';
import { useResolvedUrl } from './use-resolved-url';
import { TextAlignleftSFSymbolMedium } from '@/assets/sf-symbols/medium/text.alignleft';
import {
  focusQuoteInContainer,
  type QuoteSelection,
} from '@/utils/chat-quote-dom';

import { Menu } from '@/utils/webview-context-menu';
import { UserMessageMinimap, useMinimapOptions } from '../minimap';
import { ArrowTurnDownRightSFSymbolMedium } from '@/assets/sf-symbols/medium/arrow.turn.down.right';

// Parse text and render <use-skill display-name="..." source-repo="...">skill_name</use-skill> tags as styled badges
function renderTextWithSkillTags(text: string): React.ReactNode[] {
  const regex =
    /<use-skill(?:\s+display-name="([^"]*)")?(?:\s+source-repo="([^"]*)")?>([^<]+)<\/use-skill>/g;
  const parts: React.ReactNode[] = [];
  let lastIndex = 0;
  let match;
  let keyIndex = 0;

  while ((match = regex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parts.push(
        <LinkifiedText
          key={keyIndex++}
          text={text.slice(lastIndex, match.index)}
        />
      );
    }
    const displayName = match[1] ? match[1].replace(/&quot;/g, '"') : match[3];
    const sourceRepo = match[2];
    const originalTag = match[0];
    parts.push(
      <span
        key={keyIndex++}
        className="inline-block px-1.5 py-0.5 rounded bg-gray-500/20 text-xs font-medium relative"
      >
        <span
          className="opacity-0 absolute inset-0 overflow-hidden whitespace-nowrap"
          data-quote-ignore="true"
          aria-hidden="true"
        >
          {originalTag}
        </span>
        <span className="select-none">
          {displayName}
          {sourceRepo && <span className="ml-1 opacity-60">{sourceRepo}</span>}
        </span>
      </span>
    );
    lastIndex = match.index + match[0].length;
  }

  if (lastIndex < text.length) {
    parts.push(<LinkifiedText key={keyIndex++} text={text.slice(lastIndex)} />);
  }

  return parts.length > 0 ? parts : [<LinkifiedText key={0} text={text} />];
}

function renderEmptyTag(text: string): string {
  return text.replace(/<empty\s*\/>/g, '');
}

const UserAudio = ({
  content,
  onRequestFileAccess,
}: {
  content: SessionHistoryMessageContent;
  onRequestFileAccess?: (message: string) => void | Promise<void>;
}) => {
  const resolvedUrl = useResolvedUrl({
    src: content.url,
    filePath: content.fileRef?.path,
    environmentId: content.fileRef?.environmentId,
  });
  if (!resolvedUrl) {
    return shouldRenderFileReferenceFallback(content) ? (
      <FileAttachmentCard
        filename={content.fileName ?? 'Audio file'}
        contentType={content.mimeType ?? 'audio/mpeg'}
        path={content.fileRef?.path}
        environmentId={content.fileRef?.environmentId ?? undefined}
        size=""
        onRequestFileAccess={onRequestFileAccess}
      />
    ) : null;
  }
  return (
    <CueStreamdownAudio
      src={resolvedUrl}
      fileName={content.fileName ?? undefined}
      mimeType={content.mimeType ?? undefined}
      sourcePath={content.fileRef?.path}
      environmentId={content.fileRef?.environmentId ?? undefined}
    />
  );
};

const UserVideo = ({
  content,
  onRequestFileAccess,
}: {
  content: SessionHistoryMessageContent;
  onRequestFileAccess?: (message: string) => void | Promise<void>;
}) => {
  const resolvedUrl = useResolvedUrl({
    src: content.url,
    filePath: content.fileRef?.path,
    environmentId: content.fileRef?.environmentId,
  });
  if (!resolvedUrl) {
    return shouldRenderFileReferenceFallback(content) ? (
      <FileAttachmentCard
        filename={content.fileName ?? 'Video file'}
        contentType={content.mimeType ?? 'video/mp4'}
        path={content.fileRef?.path}
        environmentId={content.fileRef?.environmentId ?? undefined}
        size=""
        onRequestFileAccess={onRequestFileAccess}
      />
    ) : null;
  }
  return (
    <CueStreamdownVideo
      src={resolvedUrl}
      fileName={content.fileName ?? undefined}
      mimeType={content.mimeType ?? undefined}
      sourcePath={content.fileRef?.path}
      environmentId={content.fileRef?.environmentId ?? undefined}
      className="h-48 w-auto max-w-full"
    />
  );
};

export const UserMessage = ({
  message,
  enterAnimation = false,
  onSendMessage,
}: {
  message: SessionHistoryMessage;
  enterAnimation?: boolean;
  onSendMessage?: (text: string) => void;
}) => {
  const ref = useRef<HTMLDivElement>(null);
  const minimapOptions = useMinimapOptions();

  const { audios, files, images, videos, quotes, texts } =
    collectUserMessageContent(message);
  const hasVisibleContent =
    quotes.length > 0 ||
    texts.length > 0 ||
    files.length > 0 ||
    images.length > 0 ||
    audios.length > 0 ||
    videos.length > 0;
  const canCopyMessage = texts.length > 0;
  if (!hasVisibleContent) {
    return null;
  }

  const handleContextMenu = useCallback(
    (event: MouseEvent<HTMLDivElement>) => {
      const menu = Menu.create().pushItem({
        title: 'Copy',
        icon: Menu.icon.symbol('document.on.document'),
        enabled: canCopyMessage,
        onClick: async () => {
          await copyUserMessage(message);
        },
      });

      menu.popup(event, { fallbackToSelectionMenu: true });
    },
    [canCopyMessage, message]
  );

  const handleFocusQuote = useCallback((quote: QuoteSelection['quoteRef']) => {
    const container =
      ref.current?.closest<HTMLElement>('[data-quote-container="true"]') ??
      null;
    const focusClassName =
      container?.dataset.quoteFocusClass?.trim() ||
      'conversation-message-focused';

    focusQuoteInContainer({
      container,
      quoteRef: quote,
      focusClassName,
    });
  }, []);

  return (
    <div
      ref={ref}
      onContextMenu={handleContextMenu}
      className={cn(
        'user-message',
        'w-full flex pl-10 justify-end min-w-0',
        'pt-1',
        'group'
      )}
    >
      <MessageAnimationWrapper
        enabled={enterAnimation}
        className="conversation-message-focus-target flex max-w-full flex-col items-end gap-2"
        data-message-id={message.id}
      >
        {/* Contexts */}
        <div className="flex max-w-full flex-col items-end gap-2">
          {files.length > 0 && (
            <div
              className={cn(
                'grid gap-2',
                files.length > 1 ? 'grid-cols-2' : ''
              )}
            >
              {files.map((file, i) => (
                <FileAttachmentCard
                  key={`file-${i}`}
                  filename={file.filename}
                  contentType={file.contentType}
                  path={file.path}
                  url={file.url}
                  environmentId={file.environmentId}
                  size={file.size}
                  onRequestFileAccess={onSendMessage}
                  className={cn(
                    files.length > 2 &&
                      files.length % 2 !== 0 &&
                      i === files.length - 1 &&
                      'col-start-2'
                  )}
                />
              ))}
            </div>
          )}

          {images.length > 0 && (
            <MaskedScrollArea horizontal className="w-full">
              <div className="flex gap-2">
                <div className="flex-1 min-w-0" />
                {images.map((image, i) => {
                  if (shouldRenderFileReferenceFallback(image)) {
                    return (
                      <FileAttachmentCard
                        key={`img-${i}`}
                        filename={image.fileName ?? 'Image file'}
                        contentType={image.mimeType ?? 'image/png'}
                        path={image.fileRef?.path}
                        environmentId={
                          image.fileRef?.environmentId ?? undefined
                        }
                        size=""
                        onRequestFileAccess={onSendMessage}
                        className="min-w-72 shrink-0"
                      />
                    );
                  }

                  return image.url || image.fileRef?.path ? (
                    <AttachmentImage
                      key={`img-${i}`}
                      src={image.url}
                      fileName={image.fileName ?? undefined}
                      mimeType={image.mimeType ?? undefined}
                      sourcePath={image.fileRef?.path}
                      environmentId={image.fileRef?.environmentId ?? undefined}
                      className="h-24 shrink-0"
                    />
                  ) : null;
                })}
              </div>
            </MaskedScrollArea>
          )}

          {audios.length > 0 && (
            <div className="flex flex-col gap-2 items-end">
              {audios.map((audio, i) =>
                audio.url || audio.fileRef?.path ? (
                  <UserAudio
                    key={`audio-${i}`}
                    content={audio}
                    onRequestFileAccess={onSendMessage}
                  />
                ) : null
              )}
            </div>
          )}

          {videos.length > 0 && (
            <div className="flex flex-col gap-2 items-end">
              {videos.map((video, i) =>
                video.url || video.fileRef?.path ? (
                  <UserVideo
                    key={`video-${i}`}
                    content={video}
                    onRequestFileAccess={onSendMessage}
                  />
                ) : null
              )}
            </div>
          )}
        </div>
        {/* Message bubble */}
        {quotes.length > 0 && (
          <div className="flex w-full max-w-full flex-col items-end gap-1">
            {quotes.map((quote, index) => (
              <button
                key={`quote-${index}`}
                type="button"
                className="flex max-w-[min(100%,21rem)] items-center gap-2 px-0.5 py-0.5 text-left text-xs text-muted-foreground transition-colors hover:text-foreground"
                onClick={() => handleFocusQuote(quote.quoteRef)}
              >
                <span className="shrink-0 leading-none">
                  <ArrowTurnDownRightSFSymbolMedium className="text-[8px]" />
                </span>
                <span className="truncate">{quote.text}</span>
              </button>
            ))}
          </div>
        )}
        {texts.length > 0 && (
          <div
            className={cn(
              'user-message-bubble',
              'bg-user-bubble py-2 px-3 min-w-[40px] rounded-[18px] max-w-full',
              'text-sm whitespace-pre-wrap wrap-break-word space-y-2'
            )}
            data-message-id={message.messageId ?? message.id}
            data-quote-source="true"
          >
            <div className="user-message-bubble-content">
              {texts.map((text, i) => (
                <div key={`text-${i}`}>
                  {renderTextWithSkillTags(renderEmptyTag(text))}
                </div>
              ))}
            </div>
          </div>
        )}
        {/* Actions */}
        <div className="invisible group-hover:visible flex items-center gap-2 justify-end">
          <button
            className="icon-button size-6 flex-center"
            onClick={() =>
              UserMessageMinimap.toggle(message.id, minimapOptions)
            }
          >
            <TextAlignleftSFSymbolMedium className="text-xs" />
          </button>
          <CopyButton
            className="icon-button size-6 flex-center"
            onCopy={() => copyUserMessage(message)}
          />
        </div>
      </MessageAnimationWrapper>
    </div>
  );
};

function waitUntilVisible(el: HTMLElement, timeout = 300) {
  return Promise.race([
    new Promise<void>(resolve => {
      setTimeout(() => {
        resolve();
      }, timeout);
    }),
    new Promise<void>(resolve => {
      const observer = new IntersectionObserver(entries => {
        if (entries[0].isIntersecting) {
          observer.disconnect();
          resolve();
        }
      });
      observer.observe(el);
    }),
  ]);
}

const MessageAnimationWrapper = ({
  className,
  enabled = true,
  ...props
}: HTMLAttributes<HTMLDivElement> & {
  enabled?: boolean;
}) => {
  const ref = useRef<HTMLDivElement>(null);

  const applyAnimation = useCallback(async () => {
    const el = ref.current;
    if (!el) return;

    if (!enabled) {
      el.style.opacity = '1';
      return;
    }

    await waitUntilVisible(el);
    await new Promise(resolve => setTimeout(resolve, 100));

    const box = el.getBoundingClientRect();
    const viewportSize = {
      width: window.innerWidth,
      height: window.innerHeight,
    };

    const fromXYWH = {
      x: 16,
      y: viewportSize.height + 16,
      w: viewportSize.width / 2,
      h: 32,
    };

    const toXYWH = {
      x: box.left,
      y: box.top,
      w: box.width,
      h: box.height,
    };

    animate(
      el,
      {
        y: [fromXYWH.y - toXYWH.y, 0],
        scaleX: [Math.min(2, fromXYWH.w / toXYWH.w), 1],
        scaleY: [fromXYWH.h / toXYWH.h, 1],
        opacity: [0, 1],
      },
      {
        type: 'spring',
        bounce: 0.2,
        duration: 0.5,
      }
    ).finished.then(() => {
      el.style.opacity = '1';
      el.style.transform = 'translateX(0)';
      el.style.width = 'auto';
      el.style.height = 'auto';
    });
  }, [enabled]);

  useEffect(() => {
    applyAnimation();
  }, [applyAnimation]);

  return (
    <div
      ref={ref}
      className={cn(className, 'opacity-0 origin-right')}
      {...props}
    />
  );
};
