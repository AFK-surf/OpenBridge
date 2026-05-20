// @vitest-environment jsdom

import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import type { SessionHistoryMessage } from '../../src/embedded/chat/types/history';

vi.mock('../../src/embedded/chat/components/error-boundary', () => ({
  ErrorBoundary: ({
    children,
  }: React.PropsWithChildren<Record<string, never>>) => <>{children}</>,
}));

vi.mock('../../src/embedded/chat/components/markdown/streamdown', () => ({
  CueStreamdown: ({
    children,
  }: React.PropsWithChildren<Record<string, never>>) => <>{children}</>,
}));

vi.mock('../../src/embedded/chat/components/markdown/overrides/audio', () => ({
  CueStreamdownAudio: () => <div data-testid="assistant-audio" />,
}));

vi.mock('../../src/embedded/chat/components/markdown/overrides/video', () => ({
  CueStreamdownVideo: () => <div data-testid="assistant-video" />,
}));

vi.mock('../../src/embedded/chat/components/messages/attachment-image', () => ({
  AttachmentImage: ({ sourcePath }: { sourcePath?: string }) => (
    <div data-testid="attachment-image" data-source-path={sourcePath} />
  ),
}));

vi.mock(
  '../../src/embedded/chat/components/messages/assistant-message-operations',
  () => ({
    AssistantMessageOperations: () => null,
  })
);

vi.mock(
  '../../src/embedded/chat/components/messages/assistant-state-section',
  () => ({
    AssistantStateSection: () => null,
  })
);

vi.mock('../../src/embedded/chat/components/messages/file-attachment', () => ({
  FileAttachmentCard: ({
    filename,
    path,
    ...props
  }: {
    filename?: string;
    path?: string;
    [key: string]: unknown;
  }) => (
    <div
      data-testid="file-attachment-card"
      data-artifact={props['data-artifact'] as string | undefined}
      data-filename={filename}
      data-source-path={path}
    />
  ),
  shouldRenderFileReferenceFallback: (content: {
    url?: string | null;
    fileRef?: { path?: string | null; environmentId?: string | null } | null;
  }) =>
    Boolean(
      !content.url &&
      content.fileRef?.path &&
      !['', 'vfs'].includes(
        content.fileRef.environmentId?.trim().toLowerCase() ?? ''
      )
    ),
}));

vi.mock(
  '../../src/embedded/chat/components/messages/permission-message',
  () => ({
    PermissionMessage: () => null,
  })
);

vi.mock('../../src/embedded/chat/components/messages/question-message', () => ({
  QuestionMessage: () => null,
}));

vi.mock(
  '../../src/embedded/chat/components/messages/save-file-message',
  () => ({
    SaveFileMessage: () => null,
  })
);

vi.mock('../../src/embedded/chat/components/messages/schedule-message', () => ({
  ScheduleMessage: () => null,
}));

vi.mock(
  '../../src/embedded/chat/components/messages/sandbox-review-message',
  () => ({
    SandboxReviewMessage: () => null,
  })
);

vi.mock(
  '../../src/embedded/chat/components/messages/secret-input-message',
  () => ({
    SecretInputMessage: () => null,
  })
);

vi.mock('../../src/embedded/chat/components/error-card', () => ({
  ErrorCard: () => null,
}));

vi.mock(
  '../../src/embedded/chat/components/messages/web-browse-widget',
  () => ({
    WebBrowseWidget: () => null,
    tryParseWebBrowsePayload: () => null,
  })
);

vi.mock('../../src/utils/tool-call-status', () => ({
  tryParseToolCallStatusPayload: () => null,
}));

vi.mock('../../src/utils/bridge-runtime', () => ({
  hasNativeJSBridge: () => true,
}));

import { AssistantMessage } from '../../src/embedded/chat/components/messages/assistant-message';

function makeMessage(
  message: Partial<SessionHistoryMessage>
): SessionHistoryMessage {
  return {
    id: message.id ?? 'assistant-1',
    type: message.type ?? 'message',
    role: message.role ?? 'assistant',
    timestamp: message.timestamp ?? 1,
    ...message,
  };
}

describe('AssistantMessage attachments', () => {
  it('renders assistant image blocks when a VFS file ref is present', async () => {
    const message = makeMessage({
      content: [
        {
          type: 'image',
          fileRef: {
            path: '/.agent/deliveries/session/call/cat.png',
          },
          fileName: 'cat.png',
          mimeType: 'image/png',
        },
      ],
    });

    const markup = renderToStaticMarkup(
      <AssistantMessage
        items={[{ type: 'message', message }]}
        allMessages={[message]}
        hideOperations
      />
    );

    expect(markup).toContain('data-testid="attachment-image"');
    expect(markup).toContain(
      `data-source-path="${escapeAttribute(
        '/.agent/deliveries/session/call/cat.png'
      )}"`
    );
  });

  it('renders inaccessible assistant image refs as file cards', async () => {
    const message = makeMessage({
      content: [
        {
          type: 'image',
          fileRef: {
            path: '/tmp/cat.png',
            environmentId: 'local-vm-123',
          },
          fileName: 'cat.png',
          mimeType: 'image/png',
        },
      ],
    });

    const markup = renderToStaticMarkup(
      <AssistantMessage
        items={[{ type: 'message', message }]}
        allMessages={[message]}
        hideOperations
      />
    );

    expect(markup).toContain('data-testid="file-attachment-card"');
    expect(markup).toContain(`data-filename="cat.png"`);
    expect(markup).toContain(`data-source-path="/tmp/cat.png"`);
  });
});

function escapeAttribute(value: string) {
  return value.replace(/"/g, '&quot;');
}
