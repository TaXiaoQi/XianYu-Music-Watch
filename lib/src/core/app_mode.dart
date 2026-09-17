import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 写模式并落盘（供「切换→重启」前调用，新进程启动时读到新模式）。
Future<void> writeAppMode(String mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(appModeKey, mode);
}

/// 当前启动模式（供 UI 判断：独立模式的设备联动页需显示「切回联动」行）。
final appModeProvider = FutureProvider<String>((ref) => readAppMode());