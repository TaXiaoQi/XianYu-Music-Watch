part of 'player_provider.dart';

extension PlayerNotifierAudioChain on PlayerNotifier {
  bool _isDspEligible(QueueItem item) =>
      (item.onlineSongJson == null || item.onlineSongJson!.isEmpty) &&
      !item.path.startsWith('content://');

  Future<Duration?> _setLocalSource(String path) async {
    if (path.startsWith('content://')) {
      return _player.setUrl(path);
    }
    return _player.setFilePath(path);
  }

  Future<bool> _tryStartDspPipeline(
    String path, {
    required double startAtSecs,
  }) async {
    if (!_dspAvailable) return false;
    if (_dspSkipNextStart) {
      _dspSkipNextStart = false;
      return false;
    }
    try {
      final sfx = _ref.read(soundEffectProvider).settings;
      final vol = _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
      await startUsbExclusivePlayback(
        path: path,
        deviceId: -1,
        volume: vol,
        startTimeSecs: startAtSecs,
        isPlaying: true,
        volumeBalanceGain: 1.0,
        equalizerSettingsJson: jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: jsonEncode(sfx.toRustJson()),
        bitPerfect: false,
        dsdNativePassthrough: false,
        sharedMode: true,
        // 跳过静音：腕端暂无设置入口，启动时关闭（运行期可经 set_usb_exclusive_skip_silence 切换）
        skipSilenceEnabled: false,
        skipSilenceThresholdDb: -45.0,
        skipSilenceKeepMs: 500,
      );
      _dspActive = true;
      _startDspPolling();
      return true;
    } catch (e) {
      _dspActive = false;
      if (e.toString().contains('libaaudio')) {
        _dspAvailable = false;
      }
      return false;
    }
  }

  Future<void> _stopDsp() async {
    _stopDspPolling();
    try {
      await stopUsbExclusivePlayback();
    } catch (e) {
      AppLog.warn('player', '停止独占播放失败: $e');
    }
    _dspActive = false;
  }

  void _startDspPolling() {
    _stopDspPolling();
    _dspTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _pollDsp(),
    );
  }

  void _stopDspPolling() {
    _dspTimer?.cancel();
    _dspTimer = null;
  }

  Future<void> _pollDsp() async {
    if (!_dspActive) return;
    try {
      final pos = await getUsbExclusivePositionSecs();
      state = state.copyWith(position: pos);
      _persistPositionDebounced();
      final infoStr = await getUsbExclusiveDeviceInfo();
      final info = jsonDecode(infoStr) as Map<String, dynamic>;
      final engineDur = (info['durationSecs'] as num?)?.toDouble() ?? 0.0;
      if (engineDur > 0) {
        state = state.copyWith(duration: engineDur);
      }
      final dur = state.duration;
      if (info['active'] != true) {
        if (dur > 0 && pos >= dur - 0.3) {
          await _onDspTrackEnd();
        } else {
          await _onDspDisconnect();
        }
        return;
      }
      if (dur > 0 && pos >= dur - 0.3) {
        await _onDspTrackEnd();
      }
    } catch (e) {
      AppLog.warn('player', '独占管线轮询失败: $e');
    }
  }

  Future<void> _onDspDisconnect() async {
    await _stopDsp();
    _dspSkipNextStart = true;
    state = state.copyWith(isPlaying: false);
    await _playAt(state.queueIndex);
  }

  Future<void> _onDspTrackEnd() async {
    await _stopDsp();
    if (state.playMode == 1) {
      await _playAt(state.queueIndex);
      return;
    }
    final next = _pickNextIndex();
    if (next < 0) {
      state = state.copyWith(isPlaying: false, position: 0);
      _syncPlaybackState();
      return;
    }
    await _playAt(next);
  }

  void _syncDspEffects(SoundEffectSettings s) {
    if (!_dspActive) return;
    _sfxSyncTimer?.cancel();
    _sfxSyncTimer = Timer(const Duration(milliseconds: 50), () async {
      try {
        await setUsbExclusiveEqualizer(
          settingsJson: jsonEncode(s.toEqualizerRustJson()),
        );
        final json = s.toRustJson();
        final rate = s.playbackRate.clamp(50.0, 200.0) * state.speed;
        json['playbackRate'] = rate.clamp(50.0, 200.0);
        await setUsbExclusiveSoundEffect(settingsJson: jsonEncode(json));
      } catch (e) {
        AppLog.warn('player', '音效参数下发失败: $e');
      }
    });
  }

  Future<void> _applyEffectSpeedPitch(SoundEffectSettings s) async {
    if (_dspActive) return;
    try {
      final rate = s.playbackRate.clamp(50.0, 200.0) / 100.0;
      await _player.setSpeed(rate);
      if (s.preservesPitch) {
        await _player.setPitch(1.0);
      } else {
        await _player.setPitch(s.pitchShift.clamp(50.0, 200.0) / 100.0);
      }
    } catch (e) {
      AppLog.warn('player', '倍速/变调应用失败: $e');
    }
  }
}
