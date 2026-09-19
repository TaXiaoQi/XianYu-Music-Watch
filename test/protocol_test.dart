import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_watch/src/link/protocol.dart';

void main() {
  test('CRC16-CCITT-FALSE 标准校验向量 "123456789" 应为 0x29B1', () {
    expect(crc16CcittFalse(utf8.encode('123456789')), 0x29B1);
  });

  test('cloud_bind 帧编解码往返（含 url 可选缺省）', () {
    final seq = makeSeqGenerator();
    final decoder = FrameDecoder();

    final withUrl = LinkMessage.cloudBind(
      key: 'a' * 64,
      url: 'wss://api.xianyumusic.cn/watch-relay',
    );
    final out1 = decoder.feed(encodeFrames(withUrl, nextSeq: seq)[0]);
    expect(out1.length, 1);
    expect(out1[0].type, LinkMsgType.cloudBind);
    final bind1 = out1[0].payload['cloud_bind'] as Map;
    expect(bind1['key'], 'a' * 64);
    expect(bind1['url'], 'wss://api.xianyumusic.cn/watch-relay');

    final noUrl = LinkMessage.cloudBind(key: 'b' * 64);
    final out2 = FrameDecoder().feed(encodeFrames(noUrl, nextSeq: seq)[0]);
    final bind2 = out2[0].payload['cloud_bind'] as Map;
    expect(bind2['key'], 'b' * 64);
    expect(bind2.containsKey('url'), false);
  });

  test('编码→解码单帧往返', () {
    final seq = makeSeqGenerator();
    final msg = LinkMessage.state(
      isPlaying: true,
      playMode: LinkPlayMode.shuffle,
      liked: false,
    );
    final frames = encodeFrames(msg, nextSeq: seq);
    expect(frames.length, 1);

    final decoder = FrameDecoder();
    final out = decoder.feed(frames[0]);
    expect(out.length, 1);
    expect(out[0].type, LinkMsgType.state);
    expect(out[0].payload['isPlaying'], true);
    expect(out[0].payload['playMode'], 'shuffle');
  });

  test('粘包与半包：逐字节喂入', () {
    final seq = makeSeqGenerator();
    final a = LinkMessage.hello(ver: 1, role: 'phone', name: '手机');
    final b = LinkMessage.nowPlaying(
      id: 'id-1',
      title: '歌名🎶',
      artist: '歌手',
      album: '专辑',
      cover: 'https://example.com/c.jpg',
      duration: 213.5,
    );
    final bytes = BytesBuffer()
      ..add(encodeFrames(a, nextSeq: seq)[0])
      ..add(encodeFrames(b, nextSeq: seq)[0]);

    final decoder = FrameDecoder();
    final all = <LinkMessage>[];
    final raw = bytes.asBytes();
    for (final byte in raw) {
      all.addAll(decoder.feed([byte]));
    }
    expect(all.length, 2);
    expect(all[0].payload['name'], '手机');
    expect(all[1].payload['title'], '歌名🎶');
  });

  test('脏前缀数据被跳过', () {
    final seq = makeSeqGenerator();
    final msg = LinkMessage.position(pos: 3.14, duration: 100);
    final frame = encodeFrames(msg, nextSeq: seq)[0];
    final dirty = <int>[0x00, 0x11, 0x22, ...frame];

    final decoder = FrameDecoder();
    final out = decoder.feed(dirty);
    expect(out.length, 1);
    expect(out[0].payload['pos'], 3.14);
  });

  test('CRC 损坏帧被丢弃，后续帧不受影响', () {
    final seq = makeSeqGenerator();
    final a = encodeFrames(
      LinkMessage.position(pos: 1, duration: 2),
      nextSeq: seq,
    )[0];
    final b = encodeFrames(
      LinkMessage.position(pos: 9, duration: 9),
      nextSeq: seq,
    )[0];

    final corrupted = Uint8List.fromList(a);
    corrupted[corrupted.length - 2] ^= 0xFF;
    final decoder = FrameDecoder();
    final out = decoder.feed([...corrupted, ...b]);
    expect(out.length, 1);
    expect(out[0].payload['pos'], 9);
  });

  test('未知 type 静默丢弃', () {
    final seq = makeSeqGenerator();
    final msg = LinkMessage.position(pos: 5, duration: 6);
    final frame = encodeFrames(msg, nextSeq: seq)[0];
    final unknown = Uint8List.fromList(frame);
    unknown[5] = 0x77;
    unknown[12] = 0;
    unknown[13] = 0;
    final crc = crc16CcittFalse(unknown.sublist(4));
    unknown[12] = (crc >> 8) & 0xFF;
    unknown[13] = crc & 0xFF;

    final decoder = FrameDecoder();
    final out = decoder.feed([...unknown, ...frame]);
    expect(out.length, 1);
  });

  test('超大 payload 自动分片并在解码端重组', () {
    final seq = makeSeqGenerator();
    final bigText = '弦予' * 6000;
    final msg = LinkMessage(LinkMsgType.nowPlaying, {
      'id': 'big',
      'title': bigText,
      'artist': '',
      'album': '',
      'duration': 0,
    });

    final frames = encodeFrames(msg, nextSeq: seq);
    expect(frames.length, greaterThan(1));
    for (final f in frames) {
      expect(f.length, lessThanOrEqualTo(kFrameHeaderBytes + kMaxPayloadBytes));
    }

    final decoder = FrameDecoder();
    final all = <LinkMessage>[];
    for (final f in frames) {
      all.addAll(decoder.feed(f));
    }
    expect(all.length, 1);
    expect(all[0].type, LinkMsgType.nowPlaying);
    expect(all[0].payload['title'], bigText);
  });

  test('播放模式字符串往返', () {
    for (final m in LinkPlayMode.values) {
      expect(linkPlayModeFromString(linkPlayModeToString(m)), m);
    }
    expect(linkPlayModeFromString(null), LinkPlayMode.order);
  });

  test('state 帧音量字段：带 volume 往返，缺省不出现', () {
    final seq = makeSeqGenerator();
    final withVol = LinkMessage.state(
      isPlaying: true,
      playMode: LinkPlayMode.one,
      liked: true,
      volume: 0.75,
    );
    final out = FrameDecoder().feed(encodeFrames(withVol, nextSeq: seq)[0]);
    expect(out.length, 1);
    expect(out[0].payload['volume'], 0.75);

    final noVol = LinkMessage.state(
      isPlaying: false,
      playMode: LinkPlayMode.order,
      liked: false,
    );
    final out2 = FrameDecoder().feed(encodeFrames(noVol, nextSeq: seq)[0]);
    expect(out2[0].payload.containsKey('volume'), isFalse);
  });

  test('lyric 帧编解码往返（含超长 payload 自动分片重组）', () {
    final seq = makeSeqGenerator();
    final bigPayload = jsonEncode({
      'displayLines': [
        for (var i = 0; i < 400; i++)
          {
            'time': i.toDouble(),
            'endTime': (i + 1).toDouble(),
            'text': '歌词行$i 🎵',
          },
      ],
    });

    final msg = LinkMessage.lyric(id: 'song-1', payload: bigPayload);
    final frames = encodeFrames(msg, nextSeq: seq);
    expect(frames.length, greaterThan(1));

    final decoder = FrameDecoder();
    final all = <LinkMessage>[];
    for (final f in frames) {
      all.addAll(decoder.feed(f));
    }
    expect(all.length, 1);
    expect(all[0].type, LinkMsgType.lyric);
    final lyric = all[0].payload['lyric'] as Map;
    expect(lyric['id'], 'song-1');
    expect(lyric['payload'], bigPayload);
  });
}

class BytesBuffer {
  final _d = <int>[];
  void add(List<int> b) => _d.addAll(b);
  Uint8List asBytes() => Uint8List.fromList(_d);
}
