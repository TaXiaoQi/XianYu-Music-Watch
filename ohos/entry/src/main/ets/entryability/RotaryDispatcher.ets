import { EventSink } from '@ohos/flutter_ohos';

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
