import { describe, expect, it } from 'vitest';
import {
  getUserDisplayTextContent,
  isCompactedContextMessage,
  isUserMessage,
  stripLeadingAppRequestTag,
  type SessionHistoryMessage,
} from '../../src/embedded/chat/types/history';
import { collectUserMessageContent } from '../../src/embedded/chat/components/messages/copy';

function makeMessage(
  message: Partial<SessionHistoryMessage>
): SessionHistoryMessage {
  return {
    id: message.id ?? 'message-id',
    type: message.type ?? 'message',
    timestamp: message.timestamp ?? 1,
    ...message,
  };
}

describe('embedded chat history filtering', () => {
  it('keeps merged preserved user text while stripping the compacted-context wrapper', () => {
    const message = makeMessage({
      id: 'merged-user-turn',
      role: 'user',
      content: [
        {
          type: 'text',
          text: `<system-reminder>\nactive ops: op-1 tool=web_search\n</system-reminder>\n<compacted-context>\nOlder request and response.\n</compacted-context>\nPlease continue from /hello.go.`,
        },
      ],
    });

    expect(isUserMessage(message)).toBe(true);
    expect(getUserDisplayTextContent(message)).toEqual([
      'Please continue from /hello.go.',
    ]);
  });

  it('strips a prepended compacted-context text block but keeps later user content blocks', () => {
    const message = makeMessage({
      id: 'merged-structured-user-turn',
      role: 'user',
      content: [
        {
          type: 'text',
          text: '<compacted-context>\nOlder request and response.\n</compacted-context>',
        },
        {
          type: 'text',
          text: 'Real user prompt',
        },
      ],
    });

    expect(isUserMessage(message)).toBe(true);
    expect(getUserDisplayTextContent(message)).toEqual(['Real user prompt']);
  });

  it('marks a message starting with compacted-context (after system-reminder) as hidden', () => {
    const message = makeMessage({
      id: 'compacted-msg',
      role: 'user',
      content: [
        {
          type: 'text',
          text: `<system-reminder>\nactive ops: op-1 tool=web_search\n</system-reminder>\n<compacted-context>\nOlder request and response.\n</compacted-context>\nPlease continue from /hello.go.`,
        },
      ],
    });

    expect(isCompactedContextMessage(message)).toBe(true);
  });

  it('marks a message starting directly with compacted-context as hidden', () => {
    const message = makeMessage({
      id: 'compacted-msg-direct',
      role: 'user',
      content: [
        {
          type: 'text',
          text: '<compacted-context>\nOlder request and response.\n</compacted-context>',
        },
        {
          type: 'text',
          text: 'Real user prompt',
        },
      ],
    });

    expect(isCompactedContextMessage(message)).toBe(true);
  });

  it('does not mark a regular user message as compacted context', () => {
    const message = makeMessage({
      id: 'normal-msg',
      role: 'user',
      content: [
        {
          type: 'text',
          text: 'Hello, how are you?',
        },
      ],
    });

    expect(isCompactedContextMessage(message)).toBe(false);
  });

  it('does not mark an assistant message with compacted-context as hidden', () => {
    const message = makeMessage({
      id: 'assistant-msg',
      role: 'assistant',
      content: [
        {
          type: 'text',
          text: '<compacted-context>\nsome text\n</compacted-context>',
        },
      ],
    });

    expect(isCompactedContextMessage(message)).toBe(false);
  });

  it('omits compacted context from copied user text but preserves the visible user content', () => {
    const message = makeMessage({
      id: 'merged-user-turn',
      role: 'user',
      content: [
        {
          type: 'text',
          text: '<compacted-context>\nOlder request and response.\n</compacted-context>',
        },
        {
          type: 'text',
          text: 'Please continue from /hello.go.',
        },
        {
          type: 'file',
          fileName: 'debug.txt',
          mimeType: 'text/plain',
          fileRef: {
            path: '/tmp/debug.txt',
          },
        },
      ],
    });

    expect(collectUserMessageContent(message).texts).toEqual([
      'Please continue from /hello.go.',
    ]);
  });

  it('keeps user file cards when only a file ref path is present', () => {
    const message = makeMessage({
      id: 'path-only-file',
      role: 'user',
      content: [
        {
          type: 'file',
          fileName: 'debug.txt',
          mimeType: 'text/plain',
          fileRef: {
            path: '/tmp/debug.txt',
            environmentId: 'local-vm-123',
          },
        },
      ],
    });

    expect(collectUserMessageContent(message).files).toEqual([
      {
        filename: 'debug.txt',
        contentType: 'text/plain',
        path: '/tmp/debug.txt',
        url: undefined,
        environmentId: 'local-vm-123',
        size: '',
      },
    ]);
  });

  it('strips all user reminder blocks from displayed user text', () => {
    const message = makeMessage({
      id: 'macos-user-turn',
      role: 'user',
      content: [
        {
          type: 'text',
          text: `<user-reminder>This message is sent from the user's computer.</user-reminder>
<user-reminder>Write paths to local-vm-machine.</user-reminder>

Please continue from /hello.go.`,
        },
      ],
    });

    expect(getUserDisplayTextContent(message)).toEqual([
      'Please continue from /hello.go.',
    ]);
  });

  it('strips leading app-request tag from assistant messages', () => {
    const message = makeMessage({
      id: 'assistant-location',
      role: 'assistant',
      content: [
        {
          type: 'text',
          text: '<app-request type="location" />\nI\'ll check the weather for you!',
        },
      ],
    });

    expect(getUserDisplayTextContent(message)).toEqual([
      "I'll check the weather for you!",
    ]);
  });

  it('does not strip app-request tag from the middle of assistant text', () => {
    const message = makeMessage({
      id: 'assistant-mid-tag',
      role: 'assistant',
      content: [
        {
          type: 'text',
          text: 'Here is some text <app-request type="location" /> and more text',
        },
      ],
    });

    expect(getUserDisplayTextContent(message)).toEqual([
      'Here is some text <app-request type="location" /> and more text',
    ]);
  });

  it('stripLeadingAppRequestTag handles various formats', () => {
    expect(
      stripLeadingAppRequestTag('<app-request type="location" />\nHello')
    ).toBe('Hello');
    expect(
      stripLeadingAppRequestTag('  <app-request type="location"/>\nHello')
    ).toBe('Hello');
    expect(stripLeadingAppRequestTag('No tag here')).toBe('No tag here');
    expect(stripLeadingAppRequestTag('')).toBe('');
  });
});
