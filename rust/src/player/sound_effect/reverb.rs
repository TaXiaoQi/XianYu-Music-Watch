
#![allow(dead_code)]

use super::dsp::{soft_clip, SmoothedValue};
use super::{ReverbKind, SoundEffectSettings};
use std::f32::consts::PI;

// =========================================================================
// Freeverb 常量（标准 Dreampoint/STK 调谐）
// =========================================================================

const FIXED_GAIN: f32 = 0.04;
const WET_BOOST: f32 = 1.0;
const ER_GAIN: f32 = 0.0;
const SCALE_ROOM: f32 = 0.28;
const OFFSET_ROOM: f32 = 0.7;
const ROOM_EXTEND_SLOPE: f32 = 0.015;
const FEEDBACK_MAX: f32 = 0.92;
const SCALE_DAMP: f32 = 0.55;
const ALLPASS_FEEDBACK: f32 = 0.5;
const LIMITER_CEILING: f32 = 0.95;

const COMB_L: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
const COMB_R: [usize; 8] = [1139, 1211, 1300, 1379, 1445, 1514, 1580, 1640];
const ALLPASS_L: [usize; 4] = [556, 441, 341, 225];
const ALLPASS_R: [usize; 4] = [579, 464, 364, 248];

const ER_DELAYS_MS: [f32; 6] = [11.0, 19.0, 29.0, 37.0, 47.0, 61.0];
const ER_GAINS: [f32; 6] = [0.65, 0.52, 0.45, 0.38, 0.32, 0.25];

// =========================================================================
// 算法类型枚举
// =========================================================================

#[derive(Clone, Copy, PartialEq, Debug)]
enum ReverbAlgorithm {
    Freeverb,
    Tunnel,
    Valley,
    Metal,
    Spring,
    Plate,
}

// =========================================================================
// 梳状滤波器（低通反馈，Freeverb 核心）
// =========================================================================

struct Comb {
    buffer: Vec<f32>,
    idx: usize,
    feedback: f32,
    filter_store: f32,
    damp1: f32,
    damp2: f32,
}

impl Comb {
    fn new(len: usize) -> Self {
        Self {
            buffer: vec![0.0; len.max(1)],
            idx: 0,
            feedback: 0.5,
            filter_store: 0.0,
            damp1: 0.5,
            damp2: 0.5,
        }
    }

    fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.idx = 0;
        self.filter_store = 0.0;
    }

    #[inline]
    fn process(&mut self, input: f32) -> f32 {
        let output = self.buffer[self.idx];
        self.filter_store = output * self.damp2 + self.filter_store * self.damp1;
        self.buffer[self.idx] = input + self.filter_store * self.feedback;
        self.idx = if self.idx + 1 >= self.buffer.len() {
            0
        } else {
            self.idx + 1
        };
        output
    }
}

// =========================================================================
// 全通滤波器（Schroeder）
// =========================================================================

struct Allpass {
    buffer: Vec<f32>,
    idx: usize,
    feedback: f32,
}

impl Allpass {
    fn new(len: usize) -> Self {
        Self {
            buffer: vec![0.0; len.max(1)],
            idx: 0,
            feedback: ALLPASS_FEEDBACK,
        }
    }

    fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.idx = 0;
    }

    #[inline]
    fn process(&mut self, input: f32) -> f32 {
        let bufout = self.buffer[self.idx];
        let output = -input + bufout;
        self.buffer[self.idx] = input + bufout * self.feedback;
        self.idx = if self.idx + 1 >= self.buffer.len() {
            0
        } else {
            self.idx + 1
        };
        output
    }
}

// =========================================================================
// 早期反射（6 抽头多抽头延迟）
// =========================================================================

struct EarlyReflections {
    delays: [Vec<f32>; 6],
    indices: [usize; 6],
    gains: [f32; 6],
}

impl EarlyReflections {
    fn new(sample_rate: f32) -> Self {
        let sr = sample_rate;
        let delays = std::array::from_fn(|i| {
            let len = ((ER_DELAYS_MS[i] * sr / 1000.0).round() as usize).max(1);
            vec![0.0; len]
        });
        Self {
            delays,
            indices: [0; 6],
            gains: ER_GAINS,
        }
    }

    fn clear(&mut self) {
        for d in &mut self.delays {
            d.fill(0.0);
        }
        self.indices = [0; 6];
    }

