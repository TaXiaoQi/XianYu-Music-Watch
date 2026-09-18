
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

  // 系统返回兜底：back 的可消费点在 @Entry 页 onBackPress（Index.ets），但
  // 部分固件会把 back 派发到 ability 级而非页级——不重写时默认退后台/销毁，
  // 表现即「侧滑直接退出、二级页回不到一级页」。这里同样转发给 Flutter
  // （BackDispatcher 内部 300ms 去重，页级+能力级双重派发只转发一次）。
  // 注意：不要在这里调 setGestureBackEnabled(false)——关掉系统返回手势后，
  // 表固件的右滑不再走 onBackPress→popRoute 这条可消费链路，而变成
  // SystemUI 层「滑走应用」任务手势，任何回调都收不到（二级页直接退出）。
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
    // Dart 侧返回链路兜底（lib/app.dart LinkHome 的 PopScope canPop:false）：
    // 根路由无可弹页时调 moveTaskToBack 退后台驻留（应用保持存活，重开秒回）。
    // Android 由 MainActivity 实现 moveTaskToBack；ohos 等价 API 为
    // context.moveAbilityToBackground()。缺此实现会 MissingPluginException →
    // Dart 退化 SystemNavigator.pop() → 直接退出，观感即「左滑退出软件」。
    // 另扩 restartApp：调试/兜底用（模式切换已改为进程内热切换
    // AppModeNotifier.change()，不重启进程、不经过此通道）。
    this.systemNavChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/system_nav');
    this.systemNavChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'moveTaskToBack') {
          // 归因标记：若 MoveUIAbilityToBackground 前有本行，说明背景化是
          // Dart 侧 _EdgeBackStrip→moveTaskToBack 触发；否则为系统侧滑返回。
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

    // 圆/方屏形探测：鸿蒙无官方 isScreenRound，用分辨率宽高比判定——圆形
    // 表盘分辨率必为 1:1（如 Watch 3 466×466），方形表为长条（如 Watch Fit
    // 456×280），比值差 10% 内视为圆表。与 Android 侧
    // resources.configuration.isScreenRound 对齐语义。
    this.screenShapeChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/screen_shape');
    this.screenShapeChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'isRound') {
          // getDefaultDisplaySync 需 API 15+，Watch 3 鸿蒙 4 可能仅有
          // API 10-12，用 API 9 起可用的 promise 版 getDefaultDisplay。
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

    // 联动模式低占用常驻保活：ohos 等价于 Android 前台服务的是「长时任务」
    // （backgroundTaskManager 连续任务，DATA_TRANSFER 蓝牙/云中继语义）。
    // 联动进程启动时经此申请连续任务，退后台后蓝牙/云链路仍存活、手机播放
    // 可快速唤起。仅调用一次；切独立模式 restartApp 重拉进程后不再申请。
    // 注：系统会对连续任务的「真实业务」做检测，空闲无数据传输时可能取消
    // 任务并挂起应用——属系统级约束，尽力而为、失败静默。
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

    // 表冠旋转 → Dart：Index.ets 根组件 onDigitalCrown（ArkUI 通用事件，
    // API 18+）拿到 CrownEvent 后经 RotaryDispatcher 塞进本通道的 EventSink；
    // Dart 侧 third_party/wearable_rotary（ohos 实现）的 rotaryEvents 监听
    // 本通道，5 处调用点零改动恢复表冠能力。消息 = 带符号角度增量
    // CrownEvent.degree（正=顺时针，按逐事件增量处理；若真机表现为慢转
    // 飞屏则是累计角，需在 Index.ets 侧自行做差分）。Dart 未监听时置空
    // 丢弃；重复 onListen（热重启）以后到的 sink 为准。
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
