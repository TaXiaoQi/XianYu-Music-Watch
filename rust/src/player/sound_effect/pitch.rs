
use super::SoundEffectSettings;
use std::collections::VecDeque;

const OLA_SEG: usize = 1024;
const OLA_HOP: usize = OLA_SEG / 2;

pub struct PitchRateProcessor {
    channels: usize,
    sample_rate: f32,

    do_ola: bool,
    ola_stretch: f64,
    do_resample: bool,
    resample_ratio: f64,

    input_buf: VecDeque<f32>,
    ola_q: VecDeque<f32>,

    ola_out: Vec<f32>,
    ola_head: usize,
    ola_pos: f64,
    ola_win: Vec<f32>,
    raw_eof: bool,

    tail_zero_frames: usize,

    read_src_pos: f64,
}

impl PitchRateProcessor {
    pub fn new(channels: u16, sample_rate: u32) -> Self {
        let ch = (channels as usize).max(1);
        let mut win = vec![0.0f32; OLA_SEG];
        for (k, w) in win.iter_mut().enumerate() {
            let th = (std::f32::consts::TAU * k as f32) / OLA_SEG as f32;
            *w = 0.5 * (1.0 - th.cos());
        }
        Self {
            channels: ch,
            sample_rate: sample_rate as f32,
            do_ola: false,
            ola_stretch: 1.0,
            do_resample: false,
            resample_ratio: 1.0,
            input_buf: VecDeque::with_capacity(16384),
            ola_q: VecDeque::with_capacity(8192),
            ola_out: vec![0.0f32; OLA_SEG * ch],
            ola_head: 0,
            ola_pos: 0.0,
            ola_win: win,
            raw_eof: false,
            tail_zero_frames: 0,
            read_src_pos: 0.0,
        }
    }

    pub fn prepare(&mut self, sample_rate: f32, channels: usize) {
        self.sample_rate = sample_rate;
        self.channels = channels.max(1);
        self.input_buf.clear();
        self.ola_q.clear();
        self.ola_out.fill(0.0);
        self.ola_head = 0;
        self.ola_pos = 0.0;
        self.raw_eof = false;
        self.downstream_reset();
    }

    pub fn reset(&mut self) {
        self.input_buf.clear();
        self.ola_q.clear();
        self.ola_out.fill(0.0);
        self.ola_head = 0;
        self.ola_pos = 0.0;
        self.raw_eof = false;
        self.downstream_reset();
    }

    pub fn update_params(&mut self, s: &SoundEffectSettings) {
        let raw_rate = if !s.playback_rate.is_finite() || s.playback_rate <= 0.0 {
            100.0
        } else {
            s.playback_rate
        };
        let raw_pitch = if !s.pitch_shift.is_finite() || s.pitch_shift <= 0.0 {
            100.0
        } else {
            s.pitch_shift
        };
        let rate = (raw_rate / 100.0).clamp(0.25, 4.0);
        let pitch = (raw_pitch / 100.0).clamp(0.25, 4.0);

        let pitch_changed = (pitch - 1.0).abs() >= 0.001;
        let rate_changed = (rate - 1.0).abs() >= 0.001;

        if s.preserves_pitch {
            self.do_ola = rate_changed;
            self.ola_stretch = 1.0 / rate as f64;
            self.do_resample = pitch_changed;
            self.resample_ratio = pitch as f64;
            if !self.do_ola {
                self.ola_q.clear();
            }
            if rate_changed || pitch_changed {
                self.update_downstream_stage();
            }
        } else {
            if pitch_changed {
                self.do_ola = false;
                self.ola_q.clear();
                self.do_resample = true;
                self.resample_ratio = if rate_changed {
                    pitch as f64 * rate as f64
                } else {
                    pitch as f64
                };
                self.update_downstream_stage();
            } else if rate_changed {
                self.do_ola = false;
                self.ola_q.clear();
                self.do_resample = false;
                self.downstream_reset();
            } else {
                self.do_ola = false;
                self.do_resample = false;
                self.ola_q.clear();
                self.input_buf.clear();
                self.ola_out.fill(0.0);
                self.ola_head = 0;
                self.ola_pos = 0.0;
                self.raw_eof = false;
            }
        }
    }

    fn downstream_reset(&mut self) {
    }

    fn update_downstream_stage(&mut self) {
    }

    pub fn effective_sample_rate(&self, inner_rate: u32) -> u32 {
        if self.do_ola {
            inner_rate
        } else if self.do_resample && (self.resample_ratio - 1.0).abs() >= 0.001 {
            inner_rate
        } else {
            inner_rate
        }
    }

