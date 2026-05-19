import { cn } from '@/utils/cn';
import { observeResize } from '@/utils/observe-resize';
import { AnimatePresence, motion, type HTMLMotionProps } from 'motion/react';
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { createPortal } from 'react-dom';
import { MaskedScrollArea } from '../../masked-scrollarea';
import { useMacosVersion } from '@/utils/use-utils-bridge';
import { commitGlobalCSSVar } from '@/embedded/chat/global-css-var';
import {
  resolveActivityCenterAnchorHeight,
  resolveActivityCenterExitY,
  shouldPadActivityCenterSafeArea,
} from './layout';

export const ActivityCenterBanner = ({
  header,
  children,
  visible,
  className,
  style,
  ...props
}: HTMLMotionProps<'div'> & {
  header: (expanded: boolean) => ReactNode;
  visible: boolean;
  children?: ReactNode;
}) => {
  const ref = useRef<HTMLDivElement>(null);
  const macosVersion = useMacosVersion();
  const [open, setOpen] = useState(true);
  const [anchorHeight, setAnchorHeight] = useState(0);
  const [measuredVisibleHeight, setMeasuredVisibleHeight] = useState(0);

  // banner enter with a spring animation,
  // add extra space to avoid bottom side bounce into viewport
  const safeArea = 60;
  const headerHeight = 36;

  const usesSafeAreaPadding = shouldPadActivityCenterSafeArea({
    anchorHeight,
    measuredVisibleHeight,
  });

  const detectHeight = useCallback(() => {
    const el = ref.current;
    if (!el || !visible) {
      setMeasuredVisibleHeight(0);
      setAnchorHeight(0);
      return;
    }

    const paddingBottom =
      parseFloat(window.getComputedStyle(el).paddingBottom) || 0;
    const height = el.getBoundingClientRect().height;
    const nextMeasuredVisibleHeight = Math.max(0, height - paddingBottom);

    setMeasuredVisibleHeight(nextMeasuredVisibleHeight);
    setAnchorHeight(previousAnchorHeight =>
      resolveActivityCenterAnchorHeight({
        previousAnchorHeight,
        measuredVisibleHeight: nextMeasuredVisibleHeight,
        isOpen: open,
      })
    );
  }, [open, visible]);

  // const debouncedDetectHeight = useMemo(
  //   () => debounce(detectHeight, 100),
  //   [detectHeight]
  // );

  useLayoutEffect(() => {
    detectHeight();
  }, [detectHeight]);

  useEffect(() => {
    commitGlobalCSSVar(
      'activityCenterHeight',
      `${(visible ? anchorHeight : 0).toFixed(0)}px`
    );
  }, [anchorHeight, visible]);

  useEffect(() => {
    return () => {
      commitGlobalCSSVar('activityCenterHeight', '0px');
    };
  }, []);

  useEffect(() => {
    if (!visible) {
      detectHeight();
      return;
    }
    const el = ref.current;
    if (!el) return;

    const dispose = observeResize(el, detectHeight);
    return dispose;
  }, [visible, detectHeight]);

  return createPortal(
    <AnimatePresence>
      {visible && (
        <motion.div
          initial={{ y: 'calc(100% + 20px)' }}
          exit={{
            y: resolveActivityCenterExitY({ anchorHeight, safeArea }),
          }}
          animate={{ y: 0 }}
          transition={{ type: 'spring', stiffness: 100, damping: 15 }}
          className={cn(
            className,
            'absolute z-10 left-1/2 -translate-x-1/2',
            'rounded-t-2xl w-[calc(100vw-48px)] max-w-[calc(800px-48px)]',
            'border dark:border-[0.5px] border-b-0 border-[#7773] dark:border-[#aaaaaa40]',
            !macosVersion || macosVersion >= 26
              ? cn(
                  'dark:bg-[#44444490] dark:backdrop-blur-lg dark:backdrop-saturate-180 dark:backdrop-brightness-120',
                  'bg-[#dddddd80] backdrop-blur-lg backdrop-saturate-180 backdrop-brightness-120'
                )
              : 'bg-surface-card',
            ''
          )}
          style={{
            paddingBottom: usesSafeAreaPadding ? safeArea : 0,
            ...(anchorHeight > 0
              ? { top: `calc(100dvh - ${anchorHeight.toFixed(0)}px)` }
              : { bottom: -safeArea }),
            ...style,
          }}
          {...props}
          ref={ref}
        >
          <header
            style={{ height: headerHeight }}
            onClick={() => setOpen(!open)}
          >
            {header(open)}
          </header>
          <AnimatePresence>
            {children && open && (
              <motion.div
                initial={{ opacity: 0, height: 0 }}
                animate={{ opacity: 1, height: 'auto' }}
                exit={{ opacity: 0, height: 0 }}
                transition={{
                  duration: 0.15,
                  ease: 'easeInOut',
                }}
              >
                <MaskedScrollArea
                  maskSizeStart={0}
                  className="w-full"
                  scrollViewClassName="max-h-[280px]"
                >
                  {children}
                </MaskedScrollArea>
              </motion.div>
            )}
          </AnimatePresence>

          {/* Shadow below the banner */}
          <div
            className={cn(
              'absolute top-0 left-0 w-full -z-1 rounded-t-2xl',
              'shadow-[0_-24px_24px_rgba(0,0,0,0.1)]'
            )}
            style={{
              height: `calc(100% - ${usesSafeAreaPadding ? safeArea : 0}px)`,
            }}
          />
        </motion.div>
      )}
    </AnimatePresence>,
    document.body
  );
};
