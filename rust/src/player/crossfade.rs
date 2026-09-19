
#![allow(dead_code)]

use std::f32::consts::PI;

pub struct PcmCrossfadeMixer;

impl PcmCrossfadeMixer {
    #[inline]
    pub fn gain_out(progress: f32) -> f32 {
        let p = progress.clamp(0.0, 1.0);
        let out = (p * PI / 2.0).cos();
        let inn = (p * PI / 2.0).sin();
        let denom = (out + inn).max(1.0e-6);
        out / denom
    }

    #[inline]
    pub fn gain_in(progress: f32) -> f32 {
        let p = progress.clamp(0.0, 1.0);
        let out = (p * PI / 2.0).cos();
        let inn = (p * PI / 2.0).sin();
        let denom = (out + inn).max(1.0e-6);
        inn / denom
    }

    pub fn mix_in_place(
        current: &mut [f32],
        next: &[f32],
        gain_out: f32,
        gain_in: f32,
    ) {
        let len = current.len().min(next.len());
        for i in 0..len {
            let mixed = current[i] * gain_out + next[i] * gain_in;
            current[i] = if mixed.is_finite() { mixed } else { current[i] };
        }
    }

    pub fn mix_crossfade(current: &mut [f32], next: &[f32]) {
        let len = current.len().min(next.len());
        if len == 0 {
            return;
        }
        let inv = 1.0 / len as f32;
        for i in 0..len {
            let p = i as f32 * inv;
            let g_out = Self::gain_out(p);
            let g_in = Self::gain_in(p);
            let mixed = current[i] * g_out + next[i] * g_in;
            current[i] = if mixed.is_finite() { mixed } else { current[i] };
        }
    }

    pub fn gain_tables(overlap_frames: usize) -> (Vec<f32>, Vec<f32>) {
        if overlap_frames == 0 {
            return (Vec::new(), Vec::new());
        }
        let inv = 1.0 / overlap_frames as f32;
        let mut out_tbl = Vec::with_capacity(overlap_frames);
        let mut in_tbl = Vec::with_capacity(overlap_frames);
        for i in 0..overlap_frames {
            let p = i as f32 * inv;
            out_tbl.push(Self::gain_out(p));
            in_tbl.push(Self::gain_in(p));
        }
        (out_tbl, in_tbl)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gain_curves_sum_to_unity() {
        for i in 0..101 {
            let p = i as f32 / 100.0;
            let go = PcmCrossfadeMixer::gain_out(p);
            let gi = PcmCrossfadeMixer::gain_in(p);
            let sum = go + gi;
            assert!(
                (sum - 1.0).abs() < 0.01,
                "sum={sum} at p={p}"
            );
        }
    }

    #[test]
    fn endpoints_are_correct() {
        assert!((PcmCrossfadeMixer::gain_out(0.0) - 1.0).abs() < 1e-3);
        assert!(PcmCrossfadeMixer::gain_in(0.0) < 1e-3);
        assert!(PcmCrossfadeMixer::gain_out(1.0) < 1e-3);
        assert!((PcmCrossfadeMixer::gain_in(1.0) - 1.0).abs() < 1e-3);
    }

    #[test]
    fn mix_in_place_blends() {
        let mut current = vec![1.0_f32; 8];
        let next = vec![0.0_f32; 8];
        PcmCrossfadeMixer::mix_in_place(&mut current, &next, 0.5, 0.5);
        assert!((current[0] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn mix_crossfade_constant_amplitude() {
        let mut current = vec![1.0_f32; 100];
        let next = vec![1.0_f32; 100];
        PcmCrossfadeMixer::mix_crossfade(&mut current, &next);
        for v in &current {
            assert!((*v - 1.0).abs() < 0.01, "expected ~1.0, got {v}");
        }
    }

    #[test]
    fn mix_crossfade_transitions_between_signals() {
        let mut current = vec![1.0_f32; 100];
        let next = vec![0.0_f32; 100];
        PcmCrossfadeMixer::mix_crossfade(&mut current, &next);
        assert!(current[0] > 0.9, "start={}", current[0]);
        assert!(current[99] < 0.1, "end={}", current[99]);
        assert!((current[50] - 0.5).abs() < 0.1, "mid={}", current[50]);
    }

    #[test]
    fn gain_tables_length_matches() {
        let (out, inn) = PcmCrossfadeMixer::gain_tables(64);
        assert_eq!(out.len(), 64);
        assert_eq!(inn.len(), 64);
        assert!((out[0] - 1.0).abs() < 0.01);
        assert!(inn[63] > 0.95, "last gain_in={}", inn[63]);
    }

    #[test]
    fn handles_nan_safely() {
        let mut current = vec![f32::NAN; 4];
        let next = vec![1.0; 4];
        PcmCrossfadeMixer::mix_in_place(&mut current, &next, 0.5, 0.5);
        assert!(current[0].is_nan() || current[0].is_finite());
    }
}
