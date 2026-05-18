import { describe, expect, it } from 'vitest';
import { deriveIsStreamingFromBridgeState } from '../../src/embedded/chat/hooks/use-swift-bridge';
import type { AssistantState } from '../../src/embedded/chat/types/history';

function makeState(state: Partial<AssistantState>): AssistantState {
  return {
    phase: state.phase ?? 'execution',
    sequence: state.sequence ?? 1,
    phaseStartedAt: state.phaseStartedAt ?? 1,
    updatedAt: state.updatedAt ?? 1,
    tools: state.tools ?? [],
    asyncToolcalls: state.asyncToolcalls ?? [],
    reasoning: state.reasoning,
    messaging: state.messaging,
  };
}

describe('use-swift-bridge', () => {
  it('treats non-idle assistant phases as active even when bridge streaming is false', () => {
    expect(
      deriveIsStreamingFromBridgeState(false, [
        makeState({
          phase: 'thinking',
        }),
      ])
    ).toBe(true);

    expect(
      deriveIsStreamingFromBridgeState(false, [
        makeState({
          phase: 'messaging',
          messaging: {
            messageId: 'msg-1',
            responseId: null,
            text: '',
            isStreaming: false,
          },
        }),
      ])
    ).toBe(true);
  });

  it('returns false when the latest assistant state is idle and the bridge is false', () => {
    expect(
      deriveIsStreamingFromBridgeState(false, [
        makeState({
          sequence: 1,
          phase: 'thinking',
        }),
        makeState({
          sequence: 2,
          phase: 'idle',
        }),
      ])
    ).toBe(false);
  });

  it('returns false for terminal local assistant phases', () => {
    for (const phase of ['completed', 'failed', 'cancelled']) {
      expect(
        deriveIsStreamingFromBridgeState(false, [
          makeState({
            phase,
          }),
        ])
      ).toBe(false);
    }
  });

  it('preserves an explicit bridge streaming signal', () => {
    expect(deriveIsStreamingFromBridgeState(true, [])).toBe(true);
  });
});
