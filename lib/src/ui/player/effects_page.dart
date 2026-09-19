import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../core/haptics.dart';
import '../../core/watch_fit.dart';
import '../../effects/sound_effect_provider.dart';
import '../common/full_dialog.dart';
import '../common/rotary_input.dart';

void openSoundEffectsPage(BuildContext context) {
  showFullDialog(
    context: context,
    builder: (_) => const _EffectsHomePage(),
  );
}

const Color _accent = Color(0xFFFF4D6E);

// ———————————————————————————— 主页（五分组菜单） ————————————————————————————

class _EffectsHomePage extends ConsumerWidget {
  const _EffectsHomePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final sfx = ref.watch(soundEffectProvider).settings;
    final dsp = kDspPipelineSupported;
    return _FxScaffold(
      title: '音效',
      actions: [
        FullDialogButton(
          label: '重置全部音效',
          onPressed: () async {
            final ok = await showFullConfirm(
              context,
              title: '重置全部音效？',
              okLabel: '重置',
            );
            if (ok == true) {
              Haptics.tick();
              ref.read(soundEffectProvider.notifier).resetAll();
            }
          },
        ),
      ],
      children: [
        if (!dsp) ...[
          _hint(context, '当前系统不支持 DSP 音效，仅变速变调可用'),
          SizedBox(height: 10 * s),
        ],
        _FxRow(
          icon: Icons.equalizer_rounded,
          label: '均衡器',
          value: _eqValue(sfx),
          enabled: dsp,
          onTap: () => showFullDialog(
              context: context, builder: (_) => const _EqPage()),
        ),
        _FxRow(
          icon: Icons.speed_rounded,
          label: '变速变调',
          value: _speedPitchValue(sfx),
          enabled: true,
          onTap: () => showFullDialog(
              context: context, builder: (_) => const _SpeedPitchPage()),
        ),
        _FxRow(
          icon: Icons.graphic_eq_rounded,
          label: '混响',
          value: _reverbValue(sfx),
          enabled: dsp,
          onTap: () => showFullDialog(
              context: context, builder: (_) => const _ReverbPage()),
        ),
        _FxRow(
          icon: Icons.surround_sound_rounded,
          label: '空间音效',
          value: _spatialValue(sfx),
          enabled: dsp,
          onTap: () => showFullDialog(
              context: context, builder: (_) => const _SpatialPage()),
        ),
        _FxRow(
          icon: Icons.tune_rounded,
          label: '高级音效',
          value: _advancedValue(sfx),
          enabled: dsp,
          onTap: () => showFullDialog(
              context: context, builder: (_) => const _AdvancedPage()),
        ),
      ],
    );
  }

  String _eqValue(SoundEffectSettings s) {
    for (final p in eqPresets) {
      if (listEquals(p.gains, s.eqGains)) return p.name;
    }
    if (s.eqGains.any((g) => g != 0)) return '自定义';
    return '关闭';
  }

  String _speedPitchValue(SoundEffectSettings s) =>
      (s.playbackRate - 100).abs() < 0.5 && (s.pitchShift - 100).abs() < 0.5
          ? '默认'
          : '${s.playbackRate.round()}% · ${s.pitchShift.round()}%';

  String _reverbValue(SoundEffectSettings s) {
    if (s.reverbKind == 'none') return '关闭';
    for (final p in [...reverbPresets, ...algoReverbPresets]) {
      if (p.label == s.reverbPreset) return p.label;
    }
    return '开启';
  }

  String _spatialValue(SoundEffectSettings s) => switch (s.spatialMode) {
        'surround3d' => '3D 环绕',
        'd8' => '8D',
        'd36' => '36D',
        'virtual' => '虚拟环绕 ${s.virtualSurroundMode}',
        _ => '关闭',
      };

  String _advancedValue(SoundEffectSettings s) {
    final n = _kAdvancedFx.where((f) => f.enabled(s)).length;
    return n == 0 ? '关闭' : '$n 项开启';
  }
}

// ———————————————————————————— 均衡器 ————————————————————————————

class _EqPage extends ConsumerWidget {
  const _EqPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final sfx = ref.watch(soundEffectProvider).settings;
    final mgr = ref.read(soundEffectProvider.notifier);
    return _FxScaffold(
      title: '均衡器',
      children: _dspLocked(
        context,
        [
          Wrap(
            spacing: 7 * s,
            runSpacing: 7 * s,
            alignment: WrapAlignment.center,
            children: [
              for (final p in eqPresets)
                _FxChip(
                  label: p.name,
                  active: listEquals(p.gains, sfx.eqGains),
                  onTap: () {
                    Haptics.tick();
                    mgr.applyEqPreset(p.name);
                  },
                ),
            ],
          ),
          SizedBox(height: 12 * s),
          for (var i = 0; i < 10; i++)
            _FxSlider(
              label: '${eqFreqLabels[i]}Hz',
              value: sfx.eqGains[i],
              min: -12,
              max: 12,
              divisions: 24,
              fmt: (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
              onChanged: (v) => mgr.setEqGain(i, v),
            ),
        ],
      ),
    );
  }
}

