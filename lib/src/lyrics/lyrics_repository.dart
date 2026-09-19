import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_provider.dart';
import '../rust/api.dart';
import 'lyric_model.dart';

final Map<String, List<LyricLine>> _linesCache = {};
const int _lyricsCacheMax = 8;

void _cacheLyrics(String key, List<LyricLine> lines) {
  if (key.isEmpty || lines.isEmpty) return;
  _linesCache[key] = lines;
  if (_linesCache.length > _lyricsCacheMax) {
    _linesCache.remove(_linesCache.keys.first);
  }
}

class LyricsRepository {
  LyricsRepository(this._ref);

  final Ref _ref;

  Future<List<LyricLine>> fetchLyrics(QueueItem item) async {
    final key = _keyOf(item);
    final cached = _linesCache[key];
    if (cached != null) return cached;
    try {
      final payload = await fetchPayloadJson(item);
      if (payload.isEmpty || payload == 'null') return const [];
      final lines = parsePayload(payload);
      if (lines.isNotEmpty) _cacheLyrics(key, lines);
      return lines;
    } catch (_) {
      return const [];
    }
  }

  Future<String> fetchPayloadJson(QueueItem item) async {
    if (item.onlineSongJson != null && item.onlineSongJson!.isNotEmpty) {
      final pluginText = await _fetchPluginLyric(item);
      if (pluginText.trim().isNotEmpty) {
        return parseLyrics(rawLyrics: pluginText);
      }
      if (item.source != null && item.onlineInfoJson != null) {
        return _fetchFromBuiltinSource(item.source!, item.onlineInfoJson!);
      }
      return '';
    }
    final dbPath = await _ref.read(dbPathProvider.future);
    return getSongLyricsPayload(dbPath: dbPath, path: item.path);
  }

  Future<String> _fetchFromBuiltinSource(String source, String infoJson) async {
    final rawResult = await fetchLyricFromSource(
      source: source,
      songInfoJson: infoJson,
    );
    if (rawResult == 'null' || rawResult.isEmpty) return '';
    String text = '';
    try {
      final obj = jsonDecode(rawResult) as Map<String, dynamic>;
      final lxlyric = obj['lxlyric'] as String? ?? '';
      final lyric = obj['lyric'] as String? ?? '';
      final tlyric = obj['tlyric'] as String? ?? '';
      if (lxlyric.trim().isNotEmpty) {
        text = lxlyric;
      } else if (lyric.trim().isNotEmpty) {
        text = tlyric.trim().isNotEmpty ? '$lyric\n$tlyric' : lyric;
      }
    } catch (_) {
      text = rawResult;
    }
    if (text.trim().isEmpty) return '';
    return parseLyrics(rawLyrics: text);
  }

  Future<String> _fetchPluginLyric(QueueItem item) async {
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(item.onlineSongJson!) as Map<String, dynamic>;
    } catch (_) {
      return '';
    }
    final pluginId = parsed['pluginId'] as String?;
    if (pluginId == null || pluginId.isEmpty) return '';
    final sourceKey = parsed['source'] as String? ?? '';
    final musicInfo = parsed['musicInfo'] as Map<String, dynamic>? ?? {};
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final matches = sources.where((s) => s.id == pluginId).toList();
      if (matches.isEmpty) return '';
      final res = await engine.getLyric(matches.first, sourceKey, musicInfo);
      if (res == null) return '';
      final mainText = (res['lxlyric'] ??
              res['yrc'] ??
              res['qrc'] ??
              res['eslrc'] ??
              res['lyric']) as String? ??
          '';
      if (mainText.trim().isEmpty) return '';
      final tlyric = (res['tlyric'] as String?)?.trim() ?? '';
      if (tlyric.isNotEmpty && !mainText.contains('tlyric')) {
        return '$mainText\n$tlyric';
      }
      return mainText;
    } catch (_) {
      return '';
    }
  }
}

String _keyOf(QueueItem item) =>
    item.onlineSongJson != null && item.onlineSongJson!.isNotEmpty
        ? 'online:${item.title}|${item.artist}'
        : item.path;

final lyricsRepositoryProvider =
    Provider<LyricsRepository>((ref) => LyricsRepository(ref));