    #[inline]
    fn process(&mut self, input: f32) -> f32 {
        let mut sum = 0.0_f32;
        for i in 0..6 {
            let out = self.delays[i][self.indices[i]];
            self.delays[i][self.indices[i]] = input;
            self.indices[i] = if self.indices[i] + 1 >= self.delays[i].len() {
                0
            } else {
                self.indices[i] + 1
            };
            sum += out * self.gains[i];
        }
        sum
    }
}

// =========================================================================
// 简单噪声生成器（LCG，无外部依赖）
// =========================================================================

struct SimpleNoise {
    state: u32,
}

impl SimpleNoise {
    fn new() -> Self {
        Self { state: 12345 }
    }

    #[inline]
    fn next(&mut self) -> f32 {
        self.state = self.state.wrapping_mul(1103515245).wrapping_add(12345);
        ((self.state >> 8) & 0xFFFFFF) as f32 / 8388608.0 - 1.0
    }
}

// =========================================================================
// 回声混响（Tunnel / Valley 专用）
// =========================================================================

struct EchoReverb {
    delay_l: Vec<f32>,
    delay_r: Vec<f32>,
    idx_l: usize,
    idx_r: usize,
    delay_samples_l: usize,
    delay_samples_r: usize,
    feedback: f32,
    diff_l: f32,
    diff_r: f32,
    diff_coeff: f32,
    noise_gain: f32,
    noise: SimpleNoise,
    lfo_phase: f32,
    lfo_inc: f32,
}

impl EchoReverb {
    fn new(
        sample_rate: f32,
        interval_ms: f32,
        feedback: f32,
        diffusion: f32,
        noise_gain: f32,
    ) -> Self {
        let base_len = ((interval_ms * sample_rate / 1000.0).round() as usize).max(1);
        let len_l = base_len;
        let len_r = base_len + 23;
        let diff_coeff = diffusion * 0.6;
        let lfo_inc = 0.01;
        Self {
            delay_l: vec![0.0; len_l],
            delay_r: vec![0.0; len_r],
            idx_l: 0,
            idx_r: 0,
            delay_samples_l: len_l,
            delay_samples_r: len_r,
            feedback,
            diff_l: 0.0,
            diff_r: 0.0,
            diff_coeff,
            noise_gain,
            noise: SimpleNoise::new(),
            lfo_phase: 0.0,
            lfo_inc,
        }
    }

    fn clear(&mut self) {
        self.delay_l.fill(0.0);
        self.delay_r.fill(0.0);
        self.idx_l = 0;
        self.idx_r = 0;
        self.diff_l = 0.0;
        self.diff_r = 0.0;
    }

    #[inline]
    fn process(&mut self, input_l: f32, input_r: f32) -> (f32, f32) {
        let out_l = self.delay_l[self.idx_l];
        let out_r = self.delay_r[self.idx_r];

        let one_minus = 1.0 - self.diff_coeff;
        self.diff_l = out_l * one_minus + self.diff_l * self.diff_coeff;
        self.diff_r = out_r * one_minus + self.diff_r * self.diff_coeff;

        let noise = self.noise.next();
        let lfo = self.lfo_phase.sin() * 0.3;
        self.lfo_phase += self.lfo_inc;
        if self.lfo_phase >= 2.0 * PI {
            self.lfo_phase -= 2.0 * PI;
        }

        let noise_l = (noise * 0.7 + lfo) * self.noise_gain;
        let noise_r = (noise * 0.7 - lfo) * self.noise_gain;

        self.delay_l[self.idx_l] = input_l + self.diff_l * self.feedback + noise_l;
        self.delay_r[self.idx_r] = input_r + self.diff_r * self.feedback + noise_r;

        self.idx_l = if self.idx_l + 1 >= self.delay_samples_l {
            0
        } else {
            self.idx_l + 1
        };
        self.idx_r = if self.idx_r + 1 >= self.delay_samples_r {
            0
        } else {
            self.idx_r + 1
        };

        (out_l, out_r)
    }
}

// =========================================================================
// 正弦共振器（Metal / Spring 专用）
// =========================================================================

struct Resonator {
    phase: f32,
    phase_inc: f32,
    amplitude: f32,
    decay: f32,
    sensitivity: f32,
    gain: f32,
}

impl Resonator {
    fn new(freq: f32, sample_rate: f32, decay_rate: f32, sensitivity: f32, gain: f32) -> Self {
        Self {
            phase: 0.0,
            phase_inc: 2.0 * PI * freq / sample_rate,
            amplitude: 0.0,
            decay: (-decay_rate / sample_rate).exp(),
            sensitivity,
            gain,
        }
    }

