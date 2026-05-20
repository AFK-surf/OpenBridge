// @vitest-environment jsdom
/* oxlint-disable no-await-in-loop */

import React from 'react';
import { flushSync } from 'react-dom';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { FileAttachmentCard } from '../../src/embedded/chat/components/messages/file-attachment';

async function waitForCondition(condition: () => boolean, timeoutMs = 1000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) {
      return;
    }
    await new Promise(resolve => setTimeout(resolve, 0));
    flushSync(() => {});
  }
  throw new Error('Timed out waiting for condition');
}

const mountedRoots: Root[] = [];

describe('FileAttachmentCard', () => {
  afterEach(async () => {
    for (const root of mountedRoots.splice(0)) {
      flushSync(() => {
        root.unmount();
      });
      await waitForCondition(() => true);
    }
    document.body.innerHTML = '';
    vi.clearAllMocks();
  });

  it('renders an incomplete-content state and asks the agent for access', async () => {
    const container = document.createElement('div');
    document.body.appendChild(container);
    const root = createRoot(container);
    mountedRoots.push(root);
    const requestedMessages: string[] = [];

    flushSync(() => {
      root.render(
        <FileAttachmentCard
          filename="debug.txt"
          contentType="text/plain"
          path="/tmp/debug.txt"
          environmentId="local-vm-123"
          size=""
          onRequestFileAccess={message => {
            requestedMessages.push(message);
          }}
        />
      );
    });

    expect(container.textContent).toContain(
      'Content incomplete — file unavailable.'
    );
    expect(container.textContent).toContain('Location: /tmp/debug.txt');
    expect(container.textContent).toContain(
      'Environment: safe workspace on this Mac'
    );

    const button = container.querySelector('button');
    expect(button?.textContent).toBe('Ask agent to make accessible');

    flushSync(() => {
      button?.dispatchEvent(
        new MouseEvent('click', { bubbles: true, cancelable: true })
      );
    });

    await waitForCondition(() => requestedMessages.length === 1);
    expect(requestedMessages[0]).toContain('File: debug.txt');
    expect(requestedMessages[0]).toContain('Location: /tmp/debug.txt');
    await waitForCondition(() =>
      Boolean(container.textContent?.includes('Request sent'))
    );
    expect(container.textContent).toContain('Request sent');
    expect(button?.disabled).toBe(true);

    flushSync(() => {
      button?.dispatchEvent(
        new MouseEvent('click', { bubbles: true, cancelable: true })
      );
    });
    expect(requestedMessages).toHaveLength(1);
  });
});