String _cleanLyricText(String raw) {
  if (raw.isEmpty) return '';
  String text = raw;
  text = text.replaceAll(
    RegExp(
      r'\[(ar|ti|al|by|offset|kuwo|kugou|hash|sign|qq|total|language|types):[^\]]*\]',
      caseSensitive: false,
    ),
    '',
  );
  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');
  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  return text.trim();
}

List<LyricLine> parsePayload(String jsonStr) {
  final map = jsonDecode(jsonStr) as Map<String, dynamic>;
  final rawLines =
      (map['displayLines'] as List?) ??
      (map['display_lines'] as List?) ??
      (map['lines'] as List?) ??
      [];
  final lines = <LyricLine>[];
  for (final item in rawLines) {
    if (item is! Map<String, dynamic>) continue;
    double timeSec = 0.0;
    if (item['time'] is num) {
      timeSec = (item['time'] as num).toDouble();
    } else if (item['timeMs'] is num) {
      timeSec = (item['timeMs'] as num).toDouble() / 1000.0;
    } else if (item['startTime'] is num) {
      timeSec = (item['startTime'] as num).toDouble();
    } else if (item['startTimeMs'] is num) {
      timeSec = (item['startTimeMs'] as num).toDouble() / 1000.0;
    }

    double endTimeSec = 0.0;
    final rawEndTime = item['endTime'] ?? item['end_time'];
    if (rawEndTime is num) {
      endTimeSec = rawEndTime.toDouble();
    } else if (item['endTimeMs'] is num) {
      endTimeSec = (item['endTimeMs'] as num).toDouble() / 1000.0;
    }

    final text = _cleanLyricText((item['text'] as String?) ?? '');
    final rawTrans = item['translation'] as String?;
    final translation = rawTrans != null && rawTrans.trim().isNotEmpty
        ? _cleanLyricText(rawTrans)
        : null;
    final rawRomaji = (item['romaji'] as String?)?.trim();
    final romaji =
        (rawRomaji != null && rawRomaji.isNotEmpty) ? rawRomaji : null;

    final secondary = <String>[];
    final rawSecondary = item['secondary'] as List?;
    if (rawSecondary != null) {
      for (final s in rawSecondary) {
        if (s is String && s.trim().isNotEmpty) {
          secondary.add(_cleanLyricText(s));
        }
      }
    }

    if (text.isNotEmpty) {
      lines.add(LyricLine(
        timeMs: (timeSec * 1000).toInt(),
        endTimeMs: (endTimeSec * 1000).round(),
        text: text,
        translation: translation,
        romaji: romaji,
        secondary: secondary,
        speaker: (item['speaker'] as String?)?.trim().isNotEmpty == true
            ? (item['speaker'] as String).trim()
            : null,
        isBg: item['isBg'] == true,
        isDuet: item['isDuet'] == true,
        isDuetPartner: item['isDuetPartner'] == true,
      ));
    }
  }
  return _normalizeBoundaries(lines);
}

List<LyricLine> _normalizeBoundaries(List<LyricLine> lines) {
  final result = <LyricLine>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final startMs = line.timeMs.toDouble();
    final nextStartMs = i + 1 < lines.length
        ? lines[i + 1].timeMs.toDouble()
        : double.infinity;

    var endMs = line.endTimeMs.toDouble();
    if (endMs <= startMs) {
      if (nextStartMs.isFinite) {
        final gap = nextStartMs - startMs;
        final leadIn = gap < 1200.0 ? gap * 0.25 : 300.0;
        endMs = nextStartMs - leadIn;
      } else {
        endMs = startMs + 5000;
      }
    }
    endMs = endMs < startMs + 40 ? startMs + 40 : endMs;

    result.add(LyricLine(
      timeMs: line.timeMs,
      endTimeMs: endMs.round(),
      text: line.text,
      translation: line.translation,
      romaji: line.romaji,
      words: line.words,
      secondary: line.secondary,
      speaker: line.speaker,
      isBg: line.isBg,
      isDuet: line.isDuet,
      isDuetPartner: line.isDuetPartner,
    ));
  }
  return result;
}
