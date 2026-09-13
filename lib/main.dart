import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'src/core/rust_init.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  // 尽早触发 rust 初始化（与首帧渲染并行），缩短「打开→可交互」的等待。
  container.read(rustInitProvider);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const XianYuWatchApp(),
    ),
  );
}
