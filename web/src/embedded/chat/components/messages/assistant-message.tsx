import { useMemo } from 'react';
import type {
  SessionHistoryMessage,
  SessionHistoryMessageContent,
  AssistantState,
} from '../../types/history';
import {
  isErrorMessage,
  isPermissionRequestMessage,
  isQuestionMessage,
  isScheduleMessage,
  isSaveFileReplyMessage,
  isSaveFileRequestMessage,
  isSandboxReviewMessage,
  isSecretInputMessage,
  isToolMessage,
  getTextContent,
  stripLeadingAppRequestTag,
} from '../../types/history';
import { ErrorBoundary } from '../error-boundary';
import { CueStreamdown } from '../markdown/streamdown';
import { CueStreamdownAudio } from '../markdown/overrides/audio';
import { CueStreamdownVideo } from '../markdown/overrides/video';
import { AttachmentImage } from './attachment-image';
import { AssistantMessageOperations } from './assistant-message-operations';
import { AssistantStateSection } from './assistant-state-section';
import {
  FileAttachmentCard,
  shouldRenderFileReferenceFallback,
} from './file-attachment';
import { PermissionMessage } from './permission-message';
import { QuestionMessage } from './question-message';
import { SaveFileMessage } from './save-file-message';
import { ScheduleMessage } from './schedule-message';
import { SandboxReviewMessage } from './sandbox-review-message';
import { SecretInputMessage } from './secret-input-message';
import { useResolvedUrl } from './use-resolved-url';
import { ErrorCard } from '../error-card';
import type { ErrorPayload } from '../error-card-utils';
import { WebBrowseWidget, tryParseWebBrowsePayload } from './web-browse-widget';
import {
  getToolCallDisplayName,
  tryParseToolCallStatusPayload,
} from '@/utils/tool-call-status';
import { cn } from '@/utils/cn';
import { DebugMessage } from '@/utils/debug-message';

const assistantMarkdownControls = {
  table: {
    fullscreen: false,
  },
} as const;

const parseDebugJSON = (raw?: string) => {
  if (!raw) return undefined;
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    return raw;
  }
};

const ToolCallStatusMessage = ({
  toolName,
  summary,
  status,
  command,
  argumentsText,
  rawPayload,
}: {
  toolName: string;
  summary?: string;
  status: 'running' | 'completed' | 'failed';
  command?: string;
  argumentsText?: string;
  rawPayload?: unknown;
}) => {
  const displayName = getToolCallDisplayName({
    toolName,
    argumentsText,
    command,
    summary,
    status,
  });
  const showSummary =
    summary?.trim() &&
    summary.trim().replaceAll('"', '') !== displayName.trim();
  const debugPayload = {
    toolName,
    status,
    displayName,
    summary,
    command,
    arguments: parseDebugJSON(argumentsText),
    rawPayload,
  };

  return (
    <DebugMessage
      asChild
      title={`Tool call: ${displayName}`}
      data={debugPayload}
    >
      <span className={cn('flex min-w-0 flex-col gap-0.5 text-text-secondary')}>
        <span className="text-sm font-medium">{displayName}</span>
        {showSummary ? (
          <span className="text-xs text-text-tertiary">{summary}</span>
        ) : null}
      </span>
    </DebugMessage>
  );
};

export type AssistantGroupItem =
  | { type: 'message'; message: SessionHistoryMessage }
  | { type: 'state'; state: AssistantState };

export type ToolMessageRenderer = (
  message: SessionHistoryMessage
) => React.ReactNode | null | undefined;

const AssistantAudio = ({
  content,
  artifactId,
  onRequestFileAccess,
}: {
  content: SessionHistoryMessageContent;
  artifactId?: string;
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
        data-artifact={artifactId}
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
      artifactId={artifactId}
    />
  );
};

const AssistantVideo = ({
  content,
  artifactId,
  onRequestFileAccess,
}: {
  content: SessionHistoryMessageContent;
  artifactId?: string;
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
        data-artifact={artifactId}
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
      className="h-64 w-auto max-w-full"
    />
  );
};

function parseStatusCode(errorMessage: string): number | undefined {
  const match = errorMessage.match(/\b([1-5]\d{2})\b/);
  if (!match) return undefined;
  const code = Number.parseInt(match[1], 10);
  if (Number.isNaN(code)) return undefined;
  return code;
}

