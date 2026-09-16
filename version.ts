/**
 * 应用版本号 —— 腕上端唯一版本号源头（参考移动端）。
 *
 * 修改版本号时只需修改此处的 APP_VERSION，
 * 然后运行 `dart run tool/sync_version.dart` 即可自动同步到：
 *   - pubspec.yaml（version 字段，+build 段按公式自动推导，含单调保护）
 *   - lib/src/core/app_version.dart（kAppVersion 常量，设置页「关于」等展示用）
 *
 * 界面代码需读取版本号时，统一 import 生成的 app_version.dart，
 * 不要在业务代码里硬编码版本字符串。
 */
export const APP_VERSION = '0.1.0-beta3';