    fn clear(&mut self) {
        self.phase = 0.0;
        self.amplitude = 0.0;
    }

    #[inline]
    fn process(&mut self, input: f32) -> f32 {
        self.amplitude += input.abs() * self.sensitivity;
        self.amplitude *= self.decay;
        if self.amplitude > 4.0 {
            self.amplitude = 4.0;
        }
        let output = self.amplitude * self.phase.sin() * self.gain;
        self.phase += self.phase_inc;
        if self.phase >= 2.0 * PI {
            self.phase -= 2.0 * PI;
        }
        output
    }
}

// =========================================================================
// ReverbRack（多算法混响机架）
// =========================================================================

pub struct ReverbRack {
    sample_rate: f32,
    channels: usize,
    enabled: SmoothedValue,

    // --- Freeverb 路径（Freeverb / Plate 算法共用）---
    combs_l: [Comb; 8],
    combs_r: [Comb; 8],
    allpass_l: [Allpass; 4],
    allpass_r: [Allpass; 4],
    early_l: EarlyReflections,
    early_r: EarlyReflections,

    // --- Echo 路径（Tunnel / Valley 算法共用）---
    tunnel_echo: EchoReverb,
    valley_echo: EchoReverb,

    // --- 共振器路径（Metal / Spring 算法共用）---
    metal_res1_l: Resonator,
    metal_res1_r: Resonator,
    metal_res2_l: Resonator,
    metal_res2_r: Resonator,
    metal_noise: SimpleNoise,

    spring_res_l: Resonator,
    spring_res_r: Resonator,
    spring_noise: SimpleNoise,

    // --- 噪声包络跟踪（Metal/Spring 噪声门控）---
    noise_env: f32,

    // --- 公共参数 ---
    cur_preset: String,
    cur_kind: ReverbKind,
    algorithm: ReverbAlgorithm,
    room_size: f32,
    damping: f32,
    width: f32,
    input_gain: f32,
    limiter_gain: f32,
}

impl ReverbRack {
    pub fn new() -> Self {
        Self {
            sample_rate: 44100.0,
            channels: 2,
            enabled: SmoothedValue::new(0.0),
            combs_l: std::array::from_fn(|i| Comb::new(COMB_L[i])),
            combs_r: std::array::from_fn(|i| Comb::new(COMB_R[i])),
            allpass_l: std::array::from_fn(|i| Allpass::new(ALLPASS_L[i])),
            allpass_r: std::array::from_fn(|i| Allpass::new(ALLPASS_R[i])),
            early_l: EarlyReflections::new(44100.0),
            early_r: EarlyReflections::new(44100.0),
            tunnel_echo: EchoReverb::new(44100.0, 120.0, 0.70, 0.7, 0.0),
            valley_echo: EchoReverb::new(44100.0, 150.0, 0.55, 0.4, 0.0),
            metal_res1_l: Resonator::new(1053.0, 44100.0, 2.5, 0.08, 0.15),
            metal_res1_r: Resonator::new(1053.0, 44100.0, 2.5, 0.08, 0.15),
            metal_res2_l: Resonator::new(1615.0, 44100.0, 3.0, 0.08, 0.10),
            metal_res2_r: Resonator::new(1615.0, 44100.0, 3.0, 0.08, 0.10),
            metal_noise: SimpleNoise::new(),
            spring_res_l: Resonator::new(561.0, 44100.0, 3.0, 0.10, 0.20),
            spring_res_r: Resonator::new(561.0, 44100.0, 3.0, 0.10, 0.20),
            spring_noise: SimpleNoise::new(),
            noise_env: 0.0,
            cur_preset: String::new(),
            cur_kind: ReverbKind::None,
            algorithm: ReverbAlgorithm::Freeverb,
            room_size: 0.5,
            damping: 0.5,
            width: 1.0,
            input_gain: 1.0,
            limiter_gain: 1.0,
        }
    }

