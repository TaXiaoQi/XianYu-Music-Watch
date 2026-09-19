import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/watch_fit.dart';
import '../../library/library_provider.dart';
import '../../library/scan_settings_provider.dart';
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

  Future<bool> _ensurePermission() async {
    if (await Permission.audio.request().isGranted) return true;
    if (await Permission.storage.request().isGranted) return true;
    return false;
  }

  Future<void> _scan() async {
    final granted = await _ensurePermission();
    if (!granted && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('需要存储权限才能扫描本地音乐')));
      return;
    }
    setState(() => _scanning = true);
    try {
      final folders = await ref.read(scanFoldersProvider.future);
      if (folders.isEmpty) {
        const musicDir = '/storage/emulated/0/Music';
        if (Directory(musicDir).existsSync()) {
          await ref.read(scanFoldersProvider.notifier).addFolder(musicDir);
        }
      }
      await ref.read(libraryProvider.notifier).scanAllFolders();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫描失败：$e')));
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
          header: PageTitleHeader('本地音乐', showBack: false),
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
                title: '搜索',
                subtitle: '插件在线音源',
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
              subtitle: song.artist.isEmpty ? '未知歌手' : song.artist,
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
      child: Padding(
        padding: EdgeInsets.all(24 * s),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_rounded,
              size: 40 * s,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            SizedBox(height: 12 * s),
            Text(
              '本地音乐',
              style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 4 * s),
            Text(
              '扫描手机/手表中的音乐文件',
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
