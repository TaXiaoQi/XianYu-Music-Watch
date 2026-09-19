
import { common, Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FlutterAbility, FlutterEngine, MethodChannel, EventChannel, EventSink, Any } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { dispatchBackToFlutter } from './BackDispatcher';
import { attachRotarySink } from './RotaryDispatcher';

export default class EntryAbility extends FlutterAbility {
  private systemNavChannel: MethodChannel | null = null;
  private keepAliveChannel: MethodChannel | null = null;
  private screenShapeChannel: MethodChannel | null = null;
  private keepAliveStarted = false;

  onBackPressed(): boolean {
    dispatchBackToFlutter(this.context)
    return true
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    super.onWindowStageCreate(windowStage)
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    this.systemNavChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/system_nav');
    this.systemNavChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'moveTaskToBack') {
          hilog.info(0x0100, 'xianyu', 'MOVE_TASK_TO_BACK CALLED (from Dart)')
          this.context.moveAbilityToBackground()
            .then(() => result.success(null))
            .catch(() => result.error('move_failed', 'moveAbilityToBackground failed', null))
        } else if (call.method === 'restartApp') {
          const appContext = this.context.getApplicationContext() as common.ApplicationContext
          try {
            const want: Want = {
              bundleName: 'com.xianyumusic.watch',
              abilityName: 'EntryAbility'
            }
            appContext.restartApp(want)
            result.success(null)
          } catch (err) {
            result.error('restart_failed', `restartApp failed: ${(err as Error).message}`,
              null)
          }
        } else {
          result.notImplemented()
        }
      }
    });

    this.screenShapeChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/screen_shape');
    this.screenShapeChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'isRound') {
          display.getDefaultDisplay()
            .then((d) => {
              const w = d.width
              const h = d.height
              const isRound = w > 0 && h > 0 &&
                Math.abs(w - h) / Math.max(w, h) < 0.1
              result.success(isRound)
            })
            .catch((err: Error) => result.error('probe_failed', String(err), null))
        } else {
          result.notImplemented()
        }
      }
    });

    this.keepAliveChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/keep_alive');
    this.keepAliveChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'start') {
          this.startKeepAlive()
            .then(() => result.success(true))
            .catch((err: Error) => result.error('keepalive_failed', String(err), null))
        } else {
          result.notImplemented()
        }
      }
    });

    const rotaryChannel = new EventChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/rotary');
    rotaryChannel.setStreamHandler({
      onListen: (args: Any, events: EventSink) => {
        attachRotarySink(events)
      },
      onCancel: (args: Any) => {
        attachRotarySink(null)
      }
    });
  }

  private async startKeepAlive(): Promise<void> {
    if (this.keepAliveStarted) {
      return
    }
    const wa = await wantAgent.getWantAgent({
      wants: [{ bundleName: 'com.xianyumusic.watch', abilityName: 'EntryAbility' }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0
    } as wantAgent.WantAgentInfo)
    await backgroundTaskManager.startBackgroundRunning(
      this.context,
      backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
      wa
    )
    this.keepAliveStarted = true
  }
}