    pub fn prepare(&mut self, sample_rate: f32, channels: usize) {
        self.sample_rate = sample_rate;
        self.channels = channels;
        self.enabled.set_time_constant(0.05, sample_rate);
        let scale = |base: usize| -> usize {
            ((base as f32 * sample_rate / 44100.0).round() as usize).max(1)
        };
        for (i, c) in self.combs_l.iter_mut().enumerate() {
            *c = Comb::new(scale(COMB_L[i]));
        }
        for (i, c) in self.combs_r.iter_mut().enumerate() {
            *c = Comb::new(scale(COMB_R[i]));
        }
        for (i, a) in self.allpass_l.iter_mut().enumerate() {
            *a = Allpass::new(scale(ALLPASS_L[i]));
        }
        for (i, a) in self.allpass_r.iter_mut().enumerate() {
            *a = Allpass::new(scale(ALLPASS_R[i]));
        }
        self.early_l = EarlyReflections::new(sample_rate);
        self.early_r = EarlyReflections::new(sample_rate);
        self.tunnel_echo = EchoReverb::new(sample_rate, 120.0, 0.70, 0.7, 0.0);
        self.valley_echo = EchoReverb::new(sample_rate, 150.0, 0.55, 0.4, 0.0);
        self.metal_res1_l = Resonator::new(1053.0, sample_rate, 2.5, 0.08, 0.15);
        self.metal_res1_r = Resonator::new(1053.0, sample_rate, 2.5, 0.08, 0.15);
        self.metal_res2_l = Resonator::new(1615.0, sample_rate, 3.0, 0.08, 0.10);
        self.metal_res2_r = Resonator::new(1615.0, sample_rate, 3.0, 0.08, 0.10);
        self.spring_res_l = Resonator::new(561.0, sample_rate, 3.0, 0.10, 0.20);
        self.spring_res_r = Resonator::new(561.0, sample_rate, 3.0, 0.10, 0.20);
        self.noise_env = 0.0;
        self.cur_kind = ReverbKind::None;
        self.cur_preset.clear();
        self.limiter_gain = 1.0;
    }

    pub fn reset(&mut self) {
        for c in &mut self.combs_l {
            c.clear();
        }
        for c in &mut self.combs_r {
            c.clear();
        }
        for a in &mut self.allpass_l {
            a.clear();
        }
        for a in &mut self.allpass_r {
            a.clear();
        }
        self.early_l.clear();
        self.early_r.clear();
        self.tunnel_echo.clear();
        self.valley_echo.clear();
        self.metal_res1_l.clear();
        self.metal_res1_r.clear();
        self.metal_res2_l.clear();
        self.metal_res2_r.clear();
        self.spring_res_l.clear();
        self.spring_res_r.clear();
        self.noise_env = 0.0;
        self.limiter_gain = 1.0;
    }

    pub fn update_params(&mut self, s: &SoundEffectSettings) {
        let active = s.reverb_kind != ReverbKind::None && !s.reverb_preset.is_empty();
        self.enabled.set_target(if active { 1.0 } else { 0.0 });

        let (algorithm, room, damp, width, gain) = preset_params(&s.reverb_preset);

        if s.reverb_kind != self.cur_kind
            || s.reverb_preset != self.cur_preset
            || algorithm != self.algorithm
            || room != self.room_size
            || damp != self.damping
            || width != self.width
            || gain != self.input_gain
        {
            self.cur_kind = s.reverb_kind.clone();
            self.cur_preset = s.reverb_preset.clone();
            self.algorithm = algorithm;
            self.room_size = room;
            self.damping = damp;
            self.width = width;
            self.input_gain = gain;

            let fb = feedback_from_room(room);
            let damp1 = damp * SCALE_DAMP;
            let damp2 = 1.0 - damp1;
            for c in &mut self.combs_l {
                c.feedback = fb;
                c.damp1 = damp1;
                c.damp2 = damp2;
            }
            for c in &mut self.combs_r {
                c.feedback = fb;
                c.damp1 = damp1;
                c.damp2 = damp2;
            }

            if algorithm == ReverbAlgorithm::Tunnel {
                self.tunnel_echo.clear();
            } else if algorithm == ReverbAlgorithm::Valley {
                self.valley_echo.clear();
            }

            if algorithm == ReverbAlgorithm::Metal {
                self.metal_res1_l.clear();
                self.metal_res1_r.clear();
                self.metal_res2_l.clear();
                self.metal_res2_r.clear();
            } else if algorithm == ReverbAlgorithm::Spring {
                self.spring_res_l.clear();
                self.spring_res_r.clear();
            }
        }
    }

