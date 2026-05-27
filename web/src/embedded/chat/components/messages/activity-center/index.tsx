import { useState, useCallback, useMemo, useEffect } from 'react';
import { cn } from '@/utils/cn';
import type {
  SessionHistoryMessage,
  WorkspaceState,
} from '@/embedded/chat/types/history';
import { deriveCurrentTask } from '@/embedded/chat/types/history';
import type { DerivedTask } from './types';
import type { SessionHistoryMessageTodoItem } from './types';
import { ActivityCenterBanner } from './banner';
import { Spinner } from '../../loading/spinner';
import { CircleSFSymbolRegular } from '@/assets/sf-symbols/regular/circle';
import { CheckmarkCircleFillSFSymbolRegular } from '@/assets/sf-symbols/regular/checkmark.circle.fill';
import { DiffFileTree } from '../diff-file-tree';
import { Button } from '../../button';
import { DebugMessage } from '@/utils/debug-message';
import { ChevronRightSFSymbolMedium } from '@/assets/sf-symbols/medium/chevron.right';

export const ActivityCenter = ({
  messages,
  workspaceState,
  isStreaming,
  hasOpenTask,
}: {
  messages: SessionHistoryMessage[];
  workspaceState: WorkspaceState | null;
  isStreaming: boolean;
  hasOpenTask: boolean;
}) => {
  const [isAccepting, setIsAccepting] = useState(false);
  const [isDiscarding, setIsDiscarding] = useState(false);

  const visibleTask = useMemo(() => deriveCurrentTask(messages), [messages]);

  const fileDiffs = useMemo(
    () => workspaceState?.fileDiff ?? [],
    [workspaceState?.fileDiff]
  );
  const hasFiles = fileDiffs.length > 0;

  // Use runtime task openness instead of inferring completion from history alone.
  // A task can remain open while streaming is paused for wait, and some runs may
  // stop without emitting a matching task end/cancel history event.
  const showTask = visibleTask?.status === 'running' && hasOpenTask;
  const showFiles = hasFiles;
  const visible = showTask || showFiles;

  const allFilePaths = useMemo(() => {
    return fileDiffs.map(d => d.path);
  }, [fileDiffs]);

  const [selectedPaths, setSelectedPaths] = useState<Set<string>>(
    () => new Set(allFilePaths)
  );

  useEffect(() => {
    const currentSet = new Set(allFilePaths);
    setSelectedPaths(prev => {
      const next = new Set<string>();
      for (const p of currentSet) {
        next.add(prev.has(p) ? p : p);
      }
      if (next.size === prev.size && [...next].every(p => prev.has(p))) {
        return prev;
      }
      return next;
    });
  }, [allFilePaths]);

  const environmentId = workspaceState?.environmentId ?? '';

  const handleAccept = useCallback(async () => {
    const paths = Array.from(selectedPaths);
    if (paths.length === 0) return;
    setIsAccepting(true);
    try {
      await window.jsb?.MessagesBridge?.acceptFiles(paths, environmentId);
    } finally {
      setIsAccepting(false);
    }
  }, [selectedPaths, environmentId]);

  const handleDiscardAll = useCallback(async () => {
    setIsDiscarding(true);
    try {
      await window.jsb?.MessagesBridge?.discardAllChanges(environmentId);
    } finally {
      setIsDiscarding(false);
    }
  }, [environmentId]);

  const canAccept = showFiles && !isAccepting && !isDiscarding;
  const headerTitle = showFiles
    ? 'Workspace file changes'
    : (visibleTask?.title ?? 'Files');
  const headerIcon =
    !showFiles && visibleTask ? (
      <TaskStatusIcon task={visibleTask} isStreaming={isStreaming} />
    ) : null;

  const fileActions = showFiles ? (
    <div className="flex items-center gap-[6px] shrink-0">
      <Button
        variant="primary"
        onClick={e => {
          e.stopPropagation();
          handleAccept();
        }}
        disabled={!canAccept || selectedPaths.size === 0}
      >
        {isAccepting ? (
          <Spinner className="text-primary-highlight w-3 h-3" />
        ) : (
          `Accept${selectedPaths.size < allFilePaths.length ? ` (${selectedPaths.size})` : ''}`
        )}
      </Button>
      <Button
        onClick={e => {
          e.stopPropagation();
          handleDiscardAll();
        }}
        disabled={!canAccept}
      >
        {isDiscarding ? <Spinner className="w-3 h-3" /> : 'Reject'}
      </Button>
    </div>
  ) : null;

  const header = (expanded: boolean) => (
    <div className="flex items-center justify-between h-full px-[8px]">
      <div className="flex items-center min-w-0 flex-1">
        {headerIcon && (
          <div className="flex h-5 w-5 items-center justify-center mr-1">
            {headerIcon}
          </div>
        )}
        <div className="flex items-center min-w-0 flex-1 gap-[6px]">
          <span className="text-[13px] leading-[19px] text-text-primary font-medium truncate min-w-0">
            {headerTitle}
          </span>
          {fileActions}
        </div>
      </div>

      <div className="flex items-center text-text-secondary gap-[6px] shrink-0">
        {showTask && visibleTask && (
          <div
            onClick={async () => {
              await window.jsb.MessagesBridge.cancelTask(visibleTask.id);
            }}
            className={cn(
              'opacity-0 group-hover/activity-center:opacity-100',
              'rounded-full size-6 flex-center shrink-0',
              'border border-border',
              'bg-control-bg',
              'hover:bg-control-bg-hover',
              'transition-all'
            )}
          >
            <div className="size-[10px] rounded-[2px] bg-text-primary" />
          </div>
        )}
        <div
          role="button"
          className="w-5 h-5 flex items-center justify-center rounded-md transition-colors"
        >
          <ChevronRightSFSymbolMedium
            className={cn(
              'text-[11px] transition-transform duration-200',
              expanded ? 'rotate-90' : ''
            )}
          />
        </div>
      </div>
    </div>
  );

  const content = (
    <div className="flex flex-col">
      {showFiles ? (
        <DebugMessage
          data={workspaceState?.fileDiff}
          className="px-[8px] pb-[2.5px]"
        >
          <DiffFileTree
            diffs={fileDiffs}
            isStreaming={isStreaming}
            selectedPaths={selectedPaths}
            onSelectionChange={setSelectedPaths}
            maxHeight={280}
            environmentId={environmentId}
          />
        </DebugMessage>
      ) : (
        showTask &&
        visibleTask.todos.length > 0 && (
          <div className="py-[8px]">
            <DebugMessage data={visibleTask}>
              <TodoList todos={visibleTask.todos} />
            </DebugMessage>
          </div>
        )
      )}
    </div>
  );

  return (
    <ActivityCenterBanner
      header={open => header(open)}
      visible={visible}
      className="group/activity-center"
    >
      {content}
    </ActivityCenterBanner>
  );
};

