import { EventSink } from '@ohos/flutter_ohos';

/**
 * 表冠旋转事件转发给 Flutter 的小调度器（镜像 BackDispatcher 模式）。
 *
 * EntryAbility 在 configureFlutterEngine 里注册 xianyu/rotary EventChannel，
 * Dart 侧（third_party/wearable_rotary 的 ohos 实现）监听 rotaryEvents；
 * Index.ets 根组件 onDigitalCrown（ArkUI 通用事件，API 18+）拿到 CrownEvent
 * 后把 UPDATE 的角度增量转进来。Dart 未监听时 sink 为空、事件静默丢弃。
 */
let sink: EventSink | null = null;

export function attachRotarySink(s: EventSink | null): void {
  sink = s;
}

export function dispatchCrownToFlutter(degree: number): void {
  if (sink === null || degree === 0) {
    return;
  }
  sink.success(degree);
}
