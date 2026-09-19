import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';

import '../rust/frb_generated.dart' as frb;

/// 初始化 RustLib 桥接（只初始化一次），与移动端同款：
/// Android 下由 [defaultExternalLibraryLoaderConfig] 按平台加载
/// `libxianyu_core.so`，不手动指定 externalLibrary。
final rustInitProvider = FutureProvider<void>((ref) async {
  final knownPlatform = !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isWindows ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isLinux);
  await frb.RustLib.init(
    forceSameCodegenVersion: false,
    externalLibrary: knownPlatform
        ? null
        : ExternalLibrary.open('libxianyu_core.so'),
  );
});
