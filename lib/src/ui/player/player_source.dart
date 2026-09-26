import '../../player/player_provider.dart';
import '../../player/online_quality_probe.dart';
import '../../link/link_provider.dart';
import '../../link/protocol.dart';

class CoverRef {
  final String? filePath;
  final String? url;

  const CoverRef({this.filePath, this.url});

  bool get isEmpty =>
      (filePath == null || filePath!.isEmpty) && (url == null || url!.isEmpty);
}

abstract class PlayerViewSource {
  bool get hasTrack;

  String? get title;
  String? get artist;
  CoverRef get cover;

  double get position;
  double get duration;

  bool get isPlaying;

  bool? get liked;

  bool get fromDaily;

  int get playMode;

  double get volume;

  double? get speed;

  bool get supportsSoundEffects;

  /// 当前生效的在线播放音质；null = 当前曲目不支持切音质（本地/联动源）
  String? get onlineQuality => null;

  /// 实际生效的在线音质（探测解析后的真实档位）
  String? get currentQuality => null;

  /// 音质菜单探测是否进行中
  bool get qualityMenuProbing => false;

  /// 探测音质菜单可选档位（触发逐档解析）
  Future<List<String>> qualityOptions() => Future.value(const []);

  /// 查询各档位体积（URL HEAD / 元数据兜底）
  Future<Map<String, QualitySizeInfo>> qualitySizes() =>
      Future.value(const {});

  /// MV 加载进度提示（联动源才有）；null = 无 MV 活动态。
  String? get mvPhase => null;

  void toggle();
  void next();
  void prev();
  void seekTo(double secs);
  void like();

  Future<bool> dislike();
  void setVolume(double v);

  void setMode(int m);

  void setSpeed(double s);

  /// 播放中切换在线音质（同曲续播重播）；返回是否成功。默认不支持。
  Future<bool> switchQuality(String quality) => Future.value(false);
}

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
  CoverRef get cover => CoverRef(
    filePath: _link.now?.coverIsFile == true ? _link.now!.cover : null,
    url: _link.now?.coverIsFile == true ? null : _link.now?.cover,
  );

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
  double? get speed => _ctrl.linkedSpeed;

  @override
  bool get supportsSoundEffects => true;

  @override
  String? get onlineQuality => null;

  @override
  String? get currentQuality => null;

  @override
  bool get qualityMenuProbing => false;

  @override
  Future<List<String>> qualityOptions() => Future.value(const []);

  @override
  Future<Map<String, QualitySizeInfo>> qualitySizes() =>
      Future.value(const {});

  @override
  Future<bool> switchQuality(String quality) => Future.value(false);

  @override
  String? get mvPhase => _link.mvPhase;

  @override
  void toggle() => _ctrl.toggle();

  @override
  void next() => _ctrl.next();

  @override
  void prev() => _ctrl.prev();

  @override
  void seekTo(double secs) => _ctrl.seek(secs);

  @override
  void like() => _ctrl.like();

  @override
  Future<bool> dislike() async {
    _ctrl.dislike();
    return true;
  }

  @override
  void setMode(int m) {
    final steps = (m - playMode) % 3;
    for (var i = 0; i < steps; i++) {
      _ctrl.cycleMode();
    }
  }

  @override
  void setSpeed(double s) => _ctrl.setLinkedSpeed(s);

  @override
  void setVolume(double v) => _ctrl.setVolume(v);
}

class LocalPlayerSource implements PlayerViewSource {
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
  String? get onlineQuality =>
      _ctrl.effectiveOnlineQuality(_st.current?.onlineSongJson);

  @override
  String? get currentQuality => _st.currentQuality;

  @override
  bool get qualityMenuProbing => _st.qualityMenuProbing;

  @override
  Future<List<String>> qualityOptions() => _ctrl.qualityOptions();

  @override
  Future<Map<String, QualitySizeInfo>> qualitySizes() =>
      _ctrl.qualitySizes();

  @override
  Future<bool> switchQuality(String quality) => _ctrl.switchQuality(quality);

  @override
  String? get mvPhase => null;

  @override
  void toggle() => _ctrl.toggle();

  @override
  void next() => _ctrl.next();

  @override
  void prev() => _ctrl.previous();

  @override
  void seekTo(double secs) => _ctrl.seek(secs);

  @override
  void like() => _ctrl.toggleFavorite();

  @override
  Future<bool> dislike() => _ctrl.dislikeDaily();

  @override
  void setMode(int m) => _ctrl.setPlayMode(m);

  @override
  void setSpeed(double s) => _ctrl.setSpeed(s);

  @override
  void setVolume(double v) => _ctrl.setVolume(v);
}