    pub fn fill<I: Iterator<Item = f32>>(&mut self, inner: &mut I, out: &mut [f32]) -> bool {
        let ch = self.channels;

        if !self.do_ola && !self.do_resample {
            for i in 0..ch.min(out.len()) {
                if let Some(s) = inner.next() {
                    out[i] = s;
                } else {
                    return false;
                }
            }
            return true;
        }

        if !self.do_resample {
            loop {
                if self.ola_q.len() >= ch {
                    for i in 0..ch.min(out.len()) {
                        out[i] = self.ola_q.pop_front().unwrap_or(0.0);
                    }
                    return true;
                }
                if !self.ola_pump(inner) {
                    return false;
                }
            }
        }

        self.fill_resampled(inner, out)
    }

    fn fill_resampled<I: Iterator<Item = f32>>(
        &mut self,
        inner: &mut I,
        out: &mut [f32],
    ) -> bool {
        let ch = self.channels;
        let ratio = self.resample_ratio;

        if !self.raw_eof {
            self.ensure_resample_input(inner);
        }

        let src = self.resample_src_len();
        if src < (self.read_src_pos.floor() as usize) + 2 {
            if self.raw_eof && self.input_eof() {
                let idx = self.read_src_pos.floor() as usize;
                if idx * ch < src * ch {
                    for c in 0..ch.min(out.len()) {
                        out[c] = self.source_sample(idx * ch + c);
                    }
                } else {
                    for i in 0..ch.min(out.len()) {
                        out[i] = 0.0;
                    }
                }
                return false;
            }
            if self.raw_eof {
                for i in 0..ch.min(out.len()) {
                    out[i] = self.source_sample((self.read_src_pos.floor() as usize) * ch + i);
                }
                self.read_src_pos += ratio;
                return true;
            }
            for i in 0..ch.min(out.len()) {
                out[i] = 0.0;
            }
            return true;
        }

        let idx = self.read_src_pos.floor() as usize;
        let frac = (self.read_src_pos - idx as f64) as f32;
        for c in 0..ch.min(out.len()) {
            let s0 = self.source_sample(idx * ch + c);
            let s1 = self.source_sample((idx + 1) * ch + c);
            out[c] = s0 + (s1 - s0) * frac;
        }
        self.read_src_pos += ratio;

        let consumed = self.read_src_pos.floor() as usize;
        if consumed > 0 {
            self.discard_source(consumed * ch);
            self.read_src_pos -= consumed as f64;
        }
        true
    }

    // =====================================================================
    // 统一"上游样本源"抽象：让重采样既能读 OLA 输出，也能读原始输入。
    // =====================================================================

    fn resample_src_len(&self) -> usize {
        if self.do_ola {
            self.ola_q.len() / self.channels.max(1)
        } else {
            self.input_buf.len() / self.channels.max(1)
        }
    }

    fn source_sample(&self, sample_idx: usize) -> f32 {
        if self.do_ola {
            self.ola_q.get(sample_idx).copied().unwrap_or(0.0)
        } else {
            self.input_buf.get(sample_idx).copied().unwrap_or(0.0)
        }
    }

    fn discard_source(&mut self, count: usize) {
        let buf = if self.do_ola {
            &mut self.ola_q
        } else {
            &mut self.input_buf
        };
        let to_remove = count.min(buf.len());
        for _ in 0..to_remove {
            buf.pop_front();
        }
    }

    fn ensure_resample_input<I: Iterator<Item = f32>>(&mut self, inner: &mut I) {
        if self.do_ola {
            for _ in 0..2 {
                if self.resample_src_len() >= 8 {
                    break;
                }
                if !self.ola_pump(inner) {
                    self.raw_eof = true;
                    break;
                }
            }
            return;
        }
        let consumption = self.resample_ratio.max(1.0);
        let max_per_call = (consumption.ceil() as usize).max(1).min(32);
        let need_frames = self.read_src_pos.floor() as usize + 4;
        for _ in 0..max_per_call {
            if self.input_buf.len() / self.channels >= need_frames {
                break;
            }
            let mut frame_eof = false;
            for _ in 0..self.channels {
                match inner.next() {
                    Some(s) => self.input_buf.push_back(s),
                    None => {
                        frame_eof = true;
                        self.input_buf.push_back(0.0);
                    }
                }
            }
            if frame_eof {
                self.raw_eof = true;
                break;
            }
        }
    }

    fn input_eof(&self) -> bool {
        self.raw_eof && !self.do_ola
    }

    // =====================================================================
    // OLA 时间拉伸
    // =====================================================================

