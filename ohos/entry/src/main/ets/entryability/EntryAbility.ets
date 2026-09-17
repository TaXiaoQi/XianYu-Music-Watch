
import { common, Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { display } from '@kit.ArkUI';
import { FlutterAbility, FlutterEngine, MethodChannel } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';

export default class EntryAbility extends FlutterAbility {
  private systemNavChannel: MethodChannel | null = null;
  private keepAliveChannel: MethodChannel | null = null;
  private screenShapeChannel: MethodChannel | null = null;
  private keepAliveStarted = false;

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // Dart 侧返回链路兜底（lib/app.dart LinkHome 的 PopScope canPop:false）：
    // 根路由无可弹页时调 moveTaskToBack 退后台驻留（应用保持存活，重开秒回）。
    // Android 由 MainActivity 实现 moveTaskToBack；ohos 等价 API 为
    // context.moveAbilityToBackground()。缺此实现会 MissingPluginException →
    // Dart 退化 SystemNavigator.pop() → 直接退出，观感即「左滑退出软件」。
    // 另扩 restartApp：联动↔独立模式切换时，先落盘模式字段，再经此原生
    // 重启把应用彻底重拉起，新进程在 main() 按新模式初始化（不触发本
    // Ability 的 onDestroy，Window 不保留，完全重新启动，对应官方
    // ApplicationContext.restartApp，API 12+，本项目 SDK 18 可用）。
    this.systemNavChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/system_nav');
    this.systemNavChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'moveTaskToBack') {
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
