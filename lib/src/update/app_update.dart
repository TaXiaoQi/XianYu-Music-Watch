import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/app_version.dart';
import '../core/watch_fit.dart';
import '../i18n/i18n.dart';
import '../ui/common/full_dialog.dart';

const String kWatchUpdatePromptKey = 'watch_app_update_last_prompt_date';

({List<int> fields, String? pre, int preNum}) _parseVersion(String raw) {
  var s = raw.trim();
  if (s[0] == 'v' || s[0] == 'V') s = s.substring(1);
  final dash = s.indexOf('-');
  final main = dash >= 0 ? s.substring(0, dash) : s;
  final preStr = dash >= 0 ? s.substring(dash + 1) : null;
  final fields = main.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  var preNum = 0;
  if (preStr != null) {
    final m = RegExp(r'(\d+)').firstMatch(preStr);
    preNum = m != null ? int.tryParse(m.group(1)!) ?? 0 : 0;
  }
  return (fields: fields, pre: preStr, preNum: preNum);
}

/// 语义化版本比较：a > b 返回 1，a < b 返回 -1，相等返回 0。
int compareVersions(String a, String b) {
  if (a.isEmpty || b.isEmpty) return a.isEmpty == b.isEmpty ? 0 : (a.isEmpty ? -1 : 1);
  final pa = _parseVersion(a);
  final pb = _parseVersion(b);
  final len =
      pa.fields.length > pb.fields.length ? pa.fields.length : pb.fields.length;
  for (var i = 0; i < len; i++) {
    final av = i < pa.fields.length ? pa.fields[i] : 0;
    final bv = i < pb.fields.length ? pb.fields[i] : 0;
    if (av != bv) return av > bv ? 1 : -1;
  }
  if (pa.pre == null && pb.pre == null) return 0;
  if (pa.pre == null) return 1;
  if (pb.pre == null) return -1;
  final preA = pa.pre!;
  final preB = pb.pre!;
  final aToken = RegExp(r'^[a-zA-Z]*').firstMatch(preA)?.group(0) ?? '';
  final bToken = RegExp(r'^[a-zA-Z]*').firstMatch(preB)?.group(0) ?? '';
  if (aToken != bToken) return aToken.compareTo(bToken) > 0 ? 1 : -1;
  if (pa.preNum != pb.preNum) return pa.preNum > pb.preNum ? 1 : -1;
  if (preA != preB) return preA.compareTo(preB) > 0 ? 1 : -1;
  return 0;
}

bool hasNewVersion(LatestVersion latest) =>
    compareVersions(latest.version, kAppVersion) > 0;

Future<LatestVersion?> fetchWatchLatest(WidgetRef ref) =>
    ref.read(authProvider.notifier).fetchServerUpdate();

String _today() {
  final now = DateTime.now();
  return '${now.year}-${now.month}-${now.day}';
}

/// 今天是否已弹过更新（避免每次进应用都打扰），并记录今天的弹出标记。
/// 返回 true 表示可以弹出更新页。
Future<bool> claimUpdatePrompt() async {
  final prefs = await SharedPreferences.getInstance();
  final today = _today();
  if (prefs.getString(kWatchUpdatePromptKey) == today) return false;
  await prefs.setString(kWatchUpdatePromptKey, today);
  return true;
}

/// 腕上整页更新弹窗：展示最新版本与更新内容。
/// 「去更新」因手表无法直接打开下载链接，提示用户在手机端处理。
Future<void> showUpdatePage(
  BuildContext context,
  LatestVersion latest, {
  VoidCallback? onUpdate,
}) {
  return showFullDialog<void>(
    context: context,
    builder: (ctx) {
      final s = context.watchScale();
      return FullDialogScaffold(
        title: tr('发现新版本'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('v${latest.version}',
                    style: TextStyle(
                        fontSize: 16 * s, fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                _badge(ctx, tr('腕上版')),
              ],
            ),
            SizedBox(height: 10 * s),
            if (latest.content.isNotEmpty)
              Text(
                latest.content,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12 * s,
                    height: 1.55,
                    color: Colors.white.withValues(alpha: 0.72)),
              )
            else
              Text(
                tr('更新内容暂无说明'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12 * s,
                    color: Colors.white.withValues(alpha: 0.45)),
              ),
          ],
        ),
        actions: [
          FullDialogButton(
            label: tr('暂不更新'),
            onPressed: () => Navigator.pop(ctx),
          ),
          FullDialogButton(
            label: tr('去更新'),
            primary: true,
            onPressed: () {
              Navigator.pop(ctx);
              onUpdate?.call();
            },
          ),
        ],
      );
    },
  );
}

Widget _badge(BuildContext context, String text) {
  final s = context.watchScale();
  return Container(
    padding: EdgeInsets.symmetric(horizontal: 6 * s, vertical: 2 * s),
    decoration: BoxDecoration(
      color: const Color(0xFFFF4D6E).withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(text,
        style: TextStyle(
            fontSize: 9 * s,
            color: const Color(0xFFFF4D6E),
            fontWeight: FontWeight.w600)),
  );
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
  );
}

void toastUpdateOnPhone(BuildContext context) {
  _toast(context, tr('请在手机端下载最新版腕上应用'));
}