import { useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import type {
  SessionHistoryMessage,
  AssistantState,
} from '../../types/history';
import type { FollowUpState } from '@/jsb';
import {
  ScrollToBottomAnchor,
  ScrollToBottomProvider,
  ScrollToBottomTrigger,
} from '../scroll-to-bottom';
import { FollowUpBar } from './follow-up-bar';
import { globalVar } from '../../global-css-var';
import {
  ConversationMessageGroupView,
  conversationGroupKey,
  useConversationMessageGroups,
} from './conversation-thread';
import { splitCurrentConversationGroups } from './assistant-turn';

export const Messages = ({
  messages,
  assistantStateSequence,
  isStreaming,
  followUpState,
  pagePaddingTop = 0,
  enableAutoScroll,
  onSendMessage,
}: {
  messages: SessionHistoryMessage[];
  assistantStateSequence: AssistantState[];
  isStreaming: boolean;
  followUpState: FollowUpState;
  pagePaddingTop?: number;
  enableAutoScroll: boolean;
  onSendMessage: (text: string) => void;
}) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const { allMessages, currentAssistantState, groupedMessages } =
    useConversationMessageGroups({
      messages,
      assistantStateSequence,
    });

  useEffect(() => {
    if (!enableAutoScroll) {
      return;
    }

    if (!isStreaming) {
      return;
    }

    if (groupedMessages.at(-1)?.type !== 'user') {
      return;
    }

    const currentConversationEl = containerRef.current?.querySelector(
      '.current-conversation'
    );
    if (!currentConversationEl) {
      return;
    }

    const timeout = setTimeout(() => {
      currentConversationEl.scrollIntoView({
        block: 'start',
        behavior: 'smooth',
      });
    }, 100);
    return () => clearTimeout(timeout);
  }, [enableAutoScroll, groupedMessages, isStreaming]);

  const lastAssistantIndex = groupedMessages.findLastIndex(
    g => g.type === 'assistant'
  );
  const { historyGroups, currentGroups } =
    splitCurrentConversationGroups(groupedMessages);

  return (
    <ScrollToBottomProvider enableAutoScroll={enableAutoScroll}>
      <div className="flex flex-col gap-4" ref={containerRef}>
        {historyGroups.map((group, index) => (
          <ConversationMessageGroupView
            key={conversationGroupKey(group, index)}
            group={group}
            index={index}
            totalGroups={groupedMessages.length}
            lastAssistantIndex={lastAssistantIndex}
            allMessages={allMessages}
            currentAssistantStateSequence={currentAssistantState?.sequence}
            isStreaming={isStreaming}
            onSendMessage={onSendMessage}
          />
        ))}
        <div
          className="current-conversation hide-if-empty flex flex-col gap-4 pb-10"
          style={{
            minHeight: `calc(100dvh - ${globalVar('activityCenterHeight')} - ${pagePaddingTop}px)`,
          }}
        >
          {currentGroups.map((group, localIndex) => {
            const index = historyGroups.length + localIndex;
            return (
              <ConversationMessageGroupView
                key={conversationGroupKey(group, index)}
                group={group}
                index={index}
                totalGroups={groupedMessages.length}
                lastAssistantIndex={lastAssistantIndex}
                allMessages={allMessages}
                currentAssistantStateSequence={currentAssistantState?.sequence}
                isStreaming={isStreaming}
                onSendMessage={onSendMessage}
              />
            );
          })}
          <FollowUpBar
            items={followUpState.items}
            isGenerating={followUpState.isGenerating}
            show={!isStreaming && groupedMessages.length > 0}
            onSendMessage={onSendMessage}
          />
        </div>
      </div>

      <div
        className="h-0 w-full"
        style={{
          paddingBottom: globalVar('activityCenterHeight'),
        }}
      />

      {groupedMessages.length > 0 ? <ScrollToBottomAnchor /> : null}

      {createPortal(
        <ScrollToBottomTrigger
          className="fixed left-1/2 -translate-x-1/2"
          style={{
            bottom: `calc(${globalVar('activityCenterHeight')} + 16px)`,
          }}
        />,
        document.body
      )}
    </ScrollToBottomProvider>
  );
};
