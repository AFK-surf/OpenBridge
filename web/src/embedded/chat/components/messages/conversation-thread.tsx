import { useMemo } from 'react';
import type {
  AssistantState,
  SessionHistoryMessage,
} from '../../types/history';
import {
  isAssistantMessage,
  isCompactedContextMessage,
  isErrorMessage,
  isMessageStartMessage,
  isPermissionRequestMessage,
  isQuestionMessage,
  isSaveFileReplyMessage,
  isSaveFileRequestMessage,
  isSandboxReviewMessage,
  isScheduleMessage,
  isSecretInputMessage,
  isToolMessage,
  isUserMessage,
  stripLeadingAppRequestTag,
} from '../../types/history';
import { cn } from '@/utils/cn';
import { ErrorBoundary } from '../error-boundary';
import { AssistantMessage } from './assistant-message';
import {
  getActiveAssistantTurn,
  groupConversationTimelineItems,
  shouldHideAssistantOperations,
  type ConversationTimelineItem,
  type ConversationMessageGroup,
} from './assistant-turn';
import type { ToolMessageRenderer } from './assistant-message';
import { UserMessage } from './user-message';
import { DebugMessage } from '@/utils/debug-message';

const buildSyntheticAssistantMessage = (
  id: string,
  timestamp: number,
  text: string
): SessionHistoryMessage => ({
  id,
  type: 'message',
  role: 'assistant',
  timestamp,
  content: [{ type: 'text', text: stripLeadingAppRequestTag(text) }],
});

export function conversationGroupKey(
  group: ConversationMessageGroup,
  fallbackIndex: number
): string {
  if (group.type === 'user') {
    return group.message.id || `user-${fallbackIndex}`;
  }

  if (group.userMessageId) {
    return `assistant-turn-${group.userMessageId}`;
  }

  const firstItem = group.items[0];
  if (firstItem?.type === 'message') {
    return `assistant-message-${firstItem.message.messageId ?? firstItem.message.id ?? fallbackIndex}`;
  }

  if (firstItem?.type === 'state') {
    return `assistant-state-${firstItem.state.sequence}`;
  }

  return `assistant-${fallbackIndex}`;
}

export function useConversationMessageGroups({
  messages,
  assistantStateSequence,
}: {
  messages: SessionHistoryMessage[];
  assistantStateSequence: AssistantState[];
}) {
  const sortedAssistantStateSequence = useMemo(
    () =>
      [...assistantStateSequence].sort((a, b) => {
        if (a.sequence !== b.sequence) {
          return a.sequence - b.sequence;
        }
        return a.phaseStartedAt - b.phaseStartedAt;
      }),
    [assistantStateSequence]
  );

  const currentAssistantState =
    sortedAssistantStateSequence[sortedAssistantStateSequence.length - 1] ??
    null;
  const currentMessagingState =
    currentAssistantState?.phase === 'messaging' &&
    currentAssistantState.messaging
      ? currentAssistantState.messaging
      : null;

  const allMessages = useMemo(() => {
    const nextMessages: SessionHistoryMessage[] = [];
    const anchoredMessageIds = new Set<string>();
    const assistantMessagesById = new Map<string, SessionHistoryMessage>();

    for (const message of messages) {
      if (isAssistantMessage(message) && message.id) {
        assistantMessagesById.set(message.id, message);
      }
    }

    for (const message of messages) {
      if (isMessageStartMessage(message)) {
        const targetMessageId = message.messageId;
        if (!targetMessageId || anchoredMessageIds.has(targetMessageId)) {
          continue;
        }

        anchoredMessageIds.add(targetMessageId);

        const finalMessage = assistantMessagesById.get(targetMessageId);
        if (finalMessage) {
          nextMessages.push({
            ...finalMessage,
            timestamp: message.timestamp,
          });
          continue;
        }

        if (
          currentMessagingState?.messageId === targetMessageId &&
          currentMessagingState.text.length > 0
        ) {
          nextMessages.push(
            buildSyntheticAssistantMessage(
              targetMessageId,
              message.timestamp,
              currentMessagingState.text
            )
          );
        }
        continue;
      }

      if (
        isAssistantMessage(message) &&
        message.id &&
        anchoredMessageIds.has(message.id)
      ) {
        continue;
      }

      nextMessages.push(message);
    }

    const fallbackMessageId = currentMessagingState?.messageId;
    const hasMessageStartAnchor = fallbackMessageId
      ? messages.some(
          message =>
            isMessageStartMessage(message) &&
            message.messageId === fallbackMessageId
        )
      : false;
    const existsInHistory = fallbackMessageId
      ? messages.some(message => message.id === fallbackMessageId)
      : false;

    if (
      fallbackMessageId &&
      currentMessagingState?.text.length &&
      !existsInHistory &&
      !hasMessageStartAnchor
    ) {
      nextMessages.push(
        buildSyntheticAssistantMessage(
          fallbackMessageId,
          currentAssistantState?.updatedAt ?? Date.now(),
          currentMessagingState.text
        )
      );
    }

    return nextMessages;
  }, [messages, currentAssistantState, currentMessagingState]);

  const groupedMessages = useMemo(() => {
    const items: ConversationTimelineItem[] = [];

    for (const message of allMessages) {
      if (isUserMessage(message) && isCompactedContextMessage(message)) {
        continue;
      }
      if (
        isUserMessage(message) ||
        isAssistantMessage(message) ||
        isErrorMessage(message) ||
        isSandboxReviewMessage(message) ||
        isQuestionMessage(message) ||
        isScheduleMessage(message) ||
        isSaveFileReplyMessage(message) ||
        isSaveFileRequestMessage(message) ||
        isPermissionRequestMessage(message) ||
        isSecretInputMessage(message) ||
        isToolMessage(message)
      ) {
        items.push({ type: 'message', message });
      }
    }

    for (const state of sortedAssistantStateSequence) {
      if (state.phase === 'idle') {
        continue;
      }
      if (
        state.phase === 'messaging' &&
        state.messaging?.isStreaming !== true
      ) {
        continue;
      }
      if (state.phase === 'thinking' || state.phase === 'execution') {
        items.push({ type: 'state', state });
      }
    }

    items.sort((a, b) => {
      const tsA =
        a.type === 'message' ? a.message.timestamp : a.state.phaseStartedAt;
      const tsB =
        b.type === 'message' ? b.message.timestamp : b.state.phaseStartedAt;
      if (tsA !== tsB) {
        return tsA - tsB;
      }
      if (a.type === 'state' && b.type === 'message') {
        return isUserMessage(b.message) ? 1 : -1;
      }
      if (a.type === 'message' && b.type === 'state') {
        return isUserMessage(a.message) ? -1 : 1;
      }
      return 0;
    });

    return groupConversationTimelineItems(
      items,
      getActiveAssistantTurn(allMessages, currentAssistantState)
    );
  }, [allMessages, currentAssistantState, sortedAssistantStateSequence]);

  const activeTurnUserMessageId = useMemo(
    () =>
      getActiveAssistantTurn(allMessages, currentAssistantState).userMessageId,
    [allMessages, currentAssistantState]
  );

  return {
    allMessages,
    currentAssistantState,
    groupedMessages,
    activeTurnUserMessageId,
  };
}

