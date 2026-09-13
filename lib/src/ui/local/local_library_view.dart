import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../library/library_provider.dart';
import '../../library/scan_settings_provider.dart';
import '../online/search_page.dart';
import 'local_music_hub.dart';

/// 独立模式本地库页：权限引导 → 扫描 → 圆屏歌曲列表 → 点歌进播放页。
class LocalLibraryView extends ConsumerStatefulWidget {
  const LocalLibraryView({super.key});

  @override
  ConsumerState<LocalLibraryView> createState() => _LocalLibraryViewState();
}

class _LocalLibraryViewState extends ConsumerState<LocalLibraryView> {
  bool _scanning = false;

  /// 请求本地音乐读取权限（Android 13+ READ_MEDIA_AUDIO，12 及以下存储读）。
  Future<bool> _ensurePermission() async {
    if (await Permission.audio.request().isGranted) return true;
    if (await Permission.storage.request().isGranted) return true;
    return false;
  }

  Future<void> _scan() async {
    final granted = await _ensurePermission();
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('需要存储权限才能扫描本地音乐')),
      );
      return;
    }
    setState(() => _scanning = true);
    try {
      // 尚无扫描目录时自动加入默认音乐目录，之后全量扫描。
      final folders = await ref.read(scanFoldersProvider.future);
      if (folders.isEmpty) {
        const musicDir = '/storage/emulated/0/Music';
        if (Directory(musicDir).existsSync()) {
          await ref
              .read(scanFoldersProvider.notifier)
              .addFolder(musicDir);
        }
      }
      await ref.read(libraryProvider.notifier).scanAllFolders();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('扫描失败：$e')),
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

    if (songs.isEmpty) {
      return _EmptyView(scanning: _scanning, onScan: _scan);
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: songs.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.travel_explore_rounded, size: 22),
            title: const Text(
              '在线搜索',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '插件在线音源',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const OnlineSearchPage()),
            ),
          );
        }
        final s = songs[i - 1];
        return ListTile(
          dense: true,
          leading: ClipOval(
            child: SizedBox(
              width: 34,
              height: 34,
              child: s.coverThumbPath != null &&
                      File(s.coverThumbPath!).existsSync()
                  ? Image.file(File(s.coverThumbPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const _SongIcon())
                  : const _SongIcon(),
            ),
          ),
          title: Text(
            s.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            s.artist.isEmpty ? '未知歌手' : s.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          onTap: () async {
            await ref.read(libraryProvider.notifier).playFrom(i);
            if (!context.mounted) return;
            // 网易云式：点歌后返回 hub 并自动切到播放页。
            ref.read(localHubPageProvider.notifier).state = 1;
            Navigator.of(context).pop();
          },
        );
      },
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.scanning, required this.onScan});

  final bool scanning;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_rounded,
              size: 40,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            const Text(
              '本地音乐',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '扫描手机/手表中的音乐文件',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: scanning ? null : onScan,
              icon: scanning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded, size: 18),
              label: Text(scanning ? '扫描中…' : '扫描本地音乐'),
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
    return Container(
      color: const Color(0xFF1A1A1E),
      child: Icon(
        Icons.music_note_rounded,
        size: 18,
        color: Colors.white.withValues(alpha: 0.35),
      ),
    );
  }
}
