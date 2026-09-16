
import { FlutterAbility, FlutterEngine, MethodChannel } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';

export default class EntryAbility extends FlutterAbility {
  private systemNavChannel: MethodChannel | null = null;

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // Dart 侧返回链路兜底（lib/app.dart LinkHome 的 PopScope canPop:false）：
    // 根路由无可弹页时调 moveTaskToBack 退后台驻留（应用保持存活，重开秒回）。
    // Android 由 MainActivity 实现 moveTaskToBack；ohos 等价 API 为
    // context.moveAbilityToBackground()。缺此实现会 MissingPluginException →
    // Dart 退化 SystemNavigator.pop() → 直接退出，观感即「左滑退出软件」。
    this.systemNavChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/system_nav');
    this.systemNavChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'moveTaskToBack') {
          this.context.moveAbilityToBackground()
            .then(() => result.success(null))
            .catch(() => result.error('move_failed', 'moveAbilityToBackground failed', null))
        } else {
          result.notImplemented()
        }
      }
    });
  }
}
