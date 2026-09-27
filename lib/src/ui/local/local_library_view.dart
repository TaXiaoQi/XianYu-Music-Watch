import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/watch_fit.dart';
import '../../i18n/i18n.dart';
import '../../library/library_provider.dart';
import '../../library/scan_settings_provider.dart';
import '../common/full_dialog.dart';
import '../common/stepped_list.dart';
import '../online/search_page.dart';
import 'local_music_hub.dart';

class LocalLibraryView extends ConsumerStatefulWidget {
  const LocalLibraryView({super.key});

  @override
  ConsumerState<LocalLibraryView> createState() => _LocalLibraryViewState();
}

class _LocalLibraryViewState extends ConsumerState<LocalLibraryView> {
  bool _scanning = false;

  /// 无扫描目录时的默认候选：手表侧音乐常见落点
  static const _defaultDirs = [
    '/storage/emulated/0/Music',
    '/storage/emulated/0/Download',
    '/storage/emulated/0/DCIM/Music',
    '/storage/emulated/0/Bluetooth',
  ];

  Future<bool> _ensurePermission() async {
    if (await Permission.audio.request().isGranted) return true;
    if (await Permission.storage.request().isGranted) return true;
    return false;
  }

  Future<void> _scan() async {
    final granted = await _ensurePermission();
    if (!granted && mounted) {
      // 腕上不使用小弹窗：改为完整窗口，并提供去授权入口
      final goSettings = await showFullConfirm(
        context,
        title: tr('需要存储权限'),
        message: tr('需要存储权限才能扫描本地音乐'),
        okLabel: tr('去授权'),
      );
      if (goSettings == true) await openAppSettings();
      return;
    }
    setState(() => _scanning = true);
    try {
      final folders = await ref.read(scanFoldersProvider.future);
      if (folders.isEmpty) {
        var added = 0;
        for (final dir in _defaultDirs) {
          if (Directory(dir).existsSync()) {
            await ref.read(scanFoldersProvider.notifier).addFolder(dir);
            added++;
          }
        }
        if (added == 0 && mounted) {
          await showFullConfirm(
            context,
            title: tr('未找到音乐目录'),
            message: tr('请将音乐文件放入手表的 Music 或 Download 文件夹后重试'),
            okOnly: true,
          );
          return;
        }
      }
      final total = await ref.read(libraryProvider.notifier).scanAllFolders();
      if (total == 0 && mounted) {
        await showFullConfirm(
          context,
          title: tr('未找到音乐文件'),
          message: tr('已扫描的目录中没有音乐，可将文件放入 Music 或 Download 后重试'),
          okOnly: true,
        );
      }
    } catch (e) {
      if (mounted) {
        await showFullConfirm(
          context,
          title: tr('扫描失败'),
          message: '$e',
          okOnly: true,
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final songs = lib.songs;
    final s = context.watchScale();

    if (songs.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _EmptyView(scanning: _scanning, onScan: _scan),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SteppedListView(
          header: PageTitleHeader(tr('本地音乐'), showBack: false),
          itemCount: songs.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return SteppedTile(
                leading: SteppedLeadCircle(
                  color: const Color(0xFF4A90D9),
                  child: Icon(
                    Icons.travel_explore_rounded,
                    size: 22 * s,
                    color: Colors.white,
                  ),
                ),
                title: tr('搜索'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const OnlineSearchPage(),
                  ),
                ),
              );
            }
            final song = songs[i - 1];
            return SteppedTile(
              leading: ClipOval(
                child: SizedBox(
                  width: 44 * s,
                  height: 44 * s,
                  child:
                      song.coverThumbPath != null &&
                          song.coverThumbPath!.isNotEmpty
                      ? Image.file(
                          File(song.coverThumbPath!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const _SongIcon(),
                        )
                      : const _SongIcon(),
                ),
              ),
              title: song.title,
              subtitle: song.artist.isEmpty ? tr('未知歌手') : song.artist,
              onTap: () async {
                await ref.read(libraryProvider.notifier).playFrom(i);
                if (!context.mounted) return;
                ref.read(localHubPageProvider.notifier).state = 1;
                Navigator.of(context).pop();
              },
            );
          },
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.scanning, required this.onScan});

  final bool scanning;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Center(
      // 圆屏可用高度极小，滚动兜底避免 Column 溢出
      child: SingleChildScrollView(
        padding: EdgeInsets.all(24 * s),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.library_music_rounded,
              size: 40 * s,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            SizedBox(height: 12 * s),
            Text(
              tr('本地音乐'),
              style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 4 * s),
            Text(
              tr('扫描手机/手表中的音乐文件'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12 * s,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
            SizedBox(height: 18 * s),
            FilledButton.icon(
              onPressed: scanning ? null : onScan,
              icon: scanning
                  ? SizedBox(
                      width: 14 * s,
                      height: 14 * s,
                      child: CircularProgressIndicator(strokeWidth: 2 * s),
                    )
                  : Icon(Icons.search_rounded, size: 18 * s),
              label: Text(scanning ? tr('扫描中…') : tr('扫描本地音乐')),
            ),
          ],
        ),
      ),
    );
  }
}

class _SongIcon extends StatelessWidget {
  const _SongIcon();

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Container(
      color: const Color(0xFF1A1A1E),
      child: Icon(
        Icons.music_note_rounded,
        size: 22 * s,
        color: Colors.white.withValues(alpha: 0.35),
      ),
    );
  }
}