// ———————————————————————————— 变速变调 ————————————————————————————

class _SpeedPitchPage extends ConsumerWidget {
  const _SpeedPitchPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final sfx = ref.watch(soundEffectProvider).settings;
    final mgr = ref.read(soundEffectProvider.notifier);
    return _FxScaffold(
      title: '变速变调',
      children: [
        _FxSlider(
          label: '变调',
          value: sfx.pitchShift,
          min: 50,
          max: 200,
          divisions: 30,
          fmt: (v) => '${v.round()}%',
          onChanged: (v) => mgr.set(sfx.copyWith(pitchShift: v)),
        ),
        _FxSlider(
          label: '变速',
          value: sfx.playbackRate,
          min: 50,
          max: 200,
          divisions: 30,
          fmt: (v) => '${v.round()}%',
          onChanged: (v) => mgr.set(sfx.copyWith(playbackRate: v)),
        ),
        _FxSwitchRow(
          label: '变速时保持音调',
          value: sfx.preservesPitch,
          onChanged: (v) {
            Haptics.tick();
            mgr.set(sfx.copyWith(preservesPitch: v));
          },
        ),
        SizedBox(height: 4 * s),
        _hint(
          context,
          kDspPipelineSupported ? '效果经 DSP 引擎实时处理' : '经播放器原生变速/变调处理',
        ),
      ],
    );
  }
}

// ———————————————————————————— 混响 ————————————————————————————

