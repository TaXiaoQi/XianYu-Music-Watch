import '../../player/player_provider.dart';
import '../../link/link_provider.dart';
import '../../link/protocol.dart';

/// 封面引用：本地文件路径或网络 URL（二者可同时存在，URL 兜底）。
class CoverRef {
  final String? filePath;
  final String? url;

  const CoverRef({this.filePath, this.url});

  bool get isEmpty =>
      (filePath == null || filePath!.isEmpty) &&
      (url == null || url!.isEmpty);
}

/// 播放视图数据源抽象：统一「联动控制手机」与「本地独立播放」两种模式的
/// 播放页/歌词页取数与命令，UI 层（PlayPageBody/LyricsView）不感知来源。
///
/// 实例为无状态快照（每次 build 由页面层从 provider 构造新实例），
/// 表冠/HUD 等需要即时读数的场景通过 [volume] getter 拿最新值。
abstract class PlayerViewSource {
  /// 是否有当前曲目（false 时播放页显示空态）。
  bool get hasTrack;

  String? get title;
  String? get artist;
  CoverRef get cover;

  /// 显示进度（秒）。
  double get position;
  double get duration;

  bool get isPlaying;

  /// 喜欢状态；null = 来源不支持喜欢（播放页隐藏喜欢键）。
  bool? get liked;

  /// 是否来自日推队列（播放页据此显示「不喜欢」按钮）。
  bool get fromDaily;

  /// 播放模式：0 顺序 / 1 单曲循环 / 2 随机。
  int get playMode;

  /// 当前音量 0..1（表冠调节的即时读数入口）。
  double get volume;

  /// 当前倍速；null = 来源不支持倍速（播放页隐藏倍速键）。
  double? get speed;

  /// 是否支持音效页（独立模式 true；联动模式手表是外置控制器，
  /// 音效由手机端自控，照 speed 同款语义隐藏入口）。
  bool get supportsSoundEffects;

  void toggle();
  void next();
  void prev();
  void seekTo(double secs);
  void cycleMode();
  void like();

  /// 「不喜欢」日推歌：上报负反馈并跳下一首（仅 fromDaily 时会被调用）。
  /// 返回 false = 未登录/无曲目未执行（UI 据此提示）。
  Future<bool> dislike();
  void setVolume(double v);

  /// 循环切换倍速（仅 speed 非 null 时会被调用）。
  void cycleSpeed();

  /// 直接设置播放模式（0 顺序 / 1 单曲循环 / 2 随机；更多面板三选一）。
  void setMode(int m);

  /// 直接设置倍速（仅 speed 非 null 时会被调用）。
  void setSpeed(double s);
}

/// 联动模式数据源：命令转发手机（蓝牙优先/云兜底由 link 层路由）。
class LinkPlayerSource implements PlayerViewSource {
  LinkPlayerSource(this._link, this._ctrl);

  final LinkState _link;
  final LinkController _ctrl;

  @override
  bool get hasTrack => _link.now != null;

  @override
  String? get title => _link.now?.title;

  @override
  String? get artist => _link.now?.artist;

  @override
  CoverRef get cover =>
      CoverRef(filePath: _link.now?.coverIsFile == true ? _link.now!.cover : null,
          url: _link.now?.coverIsFile == true ? null : _link.now?.cover);

  @override
  double get position => _link.position;

  @override
  double get duration => _link.now?.duration ?? 0;

  @override
  bool get isPlaying => _link.isPlaying;

  @override
  bool? get liked => _link.liked;

  @override
  bool get fromDaily => _link.now?.daily ?? false;

  @override
  int get playMode => switch (_link.playMode) {
        LinkPlayMode.shuffle => 2,
        LinkPlayMode.one => 1,
        LinkPlayMode.order => 0,
      };

  @override
  double get volume => _link.volume ?? 0.5;

  @override
  double? get speed => null; // 倍速由手机端自控，表上不改

  @override
  bool get supportsSoundEffects => false; // 音效由手机端自控，表上隐藏入口

  @override
  void toggle() => _ctrl.toggle();

  @override
  void next() => _ctrl.next();

  @override
  void prev() => _ctrl.prev();

  @override
  void seekTo(double secs) => _ctrl.seek(secs);

  @override
  void cycleMode() => _ctrl.cycleMode();

  @override
  void like() => _ctrl.like();

  @override
  Future<bool> dislike() async {
    _ctrl.dislike(); // 发 cmd 即返回；上报与跳歌由手机端完成
    return true; // 手机端负责上报（登录语义由手机侧处理），始终视为已执行
  }

  @override
  void cycleSpeed() {} // 联动模式不支持倍速

  @override
  void setMode(int m) {
    // 联动协议仅支持循环切换：按当前模式差值一次性补发对应步数
    // （playMode 回包异步到达，不能边发边读，否则会多发）。
    final steps = (m - playMode) % 3;
    for (var i = 0; i < steps; i++) {
      _ctrl.cycleMode();
    }
  }

  @override
  void setSpeed(double s) {} // 联动模式不支持倍速

  @override
  void setVolume(double v) => _ctrl.setVolume(v);
}

/// 本地独立播放数据源。
class LocalPlayerSource implements PlayerViewSource {
  /// [_liked] 为 null 表示无收藏概念（无当前歌时），非 null 直接驱动红心键显隐。
  LocalPlayerSource(this._st, this._ctrl, this._volume, this._liked);

  final PlaybackState _st;
  final PlayerNotifier _ctrl;
  final double _volume;
  final bool? _liked;

  @override
  double get volume => _volume;

  @override
  bool get hasTrack => _st.current != null;

  @override
  String? get title => _st.current?.title;

  @override
  String? get artist => _st.current?.artist;

  @override
  CoverRef get cover =>
      CoverRef(filePath: _st.current?.coverPath, url: _st.current?.coverUrl);

  @override
  double get position => _st.position;

  @override
  double get duration => _st.duration;

  @override
  bool get isPlaying => _st.isPlaying;

  @override
  bool? get liked => _liked;

  @override
  bool get fromDaily => _st.current?.fromDailyRecommend ?? false;

  @override
  int get playMode => _st.playMode;

  @override
  double? get speed => _st.speed;

  @override
  bool get supportsSoundEffects => true;

  @override
  void toggle() => _ctrl.toggle();

  @override
  void next() => _ctrl.next();

  @override
  void prev() => _ctrl.previous();

  @override
  void seekTo(double secs) => _ctrl.seek(secs);

  @override
  void cycleMode() => _ctrl.cyclePlayMode();

  @override
  void like() => _ctrl.toggleFavorite();

  @override
  Future<bool> dislike() => _ctrl.dislikeDaily();

  @override
  void cycleSpeed() => _ctrl.cycleSpeed();

  @override
  void setMode(int m) => _ctrl.setPlayMode(m);

  @override
  void setSpeed(double s) => _ctrl.setSpeed(s);

  @override
  void setVolume(double v) => _ctrl.setVolume(v);
}