    pub fn process(&mut self, frame: &mut [f32], channels: u16, s: &SoundEffectSettings) {
        if channels != 2 || frame.len() < 2 {
            return;
        }
        let w = self.enabled.tick();
        if w < 0.001 {
            return;
        }

        let in_l = frame[0];
        let in_r = frame[1];

        // === Freeverb 主体（所有预设统一使用，无叠加算法）===
        let (wet_l, wet_r) = self.process_freeverb(in_l, in_r);

        let dry_gain = 1.0 + (s.reverb_dry - 1.0) * w;
        let wet = s.reverb_wet * w;
        let wet1 = wet * (self.width * 0.5 + 0.5);
        let wet2 = wet * (self.width * 0.5 - 0.5);
        let wet_out_l = wet_l * wet1 + wet_r * wet2;
        let wet_out_r = wet_r * wet1 + wet_l * wet2;
        let mixed_l = in_l * dry_gain + wet_out_l;
        let mixed_r = in_r * dry_gain + wet_out_r;

        let peak = mixed_l.abs().max(mixed_r.abs()).max(1e-9);
        let target_gain = if peak > LIMITER_CEILING {
            LIMITER_CEILING / peak
        } else {
            1.0
        };
        let coeff = if target_gain < self.limiter_gain {
            0.5
        } else {
            0.0005
        };
        self.limiter_gain += (target_gain - self.limiter_gain) * coeff;
        let comp = 1.0 + (self.limiter_gain - 1.0) * w;
        frame[0] = soft_clip(mixed_l * comp);
        frame[1] = soft_clip(mixed_r * comp);
    }

    // --- Freeverb 处理 ---

    #[inline]
    fn process_freeverb(&mut self, in_l: f32, in_r: f32) -> (f32, f32) {
        let er_l = self.early_l.process(in_l) * ER_GAIN;
        let er_r = self.early_r.process(in_r) * ER_GAIN;

        let ig = FIXED_GAIN * self.input_gain;
        let input_l = in_l * ig;
        let input_r = in_r * ig;

        let mut out_l = 0.0_f32;
        for c in &mut self.combs_l {
            out_l += c.process(input_l);
        }
        for a in &mut self.allpass_l {
            out_l = a.process(out_l);
        }

        let mut out_r = 0.0_f32;
        for c in &mut self.combs_r {
            out_r += c.process(input_r);
        }
        for a in &mut self.allpass_r {
            out_r = a.process(out_r);
        }

        (out_l * WET_BOOST + er_l, out_r * WET_BOOST + er_r)
    }

    // --- Tunnel 特征叠加（非主体，仅叠加到 Freeverb 上）---

    #[inline]
    fn process_tunnel_char(&mut self, in_l: f32, in_r: f32) -> (f32, f32) {
        let ig = self.input_gain * 0.3;
        self.tunnel_echo.process(in_l * ig, in_r * ig)
    }

    // --- Valley 特征叠加 ---

    #[inline]
    fn process_valley_char(&mut self, in_l: f32, in_r: f32) -> (f32, f32) {
        let ig = self.input_gain * 0.3;
        self.valley_echo.process(in_l * ig, in_r * ig)
    }

    // --- Metal 特征叠加 ---

    #[inline]
    fn process_metal_char(&mut self, in_l: f32, in_r: f32) -> (f32, f32) {
        let ig = self.input_gain;
        let r1l = self.metal_res1_l.process(in_l * ig);
        let r1r = self.metal_res1_r.process(in_r * ig);
        let r2l = self.metal_res2_l.process(in_l * ig);
        let r2r = self.metal_res2_r.process(in_r * ig);

        let inp = (in_l.abs() + in_r.abs()) * 0.5;
        self.noise_env = self.noise_env * 0.9995 + inp * 0.0005;
        let nl = self.metal_noise.next() * 0.3 * self.noise_env;
        let nr = self.metal_noise.next() * 0.3 * self.noise_env;
        (r1l + r2l + nl, r1r + r2r + nr)
    }

    // --- Spring 特征叠加 ---

    #[inline]
    fn process_spring_char(&mut self, in_l: f32, in_r: f32) -> (f32, f32) {
        let ig = self.input_gain;
        let rl = self.spring_res_l.process(in_l * ig);
        let rr = self.spring_res_r.process(in_r * ig);

        let inp = (in_l.abs() + in_r.abs()) * 0.5;
        self.noise_env = self.noise_env * 0.9995 + inp * 0.0005;
        let nl = self.spring_noise.next() * 0.3 * self.noise_env;
        let nr = self.spring_noise.next() * 0.3 * self.noise_env;
        (rl + nl, rr + nr)
    }
}

// =========================================================================
// room_size → 反馈增益
// =========================================================================