    fn ola_pump<I: Iterator<Item = f32>>(&mut self, inner: &mut I) -> bool {
        if !self.raw_eof {
            for _ in 0..(OLA_SEG / 2) {
                match inner.next() {
                    Some(s) => self.input_buf.push_back(s),
                    None => {
                        self.raw_eof = true;
                        for _ in 0..self.channels * OLA_SEG {
                            self.input_buf.push_back(0.0);
                        }
                        break;
                    }
                }
            }
        }

        loop {
            let seg_start = self.ola_pos.floor() as usize;
            let need_frames = seg_start + OLA_SEG;
            if (self.input_buf.len() / self.channels) < need_frames {
                break;
            }
            self.ola_place(seg_start);
            self.ola_emit();
            self.tail_zero_frames = 0;
        }

        self.ola_q.len() >= self.channels || !(self.raw_eof && self.ola_q.is_empty())
    }

    fn ola_place(&mut self, seg_start: usize) {
        let ch = self.channels;
        let seg = OLA_SEG;
        let frac = (self.ola_pos - seg_start as f64) as f32;
        let ring_len = seg * ch;
        let base = self.ola_head;

        for k in 0..seg {
            let fa = seg_start + k;
            let w = self.ola_win[k];
            for c in 0..ch {
                let idx = base + (k * ch + c);
                let ring_idx = idx % ring_len;
                let s0 = self.input_buf.get(fa * ch + c).copied().unwrap_or(0.0);
                let s1 = self
                    .input_buf
                    .get((fa + 1) * ch + c)
                    .copied()
                    .unwrap_or(0.0);
                let sample = if frac > 1e-6 {
                    s0 + (s1 - s0) * frac
                } else {
                    s0
                };
                self.ola_out[ring_idx] += sample * w;
            }
        }
        self.ola_pos += OLA_HOP as f64 / self.ola_stretch;
    }

    fn ola_emit(&mut self) {
        let ch = self.channels;
        let seg = OLA_SEG;
        let ring_len = seg * ch;
        for k in 0..OLA_HOP {
            for c in 0..ch {
                let idx = (self.ola_head + k * ch + c) % ring_len;
                let v = self.ola_out[idx];
                self.ola_q.push_back(v);
                self.ola_out[idx] = 0.0;
            }
        }
        self.ola_head = (self.ola_head + OLA_HOP * ch) % ring_len;
        self.tail_zero_frames += OLA_HOP;
    }
}

#[cfg(test)]
mod tests {
    use super::PitchRateProcessor;
    use crate::player::sound_effect::SoundEffectSettings;

    const SR: usize = 44100;

    fn sine(n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| {
                (std::f32::consts::TAU * 440.0 * i as f32 / SR as f32).sin()
            })
            .collect()
    }

    fn run(settings: &SoundEffectSettings, input_frames: usize) -> Vec<f32> {
        let mut p = PitchRateProcessor::new(1, SR as u32);
        p.prepare(SR as f32, 1);
        p.update_params(settings);
        let mut iter = sine(input_frames).into_iter();
        let mut out = Vec::with_capacity(input_frames * 2);
        let mut frame = vec![0.0f32; 1];
        let mut guard = 0;
        let max_guard = (input_frames as u64) * 8 + 1_000_000;
        while guard < max_guard {
            guard += 1;
            if !p.fill(&mut iter, &mut frame) {
                break;
            }
            out.push(frame[0]);
        }
        out
    }

    #[test]
    fn neutral_is_passthrough() {
        let s = SoundEffectSettings {
            playback_rate: 100.0,
            pitch_shift: 100.0,
            preserves_pitch: false,
            ..Default::default()
        };
        let input = sine(4096);
        let out = run(&s, 4096);
        assert_eq!(out.len(), input.len());
        for (a, b) in out.iter().zip(input.iter()) {
            assert!((a - b).abs() < 1e-4, "passthrough mismatch {a} vs {b}");
        }
    }

    #[test]
    fn ola_speed_up_half_duration() {
        let s = SoundEffectSettings {
            playback_rate: 200.0,
            pitch_shift: 100.0,
            preserves_pitch: true,
            ..Default::default()
        };
        let input_frames = SR;
        let out = run(&s, input_frames);
        let ratio = out.len() as f64 / input_frames as f64;
        assert!((0.40..0.70).contains(&ratio), "speed-up ratio={ratio}");
    }

    #[test]
    fn ola_slow_down_double_duration() {
        let s = SoundEffectSettings {
            playback_rate: 50.0,
            pitch_shift: 100.0,
            preserves_pitch: true,
            ..Default::default()
        };
        let input_frames = SR;
        let out = run(&s, input_frames);
        let ratio = out.len() as f64 / input_frames as f64;
        assert!((1.55..2.30).contains(&ratio), "slow-down ratio={ratio}");
    }
}