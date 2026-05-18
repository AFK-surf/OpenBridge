import { useCallback, useEffect, useRef, useState } from 'react';
import type {
  SessionHistoryMessage,
  AssistantState,
  WorkspaceState,
} from '../types/history';
import type { FollowUpState, QuoteFocusEvent } from '@/jsb';
import { replaceSchedules } from '../stores/schedule-store';

const terminalAssistantPhases = new Set([
  'cancelled',
  'completed',
  'failed',
  'idle',
]);

export function deriveIsStreamingFromBridgeState(
  bridgeIsStreaming: boolean,
  assistantStateSequence: AssistantState[]
): boolean {
  if (bridgeIsStreaming) {
    return true;
  }

  const currentAssistantState =
    assistantStateSequence[assistantStateSequence.length - 1] ?? null;
  if (currentAssistantState?.phase === undefined) {
    return false;
  }

  return !terminalAssistantPhases.has(
    currentAssistantState.phase.trim().toLowerCase()
  );
}

export const useChatSwiftBridge = () => {
  const [paddingTop, setPaddingTop] = useState(0);
  const [bridgeIsStreaming, setBridgeIsStreaming] = useState(false);
  const [hasOpenTask, setHasOpenTask] = useState(false);
  const [messages, setMessages] = useState<SessionHistoryMessage[]>([]);
  const [assistantStateSequence, setAssistantStateSequence] = useState<
    AssistantState[]
  >([]);
  const [workspaceState, setWorkspaceState] = useState<WorkspaceState | null>(
    null
  );
  const [followUpState, setFollowUpState] = useState<FollowUpState>({
    items: [],
    isGenerating: false,
  });
  const [restoreScrollTop, setRestoreScrollTop] = useState<number | null>(null);
  const [historyInitVersion, setHistoryInitVersion] = useState(0);
  const [queuedMessage, setQueuedMessage] = useState<string | null>(null);
  const [focusMessageId, setFocusMessageId] = useState<string | null>(null);
  const [focusMessageRequest, setFocusMessageRequest] = useState<{
    messageId: string;
    requestId: number;
  } | null>(null);
  const [focusQuoteRequest, setFocusQuoteRequest] =
    useState<QuoteFocusEvent | null>(null);
  const isStreaming = deriveIsStreamingFromBridgeState(
    bridgeIsStreaming,
    assistantStateSequence
  );
  const isStreamingRef = useRef(isStreaming);
  const focusMessageRequestIdRef = useRef(0);

  useEffect(() => {
    isStreamingRef.current = isStreaming;
  }, [isStreaming]);

  useEffect(() => {
    if (isStreaming || queuedMessage === null) {
      return;
    }
    const text = queuedMessage;
    setQueuedMessage(null);
    window.jsb.MessagesBridge.sendMessage(text).catch(() => {});
  }, [isStreaming, queuedMessage]);

  useEffect(() => {
    if (isStreaming) {
      return;
    }

    const bridge = window.jsb
      .MessagesBridge as typeof window.jsb.MessagesBridge & {
      getWorkspaceState?: () => Promise<WorkspaceState | null | undefined>;
    };

    const refreshWorkspaceState = () => {
      bridge
        .getWorkspaceState?.()
        .then(state => {
          setWorkspaceState(state ?? null);
        })
        .catch(() => {});
    };

    refreshWorkspaceState();
    const intervalId = window.setInterval(refreshWorkspaceState, 1000);
    return () => {
      window.clearInterval(intervalId);
    };
  }, [isStreaming, messages.length]);

  const sendOrQueueMessage = useCallback((text: string) => {
    if (isStreamingRef.current) {
      setQueuedMessage(text);
      return;
    }

    window.jsb.MessagesBridge.sendMessage(text).catch(() => {});
  }, []);

  const cancelQueuedMessage = useCallback(() => {
    setQueuedMessage(null);
  }, []);

  useEffect(() => {
    window.jsb.MessagesBridge.getSchedules()
      .then(schedules => {
        replaceSchedules(schedules ?? []);
      })
      .catch(() => {});

    const upsertAssistantState = (state: AssistantState | null | undefined) => {
      const next = state ?? null;
      if (!next) {
        setAssistantStateSequence([]);
        return;
      }
      if (!Number.isFinite(next.sequence)) {
        return;
      }
      setAssistantStateSequence(prev => {
        const index = prev.findIndex(item => item.sequence === next.sequence);
        if (index === -1) {
          return [...prev, next].sort((a, b) => a.sequence - b.sequence);
        }
        const updated = [...prev];
        updated[index] = next;
        return updated;
      });
    };

    const unsubHistoryInit = window.jsb.MessagesBridge.onHistoryInit(
      payload => {
        const nextMessages = payload?.messages ?? [];
        setMessages(nextMessages);
        setAssistantStateSequence([]);
        setHistoryInitVersion(version => version + 1);
        setRestoreScrollTop(
          typeof payload?.scrollTop === 'number' &&
            Number.isFinite(payload.scrollTop)
            ? payload.scrollTop
            : null
        );
        window.jsb.MessagesBridge.getAssistantState()
          .then(upsertAssistantState)
          .catch(() => {});
      }
    );

    const unsubHistoryMessageAdded =
      window.jsb.MessagesBridge.onHistoryMessageAdded(message => {
        setMessages(prev => {
          const index = prev.findIndex(item => item.id === message.id);
          if (index === -1) {
            return [...prev, message];
          }
          const updated = [...prev];
          updated[index] = message;
          return updated;
        });
      });

    const unsubIsStreaming = window.jsb.MessagesBridge.onIsStreaming(
      streaming => {
        setBridgeIsStreaming(streaming);
      }
    );

    const unsubHasOpenTask = window.jsb.MessagesBridge.onHasOpenTask(
      nextHasOpenTask => {
        setHasOpenTask(nextHasOpenTask);
      }
    );

    const unsubAssistantState = window.jsb.MessagesBridge.onAssistantState(
      state => {
        upsertAssistantState(state);
      }
    );

    const unsubWorkspaceState = window.jsb.MessagesBridge.onWorkspaceState(
      state => {
        setWorkspaceState(state ?? null);
      }
    );

    const unsubPaddingTop = window.jsb.MessagesBridge.onPaddingTop(padding => {
      setPaddingTop(padding);
    });

    const unsubFollowUpState = window.jsb.MessagesBridge.onFollowUpState(
      state => {
        setFollowUpState(state ?? { items: [], isGenerating: false });
      }
    );

    const unsubSchedules = window.jsb.MessagesBridge.onSchedules(schedules => {
      replaceSchedules(schedules ?? []);
    });

    const unsubFocusMessage = window.jsb.MessagesBridge.onFocusMessage(
      messageId => {
        setFocusMessageId(messageId);
        focusMessageRequestIdRef.current += 1;
        setFocusMessageRequest({
          messageId,
          requestId: focusMessageRequestIdRef.current,
        });
      }
    );

    const unsubFocusQuote = window.jsb.MessagesBridge.onFocusQuote(event => {
      setFocusQuoteRequest(event ?? null);
    });

    return () => {
      unsubHistoryInit();
      unsubHistoryMessageAdded();
      unsubIsStreaming();
      unsubHasOpenTask();
      unsubAssistantState();
      unsubWorkspaceState();
      unsubPaddingTop();
      unsubFollowUpState();
      unsubSchedules();
      unsubFocusMessage();
      unsubFocusQuote();
    };
  }, []);

  return {
    isStreaming,
    hasOpenTask,
    messages,
    assistantStateSequence,
    workspaceState,
    paddingTop,
    followUpState,
    historyInitVersion,
    restoreScrollTop,
    queuedMessage,
    focusMessageId,
    focusMessageRequest,
    focusQuoteRequest,
    sendOrQueueMessage,
    cancelQueuedMessage,
    clearFocusMessageId: () => setFocusMessageId(null),
    clearRestoreScrollTop: () => setRestoreScrollTop(null),
  };
};