class _ReverbPage extends ConsumerWidget {
  const _ReverbPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final sfx = ref.watch(soundEffectProvider).settings;
    final mgr = ref.read(soundEffectProvider.notifier);
    return _FxScaffold(
      title: '混响',
      children: _dspLocked(
        context,
        [
          Wrap(
            spacing: 7 * s,
            runSpacing: 7 * s,
            alignment: WrapAlignment.center,
            children: [
              _FxChip(
                label: '关闭',
                active: sfx.reverbKind == 'none',
                onTap: () {
                  Haptics.tick();
                  mgr.set(sfx.copyWith(
                    reverbKind: 'none',
                    reverbPreset: '',
                    reverbDry: 0,
                    reverbWet: 0,
                  ));
                },
              ),
              for (final p in reverbPresets)
                _FxChip(
                  label: p.label,
                  active: sfx.reverbKind == 'convolution' &&
                      sfx.reverbPreset == p.label,
                  onTap: () {
                    Haptics.tick();
                    mgr.set(sfx.copyWith(
                      reverbKind: 'convolution',
                      reverbPreset: p.label,
                      reverbDry: p.dry / 100,
                      reverbWet: p.wet / 100,
                    ));
                  },
                ),
              for (final p in algoReverbPresets)
                _FxChip(
                  label: p.label,
                  active: sfx.reverbKind == 'algorithmic' &&
                      sfx.reverbPreset == p.label,
                  onTap: () {
                    Haptics.tick();
                    mgr.set(sfx.copyWith(
                      reverbKind: 'algorithmic',
                      reverbPreset: p.label,
                      reverbDry: p.dry / 100,
                      reverbWet: p.wet / 100,
                    ));
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ———————————————————————————— 空间音效 ————————————————————————————

class _SpatialPage extends ConsumerWidget {
  const _SpatialPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final sfx = ref.watch(soundEffectProvider).settings;
    final mgr = ref.read(soundEffectProvider.notifier);
    return _FxScaffold(
      title: '空间音效',
      children: _dspLocked(
        context,
        [
          Wrap(
            spacing: 7 * s,
            runSpacing: 7 * s,
            alignment: WrapAlignment.center,
            children: [
              for (final (mode, label) in const [
                ('none', '关闭'),
                ('surround3d', '3D 环绕'),
                ('d8', '8D'),
                ('d36', '36D'),
                ('virtual', '虚拟环绕'),
              ])
                _FxChip(
                  label: label,
                  active: sfx.spatialMode == mode,
                  onTap: () {
                    Haptics.tick();
                    mgr.set(sfx.copyWith(spatialMode: mode));
                  },
                ),
            ],
          ),
          if (sfx.spatialMode == 'virtual') ...[
            SizedBox(height: 12 * s),
            _FxChip(
              label: '5.1 声道',
              active: sfx.virtualSurroundMode == '5.1',
              onTap: () {
                Haptics.tick();
                mgr.set(sfx.copyWith(virtualSurroundMode: '5.1'));
              },
            ),
            SizedBox(height: 7 * s),
            _FxChip(
              label: '7.1 声道',
              active: sfx.virtualSurroundMode == '7.1',
              onTap: () {
                Haptics.tick();
                mgr.set(sfx.copyWith(virtualSurroundMode: '7.1'));
              },
            ),
          ],
        ],
      ),
    );
  }
}

// ———————————————————————————— 高级音效（19 项，数据驱动） ————————————————————————————

class _FxParam {
  final String label;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) fmt;
  final double Function(SoundEffectSettings) get;
  final SoundEffectSettings Function(SoundEffectSettings, double) set;
  const _FxParam(
    this.label, {
    required this.min,
    required this.max,
    required this.divisions,
    required this.fmt,
    required this.get,
    required this.set,
  });
}

class _FxChoice {
  final String label;
  final List<(String, String)> options;
  final String Function(SoundEffectSettings) get;
  final SoundEffectSettings Function(SoundEffectSettings, String) set;
  const _FxChoice(
    this.label, {
    required this.options,
    required this.get,
    required this.set,
  });
}

class _FxFlag {
  final String label;
  final bool Function(SoundEffectSettings) get;
  final SoundEffectSettings Function(SoundEffectSettings, bool) set;
  const _FxFlag(
    this.label, {
    required this.get,
    required this.set,
  });
}

class _FxSpec {
  final String label;
  final bool Function(SoundEffectSettings) enabled;
  final SoundEffectSettings Function(SoundEffectSettings) toggle;
  final List<_FxFlag> flags;
  final List<_FxChoice> choices;
  final List<_FxParam> params;
  const _FxSpec(
    this.label, {
    required this.enabled,
    required this.toggle,
    this.flags = const [],
    this.choices = const [],
    this.params = const [],
  });

  bool get hasDetail => flags.isNotEmpty || choices.isNotEmpty || params.isNotEmpty;
}

const List<_FxSpec> _kAdvancedFx = [
  _FxSpec('消人声',
      enabled: _enVocalRemoval, toggle: _tgVocalRemoval),
  _FxSpec('颤音',
      enabled: _enVibrato, toggle: _tgVibrato, params: [
        _FxParam('速率', min: 0.5, max: 10, divisions: 38,
            fmt: _fmtHz2, get: _getVibratoRate, set: _setVibratoRate),
        _FxParam('深度', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getVibratoDepth, set: _setVibratoDepth),
      ]),
  _FxSpec('抖音',
      enabled: _enTremolo, toggle: _tgTremolo, params: [
        _FxParam('速率', min: 0.5, max: 10, divisions: 38,
            fmt: _fmtHz2, get: _getTremoloRate, set: _setTremoloRate),
        _FxParam('深度', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getTremoloDepth, set: _setTremoloDepth),
      ]),
  _FxSpec('Bass 增强',
      enabled: _enBassBoost, toggle: _tgBassBoost,
      flags: [_FxFlag('动态回弹', get: _getBassDynamic, set: _setBassDynamic)],
      params: [
        _FxParam('增益', min: 0, max: 15, divisions: 30,
            fmt: _fmtDb1, get: _getBassGain, set: _setBassGain),
      ]),
  _FxSpec('高音增强',
      enabled: _enTreble, toggle: _tgTreble, params: [
        _FxParam('增益', min: 0, max: 15, divisions: 30,
            fmt: _fmtDb1, get: _getTrebleGain, set: _setTrebleGain),
      ]),
  _FxSpec('失真',
      enabled: _enDistortion, toggle: _tgDistortion,
      choices: [_FxChoice('类型',
          options: [('soft', '软失真'), ('hard', '硬失真')],
          get: _getDistortionType, set: _setDistortionType)],
      params: [
        _FxParam('程度', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getDistortionAmount, set: _setDistortionAmount),
      ]),
  _FxSpec('延迟回声',
      enabled: _enDelay, toggle: _tgDelay,
      choices: [_FxChoice('类型',
          options: [('single', '单声道'), ('pingpong', '双声道')],
          get: _getDelayType, set: _setDelayType)],
      params: [
        _FxParam('时间', min: 10, max: 1000, divisions: 99,
            fmt: _fmtMs, get: _getDelayTime, set: _setDelayTime),
        _FxParam('反馈', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getDelayFeedback, set: _setDelayFeedback),
        _FxParam('混合', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getDelayMix, set: _setDelayMix),
      ]),
  _FxSpec('镶边',
      enabled: _enFlanger, toggle: _tgFlanger, params: [
        _FxParam('速率', min: 0.1, max: 5, divisions: 49,
            fmt: _fmtHz2, get: _getFlangerRate, set: _setFlangerRate),
        _FxParam('深度', min: 0, max: 20, divisions: 20,
            fmt: _fmt1, get: _getFlangerDepth, set: _setFlangerDepth),
        _FxParam('反馈', min: 0, max: 90, divisions: 90,
            fmt: _fmtPct, get: _getFlangerFeedback, set: _setFlangerFeedback),
        _FxParam('混合', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getFlangerMix, set: _setFlangerMix),
      ]),
  _FxSpec('相位',
      enabled: _enPhaser, toggle: _tgPhaser, params: [
        _FxParam('速率', min: 0.1, max: 5, divisions: 49,
            fmt: _fmtHz2, get: _getPhaserRate, set: _setPhaserRate),
        _FxParam('深度', min: 0, max: 20, divisions: 20,
            fmt: _fmt1, get: _getPhaserDepth, set: _setPhaserDepth),
        _FxParam('反馈', min: 0, max: 90, divisions: 90,
            fmt: _fmtPct, get: _getPhaserFeedback, set: _setPhaserFeedback),
        _FxParam('混合', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getPhaserMix, set: _setPhaserMix),
      ]),
  _FxSpec('压缩器',
      enabled: _enCompressor, toggle: _tgCompressor, params: [
        _FxParam('阈值', min: -60, max: 0, divisions: 60,
            fmt: _fmtDb0, get: _getCompThreshold, set: _setCompThreshold),
        _FxParam('比率', min: 1, max: 20, divisions: 19,
            fmt: _fmtRatio, get: _getCompRatio, set: _setCompRatio),
        _FxParam('起音', min: 0, max: 100, divisions: 100,
            fmt: _fmtMs, get: _getCompAttack, set: _setCompAttack),
        _FxParam('释放', min: 10, max: 1000, divisions: 99,
            fmt: _fmtMs, get: _getCompRelease, set: _setCompRelease),
      ]),
  _FxSpec('噪声门',
      enabled: _enNoiseGate, toggle: _tgNoiseGate, params: [
        _FxParam('阈值', min: -90, max: 0, divisions: 90,
            fmt: _fmtDb0, get: _getNoiseGateThreshold,
            set: _setNoiseGateThreshold),
      ]),
  _FxSpec('限制器',
      enabled: _enLimiter, toggle: _tgLimiter, params: [
        _FxParam('阈值', min: -12, max: 0, divisions: 12,
            fmt: _fmtDb0, get: _getLimiterThreshold, set: _setLimiterThreshold),
      ]),
  _FxSpec('谐波激励器',
      enabled: _enExciter, toggle: _tgExciter, params: [
        _FxParam('强度', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getExciterAmount, set: _setExciterAmount),
        _FxParam('频率', min: 1000, max: 8000, divisions: 70,
            fmt: _fmtHz0, get: _getExciterFreq, set: _setExciterFreq),
      ]),
  _FxSpec('次谐波低音',
      enabled: _enSubBass, toggle: _tgSubBass, params: [
        _FxParam('强度', min: 0, max: 100, divisions: 100,
            fmt: _fmtPct, get: _getSubBassAmount, set: _setSubBassAmount),
        _FxParam('频率', min: 40, max: 200, divisions: 32,
            fmt: _fmtHz0, get: _getSubBassFreq, set: _setSubBassFreq),
      ]),
  _FxSpec('Lo-Fi',
      enabled: _enLoFi, toggle: _tgLoFi, params: [
        _FxParam('采样率', min: 2000, max: 22050, divisions: 25,
            fmt: _fmtHz0, get: _getLoFiRate, set: _setLoFiRate),
        _FxParam('位深', min: 4, max: 16, divisions: 12,
            fmt: _fmtBit, get: _getLoFiBit, set: _setLoFiBit),
      ]),
  _FxSpec('立体声拓宽',
      enabled: _enStereoWiden, toggle: _tgStereoWiden, params: [
        _FxParam('宽度', min: 0, max: 3, divisions: 20,
            fmt: _fmtX2, get: _getStereoWiden, set: _setStereoWiden),
      ]),
  _FxSpec('单声道合并',
      enabled: _enMonoMerge, toggle: _tgMonoMerge),
  _FxSpec('左右交换',
      enabled: _enChannelSwap, toggle: _tgChannelSwap),
  _FxSpec('V4A 增强',
      enabled: _enV4a, toggle: _tgV4a),
];

bool _enVocalRemoval(SoundEffectSettings s) => s.vocalRemoval;
SoundEffectSettings _tgVocalRemoval(SoundEffectSettings s) =>
    s.copyWith(vocalRemoval: !s.vocalRemoval);
bool _enVibrato(SoundEffectSettings s) => s.vibratoEnabled;
SoundEffectSettings _tgVibrato(SoundEffectSettings s) =>
    s.copyWith(vibratoEnabled: !s.vibratoEnabled);
double _getVibratoRate(SoundEffectSettings s) => s.vibratoRate;
SoundEffectSettings _setVibratoRate(SoundEffectSettings s, double v) =>
    s.copyWith(vibratoRate: v);
double _getVibratoDepth(SoundEffectSettings s) => s.vibratoDepth;
SoundEffectSettings _setVibratoDepth(SoundEffectSettings s, double v) =>
    s.copyWith(vibratoDepth: v);
bool _enTremolo(SoundEffectSettings s) => s.tremoloEnabled;
SoundEffectSettings _tgTremolo(SoundEffectSettings s) =>
    s.copyWith(tremoloEnabled: !s.tremoloEnabled);
double _getTremoloRate(SoundEffectSettings s) => s.tremoloRate;
SoundEffectSettings _setTremoloRate(SoundEffectSettings s, double v) =>
    s.copyWith(tremoloRate: v);
double _getTremoloDepth(SoundEffectSettings s) => s.tremoloDepth;
SoundEffectSettings _setTremoloDepth(SoundEffectSettings s, double v) =>
    s.copyWith(tremoloDepth: v);
bool _enBassBoost(SoundEffectSettings s) => s.bassBoostEnabled;
SoundEffectSettings _tgBassBoost(SoundEffectSettings s) =>
    s.copyWith(bassBoostEnabled: !s.bassBoostEnabled);
bool _getBassDynamic(SoundEffectSettings s) => s.bassBoostDynamic;
SoundEffectSettings _setBassDynamic(SoundEffectSettings s, bool v) =>
    s.copyWith(bassBoostDynamic: v);
double _getBassGain(SoundEffectSettings s) => s.bassBoostGain;
SoundEffectSettings _setBassGain(SoundEffectSettings s, double v) =>
    s.copyWith(bassBoostGain: v);
bool _enTreble(SoundEffectSettings s) => s.trebleEnabled;
SoundEffectSettings _tgTreble(SoundEffectSettings s) =>
    s.copyWith(trebleEnabled: !s.trebleEnabled);
double _getTrebleGain(SoundEffectSettings s) => s.trebleGain;
SoundEffectSettings _setTrebleGain(SoundEffectSettings s, double v) =>
    s.copyWith(trebleGain: v);
bool _enDistortion(SoundEffectSettings s) => s.distortionEnabled;
SoundEffectSettings _tgDistortion(SoundEffectSettings s) =>
    s.copyWith(distortionEnabled: !s.distortionEnabled);
String _getDistortionType(SoundEffectSettings s) => s.distortionType;
SoundEffectSettings _setDistortionType(SoundEffectSettings s, String v) =>
    s.copyWith(distortionType: v);
double _getDistortionAmount(SoundEffectSettings s) => s.distortionAmount;
SoundEffectSettings _setDistortionAmount(SoundEffectSettings s, double v) =>
    s.copyWith(distortionAmount: v);
bool _enDelay(SoundEffectSettings s) => s.delayEnabled;
SoundEffectSettings _tgDelay(SoundEffectSettings s) =>
    s.copyWith(delayEnabled: !s.delayEnabled);
String _getDelayType(SoundEffectSettings s) => s.delayType;
SoundEffectSettings _setDelayType(SoundEffectSettings s, String v) =>
    s.copyWith(delayType: v);
double _getDelayTime(SoundEffectSettings s) => s.delayTime;
SoundEffectSettings _setDelayTime(SoundEffectSettings s, double v) =>
    s.copyWith(delayTime: v);
double _getDelayFeedback(SoundEffectSettings s) => s.delayFeedback;
SoundEffectSettings _setDelayFeedback(SoundEffectSettings s, double v) =>
    s.copyWith(delayFeedback: v);
double _getDelayMix(SoundEffectSettings s) => s.delayMix;
SoundEffectSettings _setDelayMix(SoundEffectSettings s, double v) =>
    s.copyWith(delayMix: v);
bool _enFlanger(SoundEffectSettings s) => s.flangerEnabled;
SoundEffectSettings _tgFlanger(SoundEffectSettings s) =>
    s.copyWith(flangerEnabled: !s.flangerEnabled);
double _getFlangerRate(SoundEffectSettings s) => s.flangerRate;
SoundEffectSettings _setFlangerRate(SoundEffectSettings s, double v) =>
    s.copyWith(flangerRate: v);
double _getFlangerDepth(SoundEffectSettings s) => s.flangerDepth;
SoundEffectSettings _setFlangerDepth(SoundEffectSettings s, double v) =>
    s.copyWith(flangerDepth: v);
double _getFlangerFeedback(SoundEffectSettings s) => s.flangerFeedback;
SoundEffectSettings _setFlangerFeedback(SoundEffectSettings s, double v) =>
    s.copyWith(flangerFeedback: v);
double _getFlangerMix(SoundEffectSettings s) => s.flangerMix;
SoundEffectSettings _setFlangerMix(SoundEffectSettings s, double v) =>
    s.copyWith(flangerMix: v);
bool _enPhaser(SoundEffectSettings s) => s.phaserEnabled;
SoundEffectSettings _tgPhaser(SoundEffectSettings s) =>
    s.copyWith(phaserEnabled: !s.phaserEnabled);
double _getPhaserRate(SoundEffectSettings s) => s.phaserRate;
SoundEffectSettings _setPhaserRate(SoundEffectSettings s, double v) =>
    s.copyWith(phaserRate: v);
double _getPhaserDepth(SoundEffectSettings s) => s.phaserDepth;
SoundEffectSettings _setPhaserDepth(SoundEffectSettings s, double v) =>
    s.copyWith(phaserDepth: v);
double _getPhaserFeedback(SoundEffectSettings s) => s.phaserFeedback;
SoundEffectSettings _setPhaserFeedback(SoundEffectSettings s, double v) =>
    s.copyWith(phaserFeedback: v);
double _getPhaserMix(SoundEffectSettings s) => s.phaserMix;
SoundEffectSettings _setPhaserMix(SoundEffectSettings s, double v) =>
    s.copyWith(phaserMix: v);
bool _enCompressor(SoundEffectSettings s) => s.compressorEnabled;
SoundEffectSettings _tgCompressor(SoundEffectSettings s) =>
    s.copyWith(compressorEnabled: !s.compressorEnabled);
double _getCompThreshold(SoundEffectSettings s) => s.compressorThreshold;
SoundEffectSettings _setCompThreshold(SoundEffectSettings s, double v) =>
    s.copyWith(compressorThreshold: v);
double _getCompRatio(SoundEffectSettings s) => s.compressorRatio;
SoundEffectSettings _setCompRatio(SoundEffectSettings s, double v) =>
    s.copyWith(compressorRatio: v);
double _getCompAttack(SoundEffectSettings s) => s.compressorAttack;
SoundEffectSettings _setCompAttack(SoundEffectSettings s, double v) =>
    s.copyWith(compressorAttack: v);
double _getCompRelease(SoundEffectSettings s) => s.compressorRelease;
SoundEffectSettings _setCompRelease(SoundEffectSettings s, double v) =>
    s.copyWith(compressorRelease: v);
bool _enNoiseGate(SoundEffectSettings s) => s.noiseGateEnabled;
SoundEffectSettings _tgNoiseGate(SoundEffectSettings s) =>
    s.copyWith(noiseGateEnabled: !s.noiseGateEnabled);
double _getNoiseGateThreshold(SoundEffectSettings s) =>
    s.noiseGateThreshold;
SoundEffectSettings _setNoiseGateThreshold(SoundEffectSettings s, double v) =>
    s.copyWith(noiseGateThreshold: v);
bool _enLimiter(SoundEffectSettings s) => s.limiterEnabled;
SoundEffectSettings _tgLimiter(SoundEffectSettings s) =>
    s.copyWith(limiterEnabled: !s.limiterEnabled);
double _getLimiterThreshold(SoundEffectSettings s) => s.limiterThreshold;
SoundEffectSettings _setLimiterThreshold(SoundEffectSettings s, double v) =>
    s.copyWith(limiterThreshold: v);
bool _enExciter(SoundEffectSettings s) => s.exciterEnabled;
SoundEffectSettings _tgExciter(SoundEffectSettings s) =>
    s.copyWith(exciterEnabled: !s.exciterEnabled);
double _getExciterAmount(SoundEffectSettings s) => s.exciterAmount;
SoundEffectSettings _setExciterAmount(SoundEffectSettings s, double v) =>
    s.copyWith(exciterAmount: v);
double _getExciterFreq(SoundEffectSettings s) => s.exciterFrequency;
SoundEffectSettings _setExciterFreq(SoundEffectSettings s, double v) =>
    s.copyWith(exciterFrequency: v);
bool _enSubBass(SoundEffectSettings s) => s.subBassEnabled;
SoundEffectSettings _tgSubBass(SoundEffectSettings s) =>
    s.copyWith(subBassEnabled: !s.subBassEnabled);
double _getSubBassAmount(SoundEffectSettings s) => s.subBassAmount;
SoundEffectSettings _setSubBassAmount(SoundEffectSettings s, double v) =>
    s.copyWith(subBassAmount: v);
double _getSubBassFreq(SoundEffectSettings s) => s.subBassFrequency;
SoundEffectSettings _setSubBassFreq(SoundEffectSettings s, double v) =>
    s.copyWith(subBassFrequency: v);
bool _enLoFi(SoundEffectSettings s) => s.loFiEnabled;
SoundEffectSettings _tgLoFi(SoundEffectSettings s) =>
    s.copyWith(loFiEnabled: !s.loFiEnabled);
double _getLoFiRate(SoundEffectSettings s) => s.loFiSampleRate;
SoundEffectSettings _setLoFiRate(SoundEffectSettings s, double v) =>
    s.copyWith(loFiSampleRate: v);
double _getLoFiBit(SoundEffectSettings s) => s.loFiBitDepth;
SoundEffectSettings _setLoFiBit(SoundEffectSettings s, double v) =>
    s.copyWith(loFiBitDepth: v);
bool _enStereoWiden(SoundEffectSettings s) => s.stereoWidenEnabled;
SoundEffectSettings _tgStereoWiden(SoundEffectSettings s) =>
    s.copyWith(stereoWidenEnabled: !s.stereoWidenEnabled);
double _getStereoWiden(SoundEffectSettings s) => s.stereoWidenAmount;
SoundEffectSettings _setStereoWiden(SoundEffectSettings s, double v) =>
    s.copyWith(stereoWidenAmount: v);
bool _enMonoMerge(SoundEffectSettings s) => s.monoMerge;
SoundEffectSettings _tgMonoMerge(SoundEffectSettings s) =>
    s.copyWith(monoMerge: !s.monoMerge);
bool _enChannelSwap(SoundEffectSettings s) => s.channelSwap;
SoundEffectSettings _tgChannelSwap(SoundEffectSettings s) =>
    s.copyWith(channelSwap: !s.channelSwap);
bool _enV4a(SoundEffectSettings s) => s.v4aEnabled;
SoundEffectSettings _tgV4a(SoundEffectSettings s) =>
    s.copyWith(v4aEnabled: !s.v4aEnabled);

String _fmtPct(double v) => '${v.round()}%';
String _fmtHz0(double v) => '${v.round()} Hz';
String _fmtHz2(double v) => '${v.toStringAsFixed(2)} Hz';
String _fmtDb0(double v) => '${v.round()} dB';
String _fmtDb1(double v) => '+${v.toStringAsFixed(1)} dB';
String _fmtMs(double v) => '${v.round()} ms';
String _fmtBit(double v) => '${v.round()} bit';
String _fmtRatio(double v) => '${v.toStringAsFixed(1)} : 1';
String _fmt1(double v) => v.toStringAsFixed(1);
String _fmtX2(double v) => '${v.toStringAsFixed(2)}x';

class _AdvancedPage extends ConsumerWidget {
  const _AdvancedPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sfx = ref.watch(soundEffectProvider).settings;
    final mgr = ref.read(soundEffectProvider.notifier);
    return _FxScaffold(
      title: '高级音效',
      children: _dspLocked(
        context,
        [
          for (final spec in _kAdvancedFx)
            _AdvRow(
              spec: spec,
              enabled: spec.enabled(sfx),
              onToggle: (v) {
                Haptics.tick();
                mgr.set(spec.toggle(sfx));
              },
              onTap: spec.hasDetail
                  ? () => showFullDialog(
                        context: context,
                        builder: (_) => _FxConfigPage(spec: spec),
                      )
                  : () {
                      Haptics.tick();
                      mgr.set(spec.toggle(sfx));
                    },
            ),
        ],
      ),
    );
  }
}

class _AdvRow extends StatelessWidget {
  const _AdvRow({
    required this.spec,
    required this.enabled,
    required this.onToggle,
    required this.onTap,
  });

  final _FxSpec spec;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Padding(
      padding: EdgeInsets.only(bottom: 8 * s),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 3 * s),
        decoration: BoxDecoration(
          color: enabled
              ? Colors.white.withValues(alpha: 0.09)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(22 * s),
          border: Border.all(
            color: enabled ? _accent.withValues(alpha: 0.35) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        spec.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5 * s,
                          fontWeight: FontWeight.w600,
                          color: enabled
                              ? Colors.white.withValues(alpha: 0.92)
                              : Colors.white.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                    if (spec.hasDetail) ...[
                      SizedBox(width: 5 * s),
                      Icon(Icons.chevron_right_rounded,
                          size: 15 * s,
                          color: Colors.white.withValues(alpha: 0.35)),
                    ],
                  ],
                ),
              ),
            ),
            SizedBox(
              width: 44 * s,
              child: Switch(
                value: enabled,
                activeThumbColor: _accent,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: onToggle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FxConfigPage extends ConsumerWidget {
  const _FxConfigPage({required this.spec});

  final _FxSpec spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final sfx = ref.watch(soundEffectProvider).settings;
    final mgr = ref.read(soundEffectProvider.notifier);
    return _FxScaffold(
      title: spec.label,
      children: _dspLocked(
        context,
        [
          _FxSwitchRow(
            label: '启用',
            value: spec.enabled(sfx),
            onChanged: (v) {
              Haptics.tick();
              mgr.set(spec.toggle(sfx));
            },
          ),
          for (final flag in spec.flags)
            _FxSwitchRow(
              label: flag.label,
              value: flag.get(sfx),
              onChanged: (v) {
                Haptics.tick();
                mgr.set(flag.set(sfx, v));
              },
            ),
          for (final choice in spec.choices) ...[
            Text(
              choice.label,
              style: TextStyle(
                fontSize: 10.5 * s,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
            SizedBox(height: 6 * s),
            Wrap(
              spacing: 7 * s,
              runSpacing: 7 * s,
              alignment: WrapAlignment.center,
              children: [
                for (final (value, label) in choice.options)
                  _FxChip(
                    label: label,
                    active: choice.get(sfx) == value,
                    onTap: () {
                      Haptics.tick();
                      mgr.set(choice.set(sfx, value));
                    },
                  ),
              ],
            ),
            SizedBox(height: 10 * s),
          ],
          for (final param in spec.params)
            _FxSlider(
              label: param.label,
              value: param.get(sfx),
              min: param.min,
              max: param.max,
              divisions: param.divisions,
              fmt: param.fmt,
              onChanged: (v) => mgr.set(param.set(sfx, v)),
            ),
        ],
      ),
    );
  }
}

// ———————————————————————————— 通用部件 ————————————————————————————

List<Widget> _dspLocked(BuildContext context, List<Widget> children) {
  if (kDspPipelineSupported) return children;
  final s = context.watchScale();
  return [
    _hint(context, '当前系统不支持 DSP 音效'),
    SizedBox(height: 10 * s),
    IgnorePointer(
      child: Opacity(opacity: 0.35, child: Column(children: children)),
    ),
  ];
}

Widget _hint(BuildContext context, String text) {
  final s = context.watchScale();
  return Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      fontSize: 10.5 * s,
      color: Colors.white.withValues(alpha: 0.42),
    ),
  );
}

class _FxScaffold extends StatefulWidget {
  const _FxScaffold({required this.title, this.children = const [], this.actions = const []});

  final String title;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  State<_FxScaffold> createState() => _FxScaffoldState();
}

class _FxScaffoldState extends State<_FxScaffold> {
  final _ctrl = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;
  final RotaryQuantizer _rotary = RotaryQuantizer();

  @override
  void initState() {
    super.initState();
    _rotarySub = rotaryEvents.listen(_onRotary);
  }

  @override
  void dispose() {
    _rotarySub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onRotary(RotaryEvent e) {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    if (!_ctrl.hasClients) return;
    final steps = _rotary.add(e);
    if (steps == 0) return;
    final s = context.watchScale();
    final target = (_ctrl.offset + steps * 48 * s)
        .clamp(0.0, _ctrl.position.maxScrollExtent);
    _ctrl.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            controller: _ctrl,
            padding: EdgeInsets.symmetric(horizontal: 22 * s, vertical: 16 * s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16 * s,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 14 * s),
                ...widget.children,
                if (widget.actions.isNotEmpty) ...[
                  SizedBox(height: 18 * s),
                  Row(
                    children: [
                      for (final (i, a) in widget.actions.indexed) ...[
                        if (i > 0) SizedBox(width: 10 * s),
                        Expanded(child: a),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FxRow extends StatelessWidget {
  const _FxRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Padding(
      padding: EdgeInsets.only(bottom: 8 * s),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          height: 46 * s,
          padding: EdgeInsets.symmetric(horizontal: 12 * s),
          decoration: BoxDecoration(
            color: enabled
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(23 * s),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18 * s,
                color: enabled
                    ? Colors.white.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.3),
              ),
              SizedBox(width: 10 * s),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13 * s,
                    fontWeight: FontWeight.w600,
                    color: enabled
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 11 * s,
                  color: enabled ? _accent : Colors.white.withValues(alpha: 0.3),
                ),
              ),
              SizedBox(width: 5 * s),
              Icon(
                Icons.chevron_right_rounded,
                size: 15 * s,
                color: Colors.white.withValues(alpha: enabled ? 0.4 : 0.15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FxChip extends StatelessWidget {
  const _FxChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(horizontal: 13 * s, vertical: 8 * s),
        decoration: BoxDecoration(
          color: active
              ? _accent.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(17 * s),
          border: Border.all(
            color: active ? _accent : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12 * s,
            fontWeight: FontWeight.w600,
            color: active
                ? _accent
                : Colors.white.withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }
}

class _FxSwitchRow extends StatelessWidget {
  const _FxSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Padding(
      padding: EdgeInsets.only(bottom: 8 * s),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 3 * s),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(22 * s),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5 * s,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ),
            SizedBox(
              width: 44 * s,
              child: Switch(
                value: value,
                activeThumbColor: _accent,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FxSlider extends StatefulWidget {
  const _FxSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.fmt,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) fmt;
  final ValueChanged<double> onChanged;

  @override
  State<_FxSlider> createState() => _FxSliderState();
}

class _FxSliderState extends State<_FxSlider> {
  late double _draft = widget.value;

  @override
  void didUpdateWidget(covariant _FxSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != _draft) {
      _draft = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Padding(
      padding: EdgeInsets.only(bottom: 2 * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12 * s,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ),
              Text(
                widget.fmt(_draft),
                style: TextStyle(
                  fontSize: 11.5 * s,
                  fontWeight: FontWeight.w600,
                  color: _accent,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 26 * s,
            child: Slider(
              value: _draft.clamp(widget.min, widget.max),
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              activeColor: _accent,
              inactiveColor: Colors.white.withValues(alpha: 0.14),
              onChanged: (v) => setState(() => _draft = v),
              onChangeEnd: (v) {
                Haptics.tick();
                widget.onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
