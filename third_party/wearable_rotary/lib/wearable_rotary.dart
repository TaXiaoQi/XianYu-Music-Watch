// OpenHarmony stub of `wearable_rotary` (upstream 2.0.4 API surface).
//
// Upstream registers the `flutter.wearable_rotary.channel` EventChannel which
// has no ohos platform handler -> every `rotaryEvents.listen()` throws
// MissingPluginException (unhandled stream error per page). This stub returns
// an empty stream instead; watch crown input on ohos is a follow-up task
// (bridge ArkUI onDigitalCrown via a xianyu/* MethodChannel).
//
// API is byte-compatible with upstream lib/src/wearable_rotary_base.dart:
// any future real ohos implementation can replace this stub without touching
// call sites.

import 'dart:async';

/// A rotary event.
class RotaryEvent {
  /// Constructor
  const RotaryEvent({required this.direction, this.magnitude});

  /// The direction of the rotary event.
  final RotaryDirection direction;

  /// The magnitude of the rotation (null on backends that only report
  /// direction; ohos stub never produces events at all).
  final double? magnitude;
}

/// The direction of the rotary event.
enum RotaryDirection {
  /// A rotation event in the clockwise direction.
  clockwise,

  /// A rotation event in the counter clockwise direction.
  counterClockwise,
}

/// A broadcast stream of events from the device rotary sensor.
///
/// ohos stub: no platform implementation exists yet, so this is a permanently
/// empty stream (never errors, never yields).
Stream<RotaryEvent> get rotaryEvents => _rotaryEvents ??= _emptyStream();

Stream<RotaryEvent>? _rotaryEvents;

Stream<RotaryEvent> _emptyStream() {
  final controller = StreamController<RotaryEvent>.broadcast();
  return controller.stream;
}