function buildErrorPayload(
  messages: SessionHistoryMessage[]
): ErrorPayload | null {
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (!message.error) {
      // A successful, renderable message after an error means the error is stale.
      const hasRenderableContent =
        (message.content && message.content.length > 0) ||
        isPermissionRequestMessage(message) ||
        isQuestionMessage(message) ||
        isSaveFileReplyMessage(message) ||
        isSaveFileRequestMessage(message) ||
        isSandboxReviewMessage(message) ||
        isSecretInputMessage(message);
      if (hasRenderableContent) {
        return null;
      }
      continue;
    }

    const desc = message.error.trim();
    if (desc === '') {
      continue;
    }

    const payload: ErrorPayload = {
      desc,
      errorType: message.errorType,
    };
    if (message.errorType === 'http_status_code') {
      payload.statusCode = parseStatusCode(desc);
    }
    return payload;
  }
  return null;
}

function wrapMessageNode(
  message: SessionHistoryMessage,
  node: React.ReactNode,
  key: string
) {
  const targetMessageId = message.messageId ?? message.id;
  return (
    <div
      key={key}
      data-message-id={targetMessageId}
      className="conversation-message-focus-target"
    >
      {node}
    </div>
  );
}

function renderContentBlock(
  content: SessionHistoryMessageContent,
  key: string,
  isAnimating: boolean,
  messageId: string,
  onRequestFileAccess?: (message: string) => void | Promise<void>
) {
  switch (content.type) {
    case 'text':
      return content.text ? (
        <div key={key} data-message-id={messageId} data-quote-source="true">
          <CueStreamdown
            className="text-sm"
            animated={isAnimating}
            controls={assistantMarkdownControls}
          >
            {content.text}
          </CueStreamdown>
        </div>
      ) : null;
    case 'image':
      if (shouldRenderFileReferenceFallback(content)) {
        return (
          <FileAttachmentCard
            key={key}
            filename={content.fileName ?? 'Image file'}
            contentType={content.mimeType ?? 'image/png'}
            path={content.fileRef?.path}
            environmentId={content.fileRef?.environmentId ?? undefined}
            size=""
            data-artifact={key}
            onRequestFileAccess={onRequestFileAccess}
          />
        );
      }

      return content.url || content.fileRef?.path ? (
        <AttachmentImage
          key={key}
          src={content.url}
          fileName={content.fileName ?? undefined}
          mimeType={content.mimeType ?? undefined}
          sourcePath={content.fileRef?.path}
          environmentId={content.fileRef?.environmentId ?? undefined}
          className="max-h-80 w-fit"
          data-artifact={key}
        />
      ) : null;
    case 'audio':
      return content.url || content.fileRef?.path ? (
        <AssistantAudio
          key={key}
          content={content}
          artifactId={key}
          onRequestFileAccess={onRequestFileAccess}
        />
      ) : null;
    case 'video':
      if (content.url || content.fileRef?.path) {
        return (
          <AssistantVideo
            key={key}
            content={content}
            artifactId={key}
            onRequestFileAccess={onRequestFileAccess}
          />
        );
      }
      return null;
    case 'file':
      if (!content.url && !content.fileRef?.path) {
        return null;
      }
      return (
        <FileAttachmentCard
          key={key}
          filename={content.fileName ?? 'Unknown file'}
          contentType={content.mimeType ?? 'application/octet-stream'}
          path={content.fileRef?.path}
          url={content.url ?? undefined}
          environmentId={content.fileRef?.environmentId ?? undefined}
          size=""
          data-artifact={key}
          onRequestFileAccess={onRequestFileAccess}
        />
      );
    default:
      return null;
  }
}

