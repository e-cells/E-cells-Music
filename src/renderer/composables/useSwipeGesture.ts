import type { Ref } from 'vue';

export interface SwipeGestureOptions {
  onSwipeLeft?: () => void;
  onSwipeRight?: () => void;
  onSwipeDown?: () => void;
  onSwipeUp?: () => void;
  threshold?: number;
  excludeSelector?: string;
}

export function useSwipeGesture(el: Ref<HTMLElement | null>, options: SwipeGestureOptions) {
  const threshold = options.threshold ?? 80;
  let startX = 0;
  let startY = 0;
  let tracking = false;

  const onTouchStart = (e: TouchEvent) => {
    if (e.touches.length !== 1) return;
    if (options.excludeSelector) {
      const target = e.target as HTMLElement;
      if (target.closest(options.excludeSelector)) return;
    }
    const t = e.touches[0];
    startX = t.clientX;
    startY = t.clientY;
    tracking = true;
  };

  const onTouchEnd = (e: TouchEvent) => {
    if (!tracking) return;
    tracking = false;
    const t = e.changedTouches[0];
    const dx = t.clientX - startX;
    const dy = t.clientY - startY;
    const absDx = Math.abs(dx);
    const absDy = Math.abs(dy);

    if (Math.max(absDx, absDy) < threshold) return;

    if (absDx > absDy) {
      if (dx < 0) options.onSwipeLeft?.();
      else options.onSwipeRight?.();
    } else {
      if (dy > 0) options.onSwipeDown?.();
      else options.onSwipeUp?.();
    }
  };

  const bind = () => {
    const target = el.value;
    if (!target) return;
    target.addEventListener('touchstart', onTouchStart, { passive: true });
    target.addEventListener('touchend', onTouchEnd, { passive: true });
  };

  const unbind = () => {
    const target = el.value;
    if (!target) return;
    target.removeEventListener('touchstart', onTouchStart);
    target.removeEventListener('touchend', onTouchEnd);
  };

  return { bind, unbind };
}
