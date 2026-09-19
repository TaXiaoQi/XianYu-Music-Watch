import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS';

let lastBackEmit = 0;

export function dispatchBackToFlutter(ctx: common.UIAbilityContext): void {
  const now = Date.now();
  if (now - lastBackEmit < 300) {
    return;
  }
  lastBackEmit = now;
  hilog.info(0x0100, 'xianyu', 'BACK -> FLUTTER (popRoute)');
  ctx.eventHub.emit(EVENT_BACK_PRESS);
}
