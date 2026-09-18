import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 系统返回统一转发给 Flutter 的小调度器。
 *
 * back 的可消费点只有 @Entry 页 onBackPress（ability 级 onBackPressed 只能
 * 选「退后台 vs 销毁」，拦截不了），但部分固件会把 back 派发到 ability 级
 * 而非页级——这里把两条路径收口到同一个转发 + 去重：同一物理返回只向
 * Flutter（EVENT_BACK_PRESS → FlutterView → popRoute）转发一次，防止
 * 「页级+能力级」双重派发时 popRoute 落两次（第二次会打到根路由误退后台）。
 */
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
