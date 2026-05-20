import { describe, expect, it } from 'vitest';
import {
  buildFileAccessRequestMessage,
  describeFileReferenceEnvironment,
  isWebInaccessibleFileReference,
  shouldRenderFileReferenceFallback,
} from '../../src/embedded/chat/components/messages/file-attachment';

describe('file attachment reference states', () => {
  it('marks path-only non-vfs refs as inaccessible without the native bridge', () => {
    expect(
      isWebInaccessibleFileReference({
        path: '/tmp/debug.txt',
        environmentId: 'local-vm-123',
        nativeBridgeAvailable: false,
      })
    ).toBe(true);
  });

  it('keeps refs accessible when a browser url or native bridge is available', () => {
    expect(
      isWebInaccessibleFileReference({
        path: '/tmp/debug.txt',
        url: 'https://files.example.com/debug.txt',
        environmentId: 'local-vm-123',
        nativeBridgeAvailable: false,
      })
    ).toBe(false);

    expect(
      isWebInaccessibleFileReference({
        path: '/tmp/debug.txt',
        environmentId: 'local-vm-123',
        nativeBridgeAvailable: true,
      })
    ).toBe(false);
  });

  it('describes known file reference environments for the card details', () => {
    expect(describeFileReferenceEnvironment('local-vm-123')).toBe(
      'safe workspace on this Mac'
    );
    expect(describeFileReferenceEnvironment('local_macos')).toBe('this Mac');
    expect(describeFileReferenceEnvironment('remote-web-01')).toBe(
      'remote-web-01'
    );
    expect(describeFileReferenceEnvironment('vfs')).toBe(null);
  });

  it('builds an agent request that includes the missing file reference', () => {
    const message = buildFileAccessRequestMessage({
      filename: 'debug.txt',
      path: '/tmp/debug.txt',
      environmentId: 'local-vm-123',
      environmentLabel: 'safe workspace on this Mac',
    });

    expect(message).toContain('Please provide a complete, accessible version');
    expect(message).toContain('File: debug.txt');
    expect(message).toContain('Location: /tmp/debug.txt');
    expect(message).toContain(
      'Environment: safe workspace on this Mac (local-vm-123)'
    );
    expect(message).toContain('incomplete file reference');
  });

  it('uses the shared fallback predicate for non-vfs path-only content', () => {
    expect(
      shouldRenderFileReferenceFallback({
        fileRef: {
          path: '/tmp/cat.png',
          environmentId: 'local-vm-123',
        },
      })
    ).toBe(true);

    expect(
      shouldRenderFileReferenceFallback({
        url: 'https://files.example.com/cat.png',
        fileRef: {
          path: '/tmp/cat.png',
          environmentId: 'local-vm-123',
        },
      })
    ).toBe(false);

    expect(
      shouldRenderFileReferenceFallback({
        fileRef: {
          path: '/.agent/deliveries/cat.png',
          environmentId: 'vfs',
        },
      })
    ).toBe(false);
  });
});