export const AssistantMessage = ({
  items,
  allMessages,
  currentAssistantStateSequence,
  userMessageId,
  isLast,
  isStreaming,
  isAnimating = false,
  hideOperations = false,
  renderToolMessage,
  onSendMessage,
}: {
  items: AssistantGroupItem[];
  allMessages: SessionHistoryMessage[];
  currentAssistantStateSequence?: number;
  userMessageId?: string;
  isLast?: boolean;
  isStreaming?: boolean;
  isAnimating?: boolean;
  hideOperations?: boolean;
  renderToolMessage?: ToolMessageRenderer;
  onSendMessage?: (text: string) => void;
}) => {
  const hasCurrentExecutionState = items.some(
    item =>
      item.type === 'state' &&
      item.state.phase === 'execution' &&
      item.state.sequence === currentAssistantStateSequence
  );
  const messages = useMemo(
    () =>
      items
        .filter(
          (i): i is AssistantGroupItem & { type: 'message' } =>
            i.type === 'message'
        )
        .map(i => i.message),
    [items]
  );

  const errorPayload = useMemo(() => buildErrorPayload(messages), [messages]);
  const containsCurrentInProgressState = items.some(
    item =>
      item.type === 'state' &&
      item.state.sequence === currentAssistantStateSequence &&
      (item.state.phase === 'thinking' || item.state.phase === 'execution')
  );
  const visibleToolEntries = useMemo(() => {
    const orderedEntryIds: string[] = [];
    const entriesById = new Map<
      string,
      {
        toolUseId?: string;
        node: React.ReactNode;
      }
    >();

    for (const message of messages) {
      if (!isToolMessage(message)) {
        continue;
      }

      const texts = getTextContent(message);
      for (let textIndex = 0; textIndex < texts.length; textIndex += 1) {
        const text = texts[textIndex];

        const payload = tryParseWebBrowsePayload(text);
        if (payload) {
          const completed =
            message.toolUseId != null &&
            allMessages.some(
              m =>
                m !== message &&
                isToolMessage(m) &&
                m.toolUseId === message.toolUseId &&
                m.timestamp > message.timestamp
            );
          if (completed) {
            continue;
          }

          const entryId =
            message.toolUseId ??
            message.id ??
            `tool-payload-${message.timestamp}-${textIndex}`;
          if (!entriesById.has(entryId)) {
            orderedEntryIds.push(entryId);
          }
          entriesById.set(entryId, {
            toolUseId: message.toolUseId ?? undefined,
            node: (
              <WebBrowseWidget
                key={message.id || `tool-${textIndex}`}
                payload={payload}
              />
            ),
          });
          continue;
        }

        const toolStatus = tryParseToolCallStatusPayload(text);
        if (!toolStatus) {
          continue;
        }

        const entryId =
          message.toolUseId ??
          message.id ??
          `tool-status-${message.timestamp}-${textIndex}`;
        if (!entriesById.has(entryId)) {
          orderedEntryIds.push(entryId);
        }
        entriesById.set(entryId, {
          toolUseId: message.toolUseId ?? undefined,
          node: (
            <ToolCallStatusMessage
              key={message.id || `tool-status-${textIndex}`}
              toolName={toolStatus.tool_name}
              summary={toolStatus.summary}
              status={toolStatus.status}
              command={toolStatus.command}
              argumentsText={toolStatus.arguments}
              rawPayload={toolStatus}
            />
          ),
        });
      }
    }

    return orderedEntryIds
      .map(entryId => entriesById.get(entryId))
      .filter(
        (entry): entry is NonNullable<typeof entry> => entry !== undefined
      );
  }, [allMessages, messages]);
  const visibleToolCallIds = useMemo(() => {
    return new Set(
      visibleToolEntries
        .map(entry => entry.toolUseId)
        .filter((toolUseId): toolUseId is string => Boolean(toolUseId))
    );
  }, [visibleToolEntries]);
  const visibleToolNodes = useMemo(
    () =>
      visibleToolEntries.map((entry, index) => (
        <div key={`tool-entry-${index}`}>{entry.node}</div>
      )),
    [visibleToolEntries]
  );

  const hasRenderableMessageContent = useMemo(
    () =>
      messages.some(message => {
        if (isErrorMessage(message) || isToolMessage(message)) {
          return false;
        }

        return (
          (message.content?.length ?? 0) > 0 ||
          isPermissionRequestMessage(message) ||
          isQuestionMessage(message) ||
          isSaveFileReplyMessage(message) ||
          isSaveFileRequestMessage(message) ||
          isSandboxReviewMessage(message) ||
          isScheduleMessage(message) ||
          isSecretInputMessage(message)
        );
      }) || !!errorPayload,
    [errorPayload, messages]
  );
  const showOperations =
    hasRenderableMessageContent &&
    !hideOperations &&
    !containsCurrentInProgressState &&
    !(isLast && isStreaming);

  let renderedSyntheticExecution = false;
  const renderedItems = items.flatMap((item, itemIndex) => {
    if (item.type === 'state') {
      if (item.state.phase !== 'thinking' && item.state.phase !== 'execution') {
        return [];
      }

      const isCurrentState =
        currentAssistantStateSequence !== undefined &&
        item.state.sequence === currentAssistantStateSequence;

      if (item.state.phase === 'execution' && !isCurrentState) {
        return [];
      }

      return [
        <AssistantStateSection
          key={`state-${item.state.sequence}`}
          state={item.state}
          isCurrent={isCurrentState}
          inlineTools={item.state.tools.filter(
            tool => !visibleToolCallIds.has(tool.callId)
          )}
          inlineEntries={
            item.state.phase === 'execution' ? visibleToolNodes : undefined
          }
        />,
      ];
    }

    const msg = item.message;

    if (isSandboxReviewMessage(msg)) {
      return [
        wrapMessageNode(
          msg,
          <SandboxReviewMessage message={msg} />,
          msg.id || `sr-${itemIndex}`
        ),
      ];
    }

    if (isQuestionMessage(msg)) {
      return [
        wrapMessageNode(
          msg,
          <QuestionMessage message={msg} messages={allMessages} />,
          msg.id || `q-${itemIndex}`
        ),
      ];
    }

    if (isPermissionRequestMessage(msg)) {
      return [
        wrapMessageNode(
          msg,
          <PermissionMessage message={msg} messages={allMessages} />,
          msg.id || `perm-${itemIndex}`
        ),
      ];
    }

    if (isScheduleMessage(msg)) {
      return [
        wrapMessageNode(
          msg,
          <ScheduleMessage message={msg} />,
          msg.id || `schedule-${itemIndex}`
        ),
      ];
    }

    if (isSaveFileRequestMessage(msg)) {
      return [
        wrapMessageNode(
          msg,
          <SaveFileMessage message={msg} messages={allMessages} />,
          msg.id || `save-file-${itemIndex}`
        ),
      ];
    }

    if (isSaveFileReplyMessage(msg)) {
      return [
        wrapMessageNode(
          msg,
          <SaveFileMessage message={msg} messages={allMessages} />,
          msg.id || `save-file-reply-${itemIndex}`
        ),
      ];
    }

    if (isSecretInputMessage(msg)) {
      return [
        wrapMessageNode(
          msg,
          <SecretInputMessage message={msg} messages={allMessages} />,
          msg.id || `secret-${itemIndex}`
        ),
      ];
    }

    if (isToolMessage(msg)) {
      const customNode = renderToolMessage?.(msg);
      if (customNode) {
        return [
          wrapMessageNode(
            msg,
            <div className="flex flex-col items-start gap-2">{customNode}</div>,
            msg.id || `custom-tool-${itemIndex}`
          ),
        ];
      }

      if (hasCurrentExecutionState || renderedSyntheticExecution) {
        return [];
      }

      if (visibleToolNodes.length === 0) {
        return [];
      }

      renderedSyntheticExecution = true;
      const toolTimestamps = messages
        .filter(candidate => isToolMessage(candidate))
        .map(candidate => candidate.timestamp);
      const firstTimestamp = Math.min(...toolTimestamps, msg.timestamp);
      const lastTimestamp = Math.max(...toolTimestamps, msg.timestamp);
      const syntheticExecutionState: AssistantState = {
        phase: 'execution',
        sequence: -1,
        phaseStartedAt: firstTimestamp,
        updatedAt: lastTimestamp,
        tools: [],
        asyncToolcalls: [],
      };

      return [
        wrapMessageNode(
          msg,
          <AssistantStateSection
            state={syntheticExecutionState}
            isCurrent={false}
            inlineEntries={visibleToolNodes}
          />,
          `synthetic-execution-${msg.id || itemIndex}`
        ),
      ];
    }

    if (isErrorMessage(msg)) {
      // Pure error messages — handled by errorPayload below
      return [];
    }

    // Assistant message: render content blocks. Strip the leading
    // `<app-request …/>` tag from the first text block so the host-capability
    // marker the agent uses to request location / other skills never appears
    // in the rendered bubble.
    const rawContents = msg.content ?? [];
    const contents = rawContents
      .map((content, ci) => {
        const prepared =
          ci === 0 && content.type === 'text' && content.text
            ? { ...content, text: stripLeadingAppRequestTag(content.text) }
            : content;
        return renderContentBlock(
          prepared,
          `${msg.id || itemIndex}-${ci}`,
          isAnimating,
          msg.messageId ?? msg.id,
          onSendMessage
        );
      })
      .filter(Boolean);

    if (contents.length === 0) {
      return [];
    }

    return [
      <div
        key={msg.id || `assistant-message-${itemIndex}`}
        className={cn('conversation-message-focus-target flex flex-col gap-2')}
        data-message-id={msg.messageId ?? msg.id}
      >
        {contents}
      </div>,
    ];
  });

  return (
    <div className="flex flex-col gap-1">
      <ErrorBoundary>
        <div className="flex flex-col gap-2">
          {errorPayload ? (
            <ErrorCard
              error={errorPayload}
              onRetry={
                window.jsb?.MessagesBridge?.retryMessage
                  ? () => {
                      window.jsb.MessagesBridge.retryMessage().catch(() => {
                        console.error(
                          '[AssistantMessage] retry message failed'
                        );
                      });
                    }
                  : undefined
              }
            />
          ) : null}

          {renderedItems}
        </div>
      </ErrorBoundary>

      {showOperations ? (
        <AssistantMessageOperations
          messages={messages}
          userMessageId={userMessageId}
        />
      ) : null}
    </div>
  );
};
