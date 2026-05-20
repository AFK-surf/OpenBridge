import { useEffect, useState, type HTMLAttributes } from 'react';
import type {
  SessionHistoryMessage,
  SessionHistoryMessageContent,
} from '../../types/history';
import { getUserDisplayTextContent, getTextContent } from '../../types/history';
import type { FileAttachmentData } from './file-attachment';
import type { QuoteContent } from '@/utils/chat-quote';
import { isQuoteContent } from '@/utils/chat-quote';
import { CheckmarkSFSymbolMedium } from '@/assets/sf-symbols/medium/checkmark';
import { DocumentOnDocumentSFSymbolMedium } from '@/assets/sf-symbols/medium/document.on.document';

type CollectedContent = {
  files: FileAttachmentData[];
  images: SessionHistoryMessageContent[];
  audios: SessionHistoryMessageContent[];
  videos: SessionHistoryMessageContent[];
  quotes: QuoteContent[];
  texts: string[];
};

export function collectUserMessageContent(
  message: SessionHistoryMessage
): CollectedContent {
  const result: CollectedContent = {
    files: [],
    images: [],
    audios: [],
    videos: [],
    quotes: [],
    texts: [],
  };
  if (!message.content) return result;
  let didCollectUserTexts = false;

  for (const c of message.content) {
    if (isQuoteContent(c)) {
      result.quotes.push(c);
    } else if (c.type === 'text' && c.text) {
      if (message.role === 'user') {
        if (didCollectUserTexts) {
          continue;
        }
        result.texts.push(...getUserDisplayTextContent(message));
        didCollectUserTexts = true;
      } else {
        result.texts.push(c.text);
      }
    } else if (c.type === 'image' && (c.url || c.fileRef?.path)) {
      result.images.push(c);
    } else if (c.type === 'audio') {
      result.audios.push(c);
    } else if (c.type === 'video') {
      result.videos.push(c);
    } else if (c.type === 'file' && (c.url || c.fileRef?.path)) {
      result.files.push({
        filename: c.fileName ?? 'unknown',
        contentType: c.mimeType ?? 'application/octet-stream',
        path: c.fileRef?.path,
        url: c.url ?? undefined,
        environmentId: c.fileRef?.environmentId ?? undefined,
        size: '',
      });
    }
  }

  return result;
}

export function collectAssistantMessagesContent(
  messages: SessionHistoryMessage[]
): string[] {
  return messages.flatMap(m => getTextContent(m));
}

export const copyUserMessage = async (message: SessionHistoryMessage) => {
  const { texts } = collectUserMessageContent(message);
  await navigator.clipboard?.writeText(texts.join('\n'));
  window.jsb?.MessagesBridge?.trackCopyFromChat('user_message');
  return true;
};

export const copyAssistantMessages = async (
  messages: SessionHistoryMessage[]
) => {
  const texts = collectAssistantMessagesContent(messages);
  await navigator.clipboard?.writeText(texts.join('\n'));
  window.jsb?.MessagesBridge?.trackCopyFromChat('assistant_message');
  return true;
};

export const CopyButton = ({
  onCopy,
  onClick,
  ...props
}: HTMLAttributes<HTMLButtonElement> & {
  onCopy: () => Promise<boolean>;
}) => {
  const [isCopied, setIsCopied] = useState(false);

  useEffect(() => {
    if (isCopied) {
      setTimeout(() => {
        setIsCopied(false);
      }, 1000);
    }
  }, [isCopied]);

  return (
    <button
      {...props}
      onClick={async e => {
        onClick?.(e);
        const success = await onCopy?.();
        if (success) {
          setIsCopied(true);
        }
      }}
    >
      {isCopied ? (
        <CheckmarkSFSymbolMedium className="text-xs" />
      ) : (
        <DocumentOnDocumentSFSymbolMedium />
      )}
    </button>
  );
};