export const ConversationMessageGroupView = ({
  group,
  index,
  totalGroups,
  lastAssistantIndex,
  allMessages,
  currentAssistantStateSequence,
  activeTurnUserMessageId,
  isStreaming,
  renderToolMessage,
  onSendMessage,
}: {
  group: ConversationMessageGroup;
  index: number;
  totalGroups: number;
  lastAssistantIndex: number;
  allMessages: SessionHistoryMessage[];
  currentAssistantStateSequence?: number;
  activeTurnUserMessageId?: string;
  isStreaming: boolean;
  renderToolMessage?: ToolMessageRenderer;
  onSendMessage?: (text: string) => void;
}) => {
  switch (group.type) {
    case 'user':
      return (
        <ErrorBoundary key={group.message.id || index.toString()}>
          <DebugMessage data={group}>
            <UserMessage
              message={group.message}
              enterAnimation={isStreaming && index === totalGroups - 1}
              onSendMessage={onSendMessage}
            />
          </DebugMessage>
        </ErrorBoundary>
      );
    case 'assistant': {
      const isLastAssistant = index === lastAssistantIndex;
      const isActiveAssistantTurn = isStreaming && index === totalGroups - 1;
      const hideOperations = shouldHideAssistantOperations(
        group.userMessageId,
        activeTurnUserMessageId
      );

      return (
        <ErrorBoundary key={conversationGroupKey(group, index)}>
          <DebugMessage data={group}>
            <AssistantMessage
              items={group.items}
              allMessages={allMessages}
              currentAssistantStateSequence={currentAssistantStateSequence}
              userMessageId={group.userMessageId}
              isLast={isLastAssistant}
              isStreaming={isActiveAssistantTurn}
              isAnimating={isActiveAssistantTurn}
              hideOperations={hideOperations}
              renderToolMessage={renderToolMessage}
              onSendMessage={onSendMessage}
            />
          </DebugMessage>
        </ErrorBoundary>
      );
    }
    default:
      return null;
  }
};

export const ConversationThread = ({
  messages,
  assistantStateSequence,
  isStreaming,
  className,
  renderToolMessage,
  onSendMessage,
}: {
  messages: SessionHistoryMessage[];
  assistantStateSequence: AssistantState[];
  isStreaming: boolean;
  className?: string;
  renderToolMessage?: ToolMessageRenderer;
  onSendMessage?: (text: string) => void;
}) => {
  const {
    allMessages,
    currentAssistantState,
    groupedMessages,
    activeTurnUserMessageId,
  } = useConversationMessageGroups({
    messages,
    assistantStateSequence,
  });

  const lastAssistantIndex = groupedMessages.findLastIndex(
    group => group.type === 'assistant'
  );
  return (
    <div className={cn('flex flex-col gap-4', className)}>
      {groupedMessages.map((group, index) => (
        <ConversationMessageGroupView
          key={conversationGroupKey(group, index)}
          group={group}
          index={index}
          totalGroups={groupedMessages.length}
          lastAssistantIndex={lastAssistantIndex}
          allMessages={allMessages}
          currentAssistantStateSequence={currentAssistantState?.sequence}
          activeTurnUserMessageId={activeTurnUserMessageId}
          isStreaming={isStreaming}
          renderToolMessage={renderToolMessage}
          onSendMessage={onSendMessage}
        />
      ))}
    </div>
  );
};