#[inline]
fn feedback_from_room(room: f32) -> f32 {
    if room <= 1.0 {
        (room * SCALE_ROOM + OFFSET_ROOM).min(FEEDBACK_MAX)
    } else {
        (OFFSET_ROOM + SCALE_ROOM + (room - 1.0) * ROOM_EXTEND_SLOPE).min(FEEDBACK_MAX)
    }
}

// =========================================================================
// 预设 → (算法, Freeverb 参数) 映射
// =========================================================================

fn preset_params(preset: &str) -> (ReverbAlgorithm, f32, f32, f32, f32) {
    match preset {
        // --- 13 个卷积混响预设 ---
        "phone" => (ReverbAlgorithm::Freeverb, 0.10, 0.80, 0.0, 1.0),
        "church" => (ReverbAlgorithm::Freeverb, 0.55, 0.55, 0.70, 1.0),
        "hall" => (ReverbAlgorithm::Freeverb, 0.60, 0.50, 0.70, 1.0),
        "cinema" => (ReverbAlgorithm::Freeverb, 0.50, 0.55, 0.60, 1.0),
        "restaurant" => (ReverbAlgorithm::Freeverb, 0.30, 0.65, 0.50, 1.0),
        "bathroom" => (ReverbAlgorithm::Freeverb, 0.20, 0.70, 0.40, 1.0),
        "room" => (ReverbAlgorithm::Freeverb, 0.30, 0.60, 0.50, 1.0),
        "stereo" => (ReverbAlgorithm::Freeverb, 0.45, 0.50, 0.65, 1.0),
        "matrixReverb1" => (ReverbAlgorithm::Freeverb, 0.40, 0.55, 0.60, 1.0),
        "matrixReverb2" => (ReverbAlgorithm::Freeverb, 0.45, 0.60, 0.60, 1.0),
        "cardioidSpread" => (ReverbAlgorithm::Freeverb, 0.40, 0.55, 0.65, 1.0),
        "magneticStereo" => (ReverbAlgorithm::Freeverb, 0.50, 0.55, 0.65, 1.0),
        "feedbackSuppressor" => (ReverbAlgorithm::Freeverb, 0.35, 0.70, 0.50, 1.0),
        // --- 9 个算法混响预设 ---
        "algoStudio" => (ReverbAlgorithm::Freeverb, 0.30, 0.55, 0.55, 1.0),
        "algoHall" => (ReverbAlgorithm::Freeverb, 0.60, 0.50, 0.70, 1.0),
        "algoBathroom" => (ReverbAlgorithm::Freeverb, 0.20, 0.70, 0.40, 1.0),
        "algoTunnel" => (ReverbAlgorithm::Freeverb, 0.45, 0.55, 0.65, 1.0),
        "algoValley" => (ReverbAlgorithm::Freeverb, 0.40, 0.60, 0.65, 1.0),
        "algoMetal" => (ReverbAlgorithm::Freeverb, 0.35, 0.60, 0.50, 1.0),
        "algoPlate" => (ReverbAlgorithm::Freeverb, 0.40, 0.50, 0.60, 1.0),
        "algoSpring" => (ReverbAlgorithm::Freeverb, 0.30, 0.60, 0.50, 1.0),
        "algoPreDelay" => (ReverbAlgorithm::Freeverb, 0.55, 0.50, 0.60, 1.0),
        _ => (ReverbAlgorithm::Freeverb, 0.40, 0.55, 0.60, 1.0),
    }
}

