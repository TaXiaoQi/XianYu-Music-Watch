import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/listen_stats.dart';
import '../player/watch_audio_service.dart';
import 'rust_init.dart';

/// 应用运行模式（腕上双模式剥离）：
/// - [appModeLink]（默认）：低占用联动模式，手表作外置控制器；不启动
///   媒体前台服务/听歌统计，主页为联动三页（功能/播放/歌词），常驻后台
///   等手机一播放即可推送到手表。
/// - [appModeStandalone]：完整独立模式，手表独立播放/搜索/本地库，起完整服务。
const appModeKey = 'appMode';
const appModeLink = 'link';
const appModeStandalone = 'standalone';

/// 读当前启动模式（默认联动）。启动早期可用，无需 provider。
Future<String> readAppMode() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getString(appModeKey) ?? appModeLink) == appModeStandalone
      ? appModeStandalone
      : appModeLink;
}

/// 写模式并落盘（供「切换」前调用，重启后读到新模式）。
Future<void> writeAppMode(String mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(appModeKey, mode);
}

/// 当前运行模式（可响应）：冷启动由 [main] 经 [AppModeNotifier.seed] 播种，
/// 运行中经 [AppModeNotifier.change] 热切换（不重启进程）。
class AppModeNotifier extends Notifier<String> {
  static String _seeded = appModeLink;

  /// main() 首帧前把启动读到的模式播种（build 需同步初值）。
  static void seed(String mode) => _seeded = mode;

  @override
  String build() => _seeded;

  bool get isLink => state == appModeLink;
  bool get isStandalone => state == appModeStandalone;

  /// 热切换到 [mode]（联动↔独立）：落盘新模式 + 补齐该模式所需的重服务
  /// 初始化 + 更新状态触发首页重建。不依赖原生杀进程重启——鸿蒙
  /// ApplicationContext.restartApp 是「不保留应用窗口」重启（API 22 才有
  /// 保留窗口版，腕上达不到），重启后停留在桌面不自动回前台；热切换始终
  /// 在前台、秒切自动打开新界面，Android/鸿蒙一致。
  Future<void> change(String mode) async {
    if (mode != appModeLink && mode != appModeStandalone) return;
    if (mode == state) return;
    await writeAppMode(mode);
    if (mode == appModeStandalone) {
      // 从联动热切独立：补初始化被联动 gate 掉的完整独立服务（rust 桥接 /
      // 听歌统计 / 媒体前台服务），provider 惰性且已在此容器，read 即触发。
      ref.read(rustInitProvider);
      ref.read(listenStatsProvider);
      initWatchAudioService();
    }
    state = mode;
  }
}

final appModeProvider = NotifierProvider<AppModeNotifier, String>(
  AppModeNotifier.new,
);