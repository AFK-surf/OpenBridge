// @vitest-environment jsdom

import React from 'react';
import { flushSync } from 'react-dom';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  SessionHistoryMessage,
  WorkspaceState,
} from '../../src/embedded/chat/types/history';
import { ActivityCenter } from '../../src/embedded/chat/components/messages/activity-center';

vi.mock(
  '../../src/embedded/chat/components/messages/activity-center/banner',
  async () => {
    const ReactModule = await import('react');

    return {
      ActivityCenterBanner: ({
        header,
        visible,
        className,
      }: {
        header: (expanded: boolean) => React.ReactNode;
        visible: boolean;
        className?: string;
      }) =>
        visible
          ? ReactModule.createElement(
              'div',
              { className },
              ReactModule.createElement('header', null, header(true))
            )
          : null,
    };
  }
);

vi.mock('../../src/embedded/chat/components/loading/spinner', async () => {
  const ReactModule = await import('react');

  return {
    Spinner: ({ className }: { className?: string }) =>
      ReactModule.createElement('span', {
        className,
        'data-testid': 'spinner',
      }),
  };
});

const mountedRoots: Root[] = [];

class MockResizeObserver implements ResizeObserver {
  readonly observe = vi.fn();
  readonly unobserve = vi.fn();
  readonly disconnect = vi.fn();
}

function makeWorkspaceState(): WorkspaceState {
  return {
    sessionId: 'session-1',
    environmentId: 'environment-1',
    environmentLabel: 'Workspace',
    fileDiff: [
      {
        path: 'src/index.tsx',
        mode: 0o100644,
        isDir: false,
        isUpdated: true,
        isDeleted: false,
        timestamp: new Date(0).toISOString(),
        size: 120,
      },
    ],
  };
}

function makeTaskMessage(): SessionHistoryMessage {
  return {
    id: 'task-start-1',
    type: 'task',
    role: 'assistant',
    timestamp: 1,
    taskId: 'task-1',
    action: 'start',
    taskTitle: 'Workspace file changes',
    todos: [],
  };
}

function renderActivityCenter() {
  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);
  mountedRoots.push(root);

  flushSync(() => {
    root.render(
      <ActivityCenter
        messages={[makeTaskMessage()]}
        workspaceState={makeWorkspaceState()}
        isStreaming={false}
        hasOpenTask
      />
    );
  });

  return container;
}

describe('ActivityCenter', () => {
  beforeEach(() => {
    globalThis.ResizeObserver = MockResizeObserver;
    window.jsb = {
      MessagesBridge: {
        acceptFiles: vi.fn().mockResolvedValue(undefined),
        discardAllChanges: vi.fn().mockResolvedValue(undefined),
        cancelTask: vi.fn().mockResolvedValue(undefined),
        checkFilesExist: vi.fn().mockResolvedValue({}),
        getFileIcon: vi.fn().mockResolvedValue(null),
      },
    } as unknown as Window['jsb'];
  });

  afterEach(() => {
    for (const root of mountedRoots.splice(0)) {
      flushSync(() => {
        root.unmount();
      });
    }
    document.body.innerHTML = '';
    vi.clearAllMocks();
    Reflect.deleteProperty(window, 'jsb');
  });

  it('keeps file review actions immediately beside the workspace file changes title', () => {
    renderActivityCenter();

    const header = document.body.querySelector('header');
    expect(header).toBeTruthy();

    const title = Array.from(header?.querySelectorAll('span') ?? []).find(
      element => element.textContent === 'Workspace file changes'
    );
    const acceptButton = Array.from(
      header?.querySelectorAll('button') ?? []
    ).find(element => element.textContent === 'Accept');
    const rejectButton = Array.from(
      header?.querySelectorAll('button') ?? []
    ).find(element => element.textContent === 'Reject');
    const expandButton = header?.querySelector('[role="button"]');

    expect(title).toBeTruthy();
    expect(acceptButton).toBeTruthy();
    expect(rejectButton).toBeTruthy();
    expect(expandButton).toBeTruthy();

    expect(acceptButton?.parentElement?.parentElement).toBe(
      title?.parentElement
    );
    expect(rejectButton?.parentElement?.parentElement).toBe(
      title?.parentElement
    );
    expect(acceptButton?.compareDocumentPosition(rejectButton as Node)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    expect(rejectButton?.compareDocumentPosition(expandButton as Node)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
  });
});