// =========================================================================
// 单元测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn settings_for(preset: &str) -> SoundEffectSettings {
        let mut s = SoundEffectSettings::default();
        s.reverb_kind = if preset.starts_with("algo") {
            ReverbKind::Algorithmic
        } else {
            ReverbKind::Convolution
        };
        s.reverb_preset = preset.to_string();
        s.reverb_dry = 0.8;
        s.reverb_wet = 0.5;
        s
    }

    #[test]
    fn test_freeverb_process_no_nan() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for("church");
        rack.update_params(&s);
        let mut nonzero = false;
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.5];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "L NaN/Inf");
            assert!(frame[1].is_finite(), "R NaN/Inf");
            if frame[0].abs() > 1e-6 || frame[1].abs() > 1e-6 {
                nonzero = true;
            }
        }
        assert!(nonzero, "输出全零，混响未生效");
    }

    #[test]
    fn test_preset_mapping_all_22() {
        let presets = [
            "phone",
            "church",
            "hall",
            "cinema",
            "restaurant",
            "bathroom",
            "room",
            "stereo",
            "matrixReverb1",
            "matrixReverb2",
            "cardioidSpread",
            "magneticStereo",
            "feedbackSuppressor",
            "algoStudio",
            "algoHall",
            "algoBathroom",
            "algoTunnel",
            "algoValley",
            "algoMetal",
            "algoPlate",
            "algoSpring",
            "algoPreDelay",
        ];
        for p in &presets {
            let (algo, room, damp, width, gain) = preset_params(p);
            assert!(room >= 0.0, "preset {} room {} 为负", p, room);
            assert!(
                damp >= 0.0 && damp <= 1.0,
                "preset {} damp {} 越界",
                p,
                damp
            );
            assert!(
                width >= 0.0 && width <= 1.0,
                "preset {} width {} 越界",
                p,
                width
            );
            assert!(gain > 0.0, "preset {} gain {} 非正", p, gain);
            assert_eq!(
                algo,
                ReverbAlgorithm::Freeverb,
                "preset {} 应为 Freeverb, 实际 {:?}",
                p,
                algo
            );
        }
    }

    #[test]
    fn test_preset_switch_no_rebuild() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let len_after_prepare = rack.combs_l[0].buffer.len();
        for p in ["church", "phone", "hall", "algoTunnel", "room"] {
            let s = settings_for(p);
            rack.update_params(&s);
            assert_eq!(
                rack.combs_l[0].buffer.len(),
                len_after_prepare,
                "切换到 {} 后 Freeverb 缓冲被重建",
                p
            );
        }
        let s_church = settings_for("church");
        rack.update_params(&s_church);
        let fb_church = rack.combs_l[0].feedback;
        let s_phone = settings_for("phone");
        rack.update_params(&s_phone);
        let fb_phone = rack.combs_l[0].feedback;
        assert_ne!(fb_church, fb_phone, "切换预设后 feedback 未变");
    }

    #[test]
    fn test_sample_rate_scaling() {
        let mut rack44 = ReverbRack::new();
        rack44.prepare(44100.0, 2);
        let len44 = rack44.combs_l[0].buffer.len();

        let mut rack48 = ReverbRack::new();
        rack48.prepare(48000.0, 2);
        let len48 = rack48.combs_l[0].buffer.len();

        assert!(
            len48 > len44,
            "48000Hz 梳状长度({})应 > 44100Hz({})",
            len48,
            len44
        );
        assert_eq!(len44, 1116);
        assert_eq!(len48, 1215);
    }

    #[test]
    fn test_bypass_passthrough() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let mut s = SoundEffectSettings::default();
        s.reverb_kind = ReverbKind::None;
        s.reverb_preset = String::new();
        s.reverb_dry = 0.8;
        s.reverb_wet = 0.5;
        rack.update_params(&s);
        for _ in 0..20000 {
            let mut frame = [0.5_f32, 0.5];
            rack.process(&mut frame, 2, &s);
        }
        let mut frame = [0.42_f32, -0.17];
        rack.process(&mut frame, 2, &s);
        assert!(
            (frame[0] - 0.42).abs() < 1e-6,
            "bypass 后 L 不等于输入: {}",
            frame[0]
        );
        assert!(
            (frame[1] + 0.17).abs() < 1e-6,
            "bypass 后 R 不等于输入: {}",
            frame[1]
        );
    }

    #[test]
    fn test_feedback_extension_long_tail() {
        let fb_small = feedback_from_room(0.2);
        let fb_mid = feedback_from_room(0.5);
        let fb_large = feedback_from_room(0.8);
        assert!(
            fb_mid > fb_small,
            "room=0.5 feedback({})应 > room=0.2({})",
            fb_mid,
            fb_small
        );
        assert!(
            fb_large > fb_mid,
            "room=0.8 feedback({})应 > room=0.5({})",
            fb_large,
            fb_mid
        );
        let fb_clamped = feedback_from_room(2.0);
        assert!(
            fb_clamped <= FEEDBACK_MAX,
            "feedback 超过上限 {}",
            fb_clamped
        );
    }

    #[test]
    fn test_early_reflections_nonzero() {
        let mut er = EarlyReflections::new(44100.0);
        for _ in 0..5000 {
            er.process(0.5);
        }
        let out = er.process(0.0);
        assert!(out.abs() > 1e-6, "早期反射输出为零，未生效");
    }

    #[test]
    fn test_wet_boost_louder_than_before() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let mut s = SoundEffectSettings::default();
        s.reverb_kind = ReverbKind::Convolution;
        s.reverb_preset = "hall".to_string();
        s.reverb_dry = 0.8;
        s.reverb_wet = 2.4;
        rack.update_params(&s);
        let mut sum_sq = 0.0_f32;
        let n = 44100_usize;
        for _ in 0..n {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            sum_sq += frame[0] * frame[0] + frame[1] * frame[1];
        }
        let rms = (sum_sq / (2.0 * n as f32)).sqrt();
        assert!(rms > 0.1, "hall 预设 RMS={} 过低", rms);
    }

    // --- 新增：专用算法测试 ---

    #[test]
    fn test_tunnel_process_no_nan() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for("algoTunnel");
        rack.update_params(&s);
        let mut nonzero = false;
        for _ in 0..44100 * 2 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "Tunnel L NaN/Inf");
            assert!(frame[1].is_finite(), "Tunnel R NaN/Inf");
            if frame[0].abs() > 1e-6 {
                nonzero = true;
            }
        }
        assert!(nonzero, "Tunnel 输出全零，算法未生效");
    }

    #[test]
    fn test_valley_process_no_nan() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for("algoValley");
        rack.update_params(&s);
        let mut nonzero = false;
        for _ in 0..44100 * 2 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "Valley L NaN/Inf");
            assert!(frame[1].is_finite(), "Valley R NaN/Inf");
            if frame[0].abs() > 1e-6 {
                nonzero = true;
            }
        }
        assert!(nonzero, "Valley 输出全零，算法未生效");
    }

    #[test]
    fn test_metal_process_no_nan() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for("algoMetal");
        rack.update_params(&s);
        let mut nonzero = false;
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "Metal L NaN/Inf");
            assert!(frame[1].is_finite(), "Metal R NaN/Inf");
            if frame[0].abs() > 1e-6 {
                nonzero = true;
            }
        }
        assert!(nonzero, "Metal 输出全零，算法未生效");
    }

    #[test]
    fn test_spring_process_no_nan() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for("algoSpring");
        rack.update_params(&s);
        let mut nonzero = false;
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "Spring L NaN/Inf");
            assert!(frame[1].is_finite(), "Spring R NaN/Inf");
            if frame[0].abs() > 1e-6 {
                nonzero = true;
            }
        }
        assert!(nonzero, "Spring 输出全零，算法未生效");
    }

    #[test]
    fn test_plate_process_no_nan() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for("algoPlate");
        rack.update_params(&s);
        let mut nonzero = false;
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "Plate L NaN/Inf");
            assert!(frame[1].is_finite(), "Plate R NaN/Inf");
            if frame[0].abs() > 1e-6 {
                nonzero = true;
            }
        }
        assert!(nonzero, "Plate 输出全零，算法未生效");
    }

    #[test]
    fn test_algorithm_switch_no_panic() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        for p in [
            "church",
            "algoTunnel",
            "algoValley",
            "algoMetal",
            "algoSpring",
            "algoPlate",
            "hall",
            "algoHall",
        ] {
            let s = settings_for(p);
            rack.update_params(&s);
            for _ in 0..100 {
                let mut frame = [0.5_f32, 0.4];
                rack.process(&mut frame, 2, &s);
            }
        }
    }

    #[test]
    fn test_resonator_decay() {
        let mut res = Resonator::new(1000.0, 44100.0, 3.0, 0.2, 0.5);
        res.process(0.5);
        let initial = res.process(0.0).abs();
        for _ in 0..44100 {
            res.process(0.0);
        }
        let final_amp = res.process(0.0).abs();
        assert!(
            final_amp < initial * 0.1,
            "共振器未衰减: initial={}, final={}",
            initial,
            final_amp
        );
        assert!(final_amp < 0.001, "共振器最终幅度过大: {}", final_amp);
    }

    #[test]
    fn test_echo_reverb_discrete_echo() {
        let mut echo = EchoReverb::new(44100.0, 120.0, 0.75, 0.0, 0.0);
        echo.process(1.0, 1.0);
        let mut max_echo = 0.0_f32;
        for _ in 0..12000 {
            let (l, r) = echo.process(0.0, 0.0);
            max_echo = max_echo.max(l.abs()).max(r.abs());
        }
        assert!(max_echo > 0.1, "Tunnel 回声未产生: max_echo={}", max_echo);
    }

    #[test]
    fn test_simple_noise_range() {
        let mut noise = SimpleNoise::new();
        for _ in 0..1000 {
            let v = noise.next();
            assert!(v >= -1.0 && v < 1.0, "噪声超出范围: {}", v);
            assert!(v.is_finite(), "噪声 NaN/Inf");
        }
    }
}