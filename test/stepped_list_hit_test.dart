// 阶梯列表「所见即所得」命中回归测试：
// 拖动滚动 → settle → 逐个点击可见行的视觉中心，断言触发的就是该行。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_watch/src/ui/common/stepped_list.dart';

void main() {
  testWidgets('滚动后按视觉位置命中：点哪儿触发哪儿', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          const EventChannel('flutter.wearable_rotary.channel').name,
          (message) async => null,
        );

    tester.view.physicalSize = const Size(200, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var tapped = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SteppedListView(
            itemCount: 40,
            itemBuilder: (context, i) =>
                SteppedTile(title: 'row$i', onTap: () => tapped = i),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const listRect = Rect.fromLTWH(0, 0, 200, 200);
    final failures = <String>[];
    for (final dragDy in const [0.0, -120.0, -260.0, -420.0, -560.0]) {
      if (dragDy != 0.0) {
        await tester.drag(find.byType(ListView), Offset(0, dragDy));
        await tester.pumpAndSettle();
      }
      // 每个可见行：点它的视觉中心，必须触发它自己
      for (var i = 0; i < 40; i++) {
        final f = find.text('row$i');
        if (f.evaluate().isEmpty) continue;
        final c = tester.getCenter(f);
        if (!listRect.contains(c)) continue;
        tapped = -1;
        await tester.tapAt(c);
        await tester.pump();
        if (tapped != i) {
          failures.add('offset~$dragDy: 点 row$i 视觉中心 $c 实际触发 row$tapped');
        }
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  testWidgets('页面销毁再重建（模拟 PageView 翻走再翻回）不崩且可交互', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          const EventChannel('flutter.wearable_rotary.channel').name,
          (message) async => null,
        );

    tester.view.physicalSize = const Size(200, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final list = SteppedListView(
      itemCount: 12,
      itemBuilder: (context, i) => SteppedTile(title: 'row$i'),
    );
    var showList = true;
    void Function(void Function())? setState;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: StatefulBuilder(
            builder: (context, markDirty) {
              setState = markDirty;
              return showList ? list : const Center(child: Text('home'));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 翻到主页：列表销毁
    setState!(() => showList = false);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);

    // 翻回功能页：全新 State 重建（重复 3 轮）
    for (var round = 0; round < 3; round++) {
      setState!(() => showList = true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView), const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      setState!(() => showList = false);
      await tester.pumpAndSettle();
    }
  });
}