const TaskStatusIcon = ({
  isStreaming,
  task,
}: {
  isStreaming: boolean;
  task: DerivedTask;
}) => {
  if (task.status === 'running' && isStreaming)
    return <Spinner className="text-[17px]" />;
  if (task.status === 'completed')
    return (
      <CheckmarkCircleFillSFSymbolRegular className="text-[#25D083] text-[15px]" />
    );
  if (task.status === 'cancelled')
    return (
      <CheckmarkCircleFillSFSymbolRegular className="text-text-tertiary text-[15px]" />
    );
  return <CircleSFSymbolRegular className="text-text-tertiary text-[15px]" />;
};

const TodoList = ({ todos }: { todos: SessionHistoryMessageTodoItem[] }) => {
  return (
    <div className="px-[8px] space-y-1.5">
      {todos.map(todo => (
        <div
          key={todo.content}
          className="grid grid-cols-[20px_minmax(0,1fr)] items-start gap-1"
        >
          <div className="shrink-0 w-5 h-5 flex items-center justify-center">
            <TodoStatusIcon status={todo.status} />
          </div>
          <div
            className={cn(
              'text-[13px] leading-[19px] transition-colors py-[2px]',
              todo.status === 'completed'
                ? 'text-text-tertiary line-through decoration-text-tertiary'
                : 'text-text-secondary'
            )}
          >
            {todo.content}
          </div>
        </div>
      ))}
    </div>
  );
};

const TodoStatusIcon = ({ status }: { status: string }) => {
  switch (status) {
    case 'pending':
      return (
        <CircleSFSymbolRegular className="text-text-tertiary text-[15px]" />
      );
    case 'in_progress':
      return <Spinner className="text-[17px]" />;
    case 'completed':
      return (
        <CheckmarkCircleFillSFSymbolRegular className="text-text-tertiary text-[15px]" />
      );
    default:
      return (
        <CircleSFSymbolRegular className="text-text-tertiary text-[15px]" />
      );
  }
};
