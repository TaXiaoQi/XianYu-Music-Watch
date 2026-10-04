// 备份域单测：备份文件名、歌单存储模型（CloudSong/CloudPlaylist）
// 与 WatchBackupService.importJson 的入参校验/恢复计数/去重逻辑。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xianyu_watch/src/backup/watch_backup.dart';
import 'package:xianyu_watch/src/sync/playlist_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('watchBackupFileName 命名格式', () {
    expect(RegExp(r'^xianyu-backup-\d{4}-\d{2}-\d{2}\.json$').hasMatch(
      watchBackupFileName(),
    ), isTrue);
  });

  test('CloudSong.fromJson 兼容移动端备份字段', () {
    final s = CloudSong.fromJson({
      'localPath': '/sdcard/a.flac',
      'name': '歌名',
      'artist': '歌手',
      'duration': 213500,
      'pluginId': 'kw',
      'addedInApp': true,
    });
    expect(s.path, '/sdcard/a.flac');
    expect(s.title, '歌名');
    expect(s.artist, '歌手');
    expect(s.durationSec, 214);
    expect(s.isOnline, isTrue);
    expect(s.addedInApp, isTrue);
  });

  test('CloudSong 本地歌曲 isOnline=false，缺省字段兜底', () {
    final s = CloudSong.fromJson({'path': '/c.mp3', 'title': 't'});
    expect(s.isOnline, isFalse);
    expect(s.durationSec, 0);
    expect(s.musicInfo, isEmpty);
  });

  test('CloudSong 在线歌曲无插件 id 也判在线（lx://）', () {
    final s = CloudSong.fromJson({'path': 'lx://track/1', 'title': 't'});
    expect(s.isOnline, isTrue);
  });

  test('CloudPlaylist toJson→fromJson 往返', () {
    final p = CloudPlaylist(
      cloudId: 'c1',
      name: '我的歌单',
      songs: [
        const CloudSong(path: '/a.flac', title: 'A', artist: '甲'),
        const CloudSong(path: 'plugin://x/1', title: 'B', pluginId: 'kg'),
      ],
      sourcePluginId: 'kw',
      sourceUrl: 'https://example.com/pl',
      sourceRaw: const {'k': 'v'},
    );
    final p2 = CloudPlaylist.fromJson(
      jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
    );
    expect(p2.cloudId, 'c1');
    expect(p2.name, '我的歌单');
    expect(p2.sourcePluginId, 'kw');
    expect(p2.sourceUrl, 'https://example.com/pl');
    expect(p2.sourceRaw, {'k': 'v'});
    expect(p2.songs.length, 2);
    expect(p2.songs[0].title, 'A');
    expect(p2.songs[1].isOnline, isTrue);
  });

  test('CloudPlaylist.fromJson 丢弃空 path 歌曲与缺省歌单名', () {
    final p = CloudPlaylist.fromJson({
      'songs': [
        {'title': 'no-path'},
        {'path': '/ok.mp3', 'title': 'ok'},
      ],
    });
    expect(p.name, '未命名歌单');
    expect(p.songs.length, 1);
    expect(p.songs.single.path, '/ok.mp3');
  });

  test('CloudPlaylistStore saveAll/loadAll 持久化往返', () async {
    SharedPreferences.setMockInitialValues({});
    await CloudPlaylistStore.saveAll([
      const CloudPlaylist(
        cloudId: 'c1',
        name: 'p1',
        songs: [CloudSong(path: '/x.mp3', title: 'x')],
      ),
    ]);
    final loaded = await CloudPlaylistStore.loadAll();
    expect(loaded.single.name, 'p1');
    expect(loaded.single.songs.single.path, '/x.mp3');
  });

  test('CloudPlaylistStore.loadAll 空存储返回空列表，坏数据兜底', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await CloudPlaylistStore.loadAll(), isEmpty);
    SharedPreferences.setMockInitialValues({
      'xianyu_watch_cloud_playlists_v1': '{broken',
    });
    expect(await CloudPlaylistStore.loadAll(), isEmpty);
  });

  group('WatchBackupService.importJson', () {
    late ProviderContainer container;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('非 JSON 抛格式错误', () {
      final svc = container.read(watchBackupProvider);
      expect(() => svc.importJson('not-json'), throwsFormatException);
    });

    test('schema 不符抛无法识别的备份格式', () {
      final svc = container.read(watchBackupProvider);
      expect(
        () => svc.importJson(jsonEncode({'schema': 'other', 'data': {}})),
        throwsFormatException,
      );
    });

    test('data 非 Map 抛结构无效', () {
      final svc = container.read(watchBackupProvider);
      expect(
        () => svc.importJson(jsonEncode({
          'schema': 'xianyu-music.app-backup',
          'data': [],
        })),
        throwsFormatException,
      );
    });

    test('有效最小备份：歌单导入计数并写入持久层', () async {
      final svc = container.read(watchBackupProvider);
      final backup = jsonEncode({
        'schema': 'xianyu-music.app-backup',
        'version': 2,
        'platform': 'watch',
        'data': {
          'favorites': [],
          'playlists': [
            {
              'name': '新歌单',
              'songs': [
                {'path': '/a.flac', 'title': 'A'},
              ],
            },
          ],
          'plugins': [],
          'settings': {'watch': null},
        },
      });
      final r1 = await svc.importJson(backup);
      expect(r1['playlists'], 1);
      expect(r1['favorites'], 0);
      expect(r1['plugins'], 0);
      expect(r1['settings'], 0);
      final stored = await CloudPlaylistStore.loadAll();
      expect(stored.single.name, '新歌单');
      expect(stored.single.songs.single.path, '/a.flac');
    });

    test('同名歌单第二次导入去重不重复', () async {
      final svc = container.read(watchBackupProvider);
      final backup = jsonEncode({
        'schema': 'xianyu-music.app-backup',
        'version': 2,
        'platform': 'watch',
        'data': {
          'playlists': [
            {
              'name': '重复歌单',
              'songs': [
                {'path': '/b.mp3', 'title': 'B'},
              ],
            },
          ],
        },
      });
      expect((await svc.importJson(backup))['playlists'], 1);
      expect((await svc.importJson(backup))['playlists'], 0);
      expect((await CloudPlaylistStore.loadAll()).length, 1);
    });

    test('损坏的收藏条目被跳过不致失败', () async {
      final svc = container.read(watchBackupProvider);
      final r = await svc.importJson(jsonEncode({
        'schema': 'xianyu-music.app-backup',
        'version': 2,
        'platform': 'watch',
        'data': {
          'favorites': [
            'not-a-map',
            {'path': ''},
          ],
          'playlists': [],
        },
      }));
      expect(r['favorites'], 0);
    });
  });
}
