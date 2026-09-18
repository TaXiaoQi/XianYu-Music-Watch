// OpenHarmony implementation of `wearable_rotary` (upstream 2.0.4 API surface).
//
// ohos has no upstream plugin, so this package IS the implementation: it
// listens on the project-owned `xianyu/rotary` EventChannel, registered by
// EntryAbility.ets; Index.ets forwards ArkUI onDigitalCrown events (API 18+,
// CrownAction.UPDATE) through RotaryDispatcher into the channel sink.
//
// Wire format: one signed double per event = CrownEvent.degree（正=顺时针，
// 0 已在原生侧过滤；按逐事件增量处理）。幅度校准：华为表冠 1 detent≈24°
// → ×2 折算 48px ≈ 三星官方一格的 magnitude，与各端共用的
// RotaryQuantizer(pxPerStep: 48) 直接对齐。若真机方向相反，只需在下面
// _onEvent 里反转符号；若慢转飞屏则原生侧发的是累计角，需在 Index.ets
// 做差分后再转发。
//
// API is byte-compatible with upstream lib/src/wearable_rotary_base.dart:
// all 5 rotaryEvents.listen() call sites consume this unchanged.

import 'dart:async';

import 'package:flutter/services.dart';

/// A rotary event.
class RotaryEvent {
  /// Constructor
  const RotaryEvent({required this.direction, this.magnitude});

  /// The direction of the rotary event.
  final RotaryDirection direction;

  /// The magnitude of the rotation (null on backends that only report
  /// direction).
  final double? magnitude;
}

/// The direction of the rotary event.
enum RotaryDirection {
  /// A rotation event in the clockwise direction.
  clockwise,

  /// A rotation event in the counter clockwise direction.
  counterClockwise,
}

const EventChannel _eventChannel = EventChannel('xianyu/rotary');

Stream<RotaryEvent>? _rotaryEvents;

/// A broadcast stream of events from the device rotary sensor.
///
/// 5 个页面各自 listen：必须 broadcast；底层 EventChannel 是单订阅流，在
/// onListen/onCancel 里桥接（首个监听建立订阅、最后一个取消时断开），
/// 与上游 Samsung 实现的语义一致。
Stream<RotaryEvent> get rotaryEvents => _rotaryEvents ??= _initRotaryEvents();

Stream<RotaryEvent> _initRotaryEvents() {
  late StreamSubscription<dynamic> subscription;
  late StreamController<RotaryEvent> controller;
  controller = StreamController<RotaryEvent>.broadcast(
    onListen: () {
      subscription = _eventChannel.receiveBroadcastStream().listen(
            _onEvent(controller),
            onError: controller.addError,
          );
    },
    onCancel: () => subscription.cancel(),
  );
  return controller.stream;
}

void Function(dynamic data) _onEvent(StreamController<RotaryEvent> controller) {
  return (dynamic data) {
    final degree = (data as num?)?.toDouble() ?? 0.0;
    if (degree == 0) return;
    controller.add(RotaryEvent(
      direction: degree > 0
          ? RotaryDirection.clockwise
          : RotaryDirection.counterClockwise,
      magnitude: degree.abs() * 2.0, // 24°/detent → 48px ≈ 一格
    ));
  };
}
