import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../link/link_provider.dart';
import '../../lyrics/lyric_model.dart';
import '../../lyrics/lyrics_repository.dart';
import '../../core/watch_fit.dart';
import '../player/play_page_body.dart';
import '../player/cover_backdrop.dart';
import '../player/lyrics_view.dart';
import '../player/page_dots.dart';
import '../player/player_source.dart';

/// 联接控制页（网易云手表版形态）：左右横移双页 + 底部圆点指示。
///
/// 播放页 = 通用 PlayPageBody（联动数据源：表冠调手机音量、环形 seek、
/// 喜欢/播放模式，云中继显示小云标）；歌词页 = 手机推送的当前歌歌词
/// （type 0x13），当前行高亮自动居中，点行 seek。
///
/// [frontBuilder] 传入时，在最左新增一页「功能页」（联动模式主页用，
/// 收纳「启动独立模式」等唯一功能），页面数扩为三页，初始落在播放页
/// （1），左滑回到功能页。其余行为（封面背景、表冠门禁、圆点指示）
/// 按页数自适应。
///
/// [isRootHome] 传 true（联动模式根路由主页）：装 PopScope 承接系统返回。
/// 鸿蒙旧表 setGestureBackEnabled 不可用（API<13）时，侧滑返回手势仍被
/// 系统整条抢走并提交为 back 事件（Index.onBackPress→popRoute），触摸横滑
/// 翻页失效——这里把该事件转成语义化导航：非最左页先翻回上一页（补回被
/// 抢走的「往右滑回功能区」），仅最左页才退后台驻留；推入的二级路由
/// （独立模式控制页）不传，返回照常弹栈。
class WatchControllerPage extends ConsumerStatefulWidget {
  const WatchControllerPage({
    super.key,
    this.frontBuilder,
    this.isRootHome = false,
  });

  /// 最左功能页构造器：[isCurrent] 报告该页是否为 PageView 当前页，
  /// 供功能页的表冠门禁使用（非当前页时不响应表冠滚动）。
  final Widget Function({required bool Function() isCurrent})? frontBuilder;

  /// 根路由主页语义（联动主页）：系统返回 = 先翻页、最左页才退后台。
  final bool isRootHome;

  @override
  ConsumerState<WatchControllerPage> createState() =>
      _WatchControllerPageState();
}

class _WatchControllerPageState extends ConsumerState<WatchControllerPage> {
  /// 有前置功能页时总页数为 3（功能/播放/歌词），否则为 2（播放/歌词）。
  bool get _hasFront => widget.frontBuilder != null;
  int get _playIndex => _hasFront ? 1 : 0;
  int get _lyricsIndex => _hasFront ? 2 : 1;

  late final PageController _pageCtrl;
  late int _page;

  /// 最近一次翻页时刻（触摸/程序翻页都会触发 onPageChanged）：用于识别
  /// 「手势与触摸并存」机型上触摸刚翻完页、系统返回又随即提交的双重响应。
  DateTime _lastPageChange = DateTime.fromMillisecondsSinceEpoch(0);

  /// 联动歌词解析缓存（lyricSongId → 行列表）。
  final Map<String, List<LyricLine>> _parsedLyrics = {};
  bool _parsing = false;

  @override
  void initState() {
    super.initState();
    // 有前置功能页时初始落在播放页（1），左滑回到功能页（0）。
    _page = _hasFront ? 1 : 0;
    _pageCtrl = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 取当前歌歌词行；未命中缓存时后台解析（解析完 setState 生效）。
  List<LyricLine> _lyricsOf(LinkState link) {
    final id = link.lyricSongId;
    final payload = link.lyricPayload;
    // 歌词与当前歌不一致（未到/已过期）→ 视为无歌词。
    if (id == null || payload == null || id != (link.now?.id ?? '')) {
      return const [];
    }
    final cached = _parsedLyrics[id];
    if (cached != null) return cached;
    if (!_parsing) {
      _parsing = true;
      Future(() => parsePayload(payload)).then((lines) {
        _parsing = false;
        if (!mounted) return;
        _parsedLyrics[id] = lines;
        if (_parsedLyrics.length > 8) {
          _parsedLyrics.remove(_parsedLyrics.keys.first);
        }
        setState(() {});
      }).catchError((_) {
        _parsing = false;
      });
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(linkControllerProvider);
    final lyrics = _lyricsOf(link);
    final now = link.now;

    final body = Scaffold(
      body: Stack(
        children: [
          // 全屏封面模糊背景（网易云手表版）：双页共享一层，横移时背景不动。
          Positioned.fill(
            child: CoverBackdrop(
              cover: CoverRef(
                filePath: now?.coverIsFile == true ? now!.cover : null,
                url: now?.coverIsFile == true ? null : now?.cover,
              ),
            ),
          ),
          PageView(
            controller: _pageCtrl,
            onPageChanged: (i) {
              _lastPageChange = DateTime.now();
              setState(() => _page = i);
            },
            children: [
              if (_hasFront)
                widget.frontBuilder!(isCurrent: () => _page == 0),
              PlayPageBody(
                sourceBuilder: () => LinkPlayerSource(
                  link,
                  ref.read(linkControllerProvider.notifier),
                ),
                showCloudBadge: link.viaCloud,
                emptyText: '手机未在播放',
                // 表冠门禁：仅播放页是 PageView 当前页时才调音量。
                rotaryGuard: () => _page == _playIndex,
              ),
              LyricsView(
                lines: lyrics,
                position: link.position,
                isPlaying: link.isPlaying,
                onSeek: (secs) =>
                    ref.read(linkControllerProvider.notifier).seek(secs),
                // 表冠门禁：仅歌词页是 PageView 当前页时才滚动歌词。
                rotaryGuard: () => _page == _lyricsIndex,
              ),
            ],
          ),
          // 底部页指示圆点（贴下缘居中，间距随屏径等比）
          Positioned(
            left: 0,
            right: 0,
            bottom: 10 * context.watchScale(),
            child: Center(
              child: PageDots(
                count: (_hasFront ? 3 : 2),
                current: _page,
              ),
            ),
          ),
        ],
      ),
    );

    // 非根路由（独立模式推入的控制页）：不装 PopScope，返回照常弹栈。
    if (!widget.isRootHome) return body;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleRootBack();
      },
      child: body,
    );
  }

  /// 根路由系统返回（鸿蒙侧滑手势经 Index.onBackPress→popRoute 到此；
  /// 安卓版 _EdgeBackStrip 也经 maybePop 走同一路径）：非最左页先翻回
  /// 上一页，仅最左页才退后台驻留——等价网易云手表「右滑回上一页，
  /// 首页再右滑退表盘」。
  void _handleRootBack() {
    // 触摸横滑正在进行/刚完成翻页（手势与触摸并存机型）：本次返回已被
    // 触摸横滑消化，忽略，防止「翻页后又立刻退后台」的双重响应。
    final scrolling = _pageCtrl.hasClients &&
        _pageCtrl.position.isScrollingNotifier.value;
    final justPaged =
        DateTime.now().difference(_lastPageChange) <
            const Duration(milliseconds: 600);
    if (scrolling || justPaged) return;
    if (_page > 0) {
      _pageCtrl.animateToPage(
        _page - 1,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    // 最左页再返回：退后台驻留（应用保持存活、重开秒回、联动会话不断），
    // 绝不退出——失败就静默留在前台，与安卓版根路由行为一致。
    const MethodChannel('xianyu/system_nav')
        .invokeMethod('moveTaskToBack')
        .catchError((_) {});
  }
}
