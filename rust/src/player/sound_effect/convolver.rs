
#![allow(dead_code)]

use rustfft::num_complex::Complex;
use rustfft::{Fft, FftPlanner};
use std::sync::Arc;

const MAX_IR_FRAMES: usize = 32768;
const MAX_STREAM_CHANNELS: usize = 8;

#[derive(Clone, Copy, PartialEq, Debug)]
enum RoutingMode {
    SharedDiagonal,
    PerChannelDiagonal,
    FullMatrix,
}

pub struct ConvolverKernel {
    sample_rate: u32,
    stream_channels: usize,
    ir_frames: usize,
    ir_channels: usize,
    partition_size: usize,
    fft_size: usize,
    partition_count: usize,
    routing: RoutingMode,
    spectra: Vec<Complex<f32>>,
    fft: Arc<dyn Fft<f32>>,
    ifft: Arc<dyn Fft<f32>>,
}

impl ConvolverKernel {
    pub fn new(
        interleaved_ir: &[f32],
        ir_frames: usize,
        ir_channels: usize,
        sample_rate: u32,
        stream_channels: usize,
    ) -> Option<Self> {
        if ir_frames == 0 || ir_channels == 0 || sample_rate == 0 {
            return None;
        }
        let ir_frames = ir_frames.min(MAX_IR_FRAMES);
        let stream_channels = stream_channels.clamp(1, MAX_STREAM_CHANNELS);

        let routing = if ir_channels == 1 {
            RoutingMode::SharedDiagonal
        } else if ir_channels == stream_channels {
            RoutingMode::PerChannelDiagonal
        } else {
            RoutingMode::FullMatrix
        };

        let path_count = match routing {
            RoutingMode::SharedDiagonal => 1,
            RoutingMode::PerChannelDiagonal => stream_channels,
            RoutingMode::FullMatrix => stream_channels * stream_channels,
        };

        let partition_size = Self::choose_partition_size(ir_frames, path_count);
        let fft_size = partition_size * 2;
        let partition_count = (ir_frames + partition_size - 1) / partition_size;

        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(fft_size);
        let ifft = planner.plan_fft_inverse(fft_size);

        let mut spectra = vec![Complex::new(0.0, 0.0); path_count * partition_count * fft_size];

        for path in 0..path_count {
            for part in 0..partition_count {
                let mut buf = vec![Complex::new(0.0, 0.0); fft_size];
                let start = part * partition_size;
                let end = (start + partition_size).min(ir_frames);
                for frame in start..end {
                    let ir_idx = match routing {
                        RoutingMode::SharedDiagonal => frame,
                        RoutingMode::PerChannelDiagonal => frame * ir_channels + path % ir_channels,
                        RoutingMode::FullMatrix => {
                            let in_ch = path / stream_channels;
                            let out_ch = path % stream_channels;
                            let ir_ch = if in_ch == out_ch && out_ch < ir_channels {
                                out_ch
                            } else {
                                in_ch.min(ir_channels - 1)
                            };
                            frame * ir_channels + ir_ch
                        }
                    };
                    if ir_idx < interleaved_ir.len() {
                        buf[frame - start] = Complex::new(interleaved_ir[ir_idx], 0.0);
                    }
                }
                fft.process(&mut buf);
                let offset = (path * partition_count + part) * fft_size;
                spectra[offset..offset + fft_size].copy_from_slice(&buf);
            }
        }

        Some(Self {
            sample_rate,
            stream_channels,
            ir_frames,
            ir_channels,
            partition_size,
            fft_size,
            partition_count,
            routing,
            spectra,
            fft,
            ifft,
        })
    }

    fn choose_partition_size(ir_frames: usize, path_count: usize) -> usize {
        if path_count > 2 {
            if ir_frames <= 2048 {
                return 512;
            }
            if ir_frames <= 8192 {
                return 1024;
            }
            return 2048;
        }
        if ir_frames <= 2048 {
            return 256;
        }
        if ir_frames <= 8192 {
            return 512;
        }
        1024
    }

    #[inline]
    fn spectrum_offset(&self, path: usize, partition: usize) -> usize {
        (path * self.partition_count + partition) * self.fft_size
    }

    #[inline]
    fn path_for(&self, input_channel: usize, output_channel: usize) -> isize {
        match self.routing {
            RoutingMode::SharedDiagonal => {
                if input_channel == output_channel {
                    0
                } else {
                    -1
                }
            }
            RoutingMode::PerChannelDiagonal => {
                if input_channel == output_channel {
                    output_channel as isize
                } else {
                    -1
                }
            }
            RoutingMode::FullMatrix => (input_channel * self.stream_channels + output_channel) as isize,
        }
    }

    pub fn latency_frames(&self) -> usize {
        self.partition_size
    }

    pub fn ir_frames(&self) -> usize {
        self.ir_frames
    }

    pub fn stream_channels(&self) -> usize {
        self.stream_channels
    }
}

pub struct Convolver {
    kernel: Option<Arc<ConvolverKernel>>,
    pending_input: Vec<f32>,
    pending_frames: usize,
    input_history: Vec<Complex<f32>>,
    write_partition: usize,
    overlap: Vec<f32>,
    wet_block: Vec<f32>,
    fft_input: Vec<Complex<f32>>,
    fft_output: Vec<Complex<f32>>,
    enabled: bool,
    activation_mix: f32,
    wet: f32,
    dry: f32,
    gain_linear: f32,
    predelay_frames: usize,
    wet_delay: Vec<f32>,
    wet_delay_write_frame: usize,
    max_predelay_frames: usize,
    limiter_gain: f32,
    limiter_release: f32,
}

impl Convolver {
    pub fn new() -> Self {
        Self {
            kernel: None,
            pending_input: Vec::new(),
            pending_frames: 0,
            input_history: Vec::new(),
            write_partition: 0,
            overlap: Vec::new(),
            wet_block: Vec::new(),
            fft_input: Vec::new(),
            fft_output: Vec::new(),
            enabled: false,
            activation_mix: 0.0,
            wet: 1.0,
            dry: 0.0,
            gain_linear: 1.0,
            predelay_frames: 0,
            wet_delay: Vec::new(),
            wet_delay_write_frame: 0,
            max_predelay_frames: 1,
            limiter_gain: 1.0,
            limiter_release: 0.0,
        }
    }

    pub fn load_kernel(&mut self, kernel: Arc<ConvolverKernel>) {
        let ch = kernel.stream_channels;
        let block = kernel.partition_size;
        let fft_size = kernel.fft_size;
        let partitions = kernel.partition_count;

        self.pending_input = vec![0.0; block * ch];
        self.input_history = vec![Complex::new(0.0, 0.0); ch * partitions * fft_size];
        self.overlap = vec![0.0; ch * block];
        self.wet_block = vec![0.0; ch * block];
        self.fft_input = vec![Complex::new(0.0, 0.0); fft_size];
        self.fft_output = vec![Complex::new(0.0, 0.0); fft_size];

        self.max_predelay_frames = (kernel.sample_rate as usize / 2 + 1).max(1);
        self.wet_delay = vec![0.0; self.max_predelay_frames * ch];
        self.limiter_release =
            1.0 - (-1.0 / (0.160 * kernel.sample_rate.max(8000) as f32)).exp();

        self.kernel = Some(kernel);
        self.reset_state();
    }

    pub fn clear_kernel(&mut self) {
        self.kernel = None;
        self.enabled = false;
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn is_ready(&self) -> bool {
        self.kernel.is_some()
    }

    pub fn set_wet_dry(&mut self, wet: f32, dry: f32) {
        self.wet = wet.clamp(0.0, 2.0);
        self.dry = dry.clamp(0.0, 2.0);
    }

    pub fn set_gain_db(&mut self, gain_db: f32) {
        self.gain_linear = 10.0_f32.powf(gain_db / 20.0);
    }

    pub fn set_predelay_ms(&mut self, ms: f32) {
        if let Some(k) = &self.kernel {
            let safe_ms = ms.clamp(0.0, 500.0);
            self.predelay_frames =
                (safe_ms * k.sample_rate.max(8000) as f32 / 1000.0).round() as usize;
        }
    }

    pub fn reset_state(&mut self) {
        if self.kernel.is_some() {
            self.pending_input.fill(0.0);
            self.input_history.fill(Complex::new(0.0, 0.0));
            self.overlap.fill(0.0);
            self.wet_block.fill(0.0);
            self.wet_delay.fill(0.0);
        }
        self.pending_frames = 0;
        self.write_partition = 0;
        self.wet_delay_write_frame = 0;
        self.activation_mix = 0.0;
        self.limiter_gain = 1.0;
    }

    #[inline]
    fn input_spectrum_offset(&self, channel: usize, partition: usize) -> usize {
        let k = self.kernel.as_ref().unwrap();
        (channel * k.partition_count + partition) * k.fft_size
    }

    pub fn process(&mut self, interleaved: &mut [f32], num_frames: usize) {
        let kernel = match &self.kernel {
            Some(k) => k.clone(),
            None => return,
        };
        let ch = kernel.stream_channels;
        let block = kernel.partition_size;

        let target = if self.enabled { 1.0 } else { 0.0 };
        let activation_step = 1.0 / (kernel.sample_rate as f32 * 0.08).max(1.0);

        for frame in 0..num_frames {
            for c in 0..ch {
                let idx = frame * ch + c;
                if idx < interleaved.len() {
                    let pidx = self.pending_frames * ch + c;
                    if pidx < self.pending_input.len() {
                        self.pending_input[pidx] = interleaved[idx];
                    }
                }
            }
            self.pending_frames += 1;

            if self.pending_frames < block {
                continue;
            }

            self.process_block(&kernel);
            self.pending_frames = 0;

        }

        let processed_blocks = (num_frames + block - 1) / block;
        let _ = processed_blocks;

        for frame in 0..num_frames {
            let block_idx = frame / block;
            let in_block = frame % block;

            if self.activation_mix < target {
                self.activation_mix = (self.activation_mix + activation_step).min(target);
            } else if self.activation_mix > target {
                self.activation_mix = (self.activation_mix - activation_step).max(target);
            }

            for c in 0..ch {
                let idx = frame * ch + c;
                if idx >= interleaved.len() {
                    break;
                }
                let dry_sample = interleaved[idx];

                let wet_idx = block_idx * block * ch + in_block * ch + c;
                let current_wet = if wet_idx < self.wet_block.len() {
                    self.wet_block[wet_idx]
                } else {
                    0.0
                };

                let delayed_wet = if self.predelay_frames > 0 {
                    let read_frame = if self.wet_delay_write_frame >= self.predelay_frames {
                        self.wet_delay_write_frame - self.predelay_frames
                    } else {
                        self.max_predelay_frames + self.wet_delay_write_frame
                            - self.predelay_frames
                    };
                    let read_idx = read_frame * ch + c;
                    if read_idx < self.wet_delay.len() {
                        self.wet_delay[read_idx]
                    } else {
                        current_wet
                    }
                } else {
                    current_wet
                };

                let write_idx = self.wet_delay_write_frame * ch + c;
                if write_idx < self.wet_delay.len() {
                    self.wet_delay[write_idx] = current_wet;
                }

                let limited_wet = self.apply_limiter(delayed_wet);

                let mix = self.activation_mix;
                let out = dry_sample * self.dry * (1.0 - mix)
                    + limited_wet * self.wet * self.gain_linear * mix;

                interleaved[idx] = if out.is_finite() { out } else { dry_sample };
            }

            self.wet_delay_write_frame =
                (self.wet_delay_write_frame + 1) % self.max_predelay_frames.max(1);
        }
    }

    fn process_block(&mut self, kernel: &ConvolverKernel) {
        let ch = kernel.stream_channels;
        let block = kernel.partition_size;
        let fft_size = kernel.fft_size;
        let partitions = kernel.partition_count;
        let slot = self.write_partition;

        for input_channel in 0..ch {
            self.fft_input.fill(Complex::new(0.0, 0.0));
            for frame in 0..block {
                let idx = frame * ch + input_channel;
                if idx < self.pending_input.len() {
                    self.fft_input[frame] = Complex::new(self.pending_input[idx], 0.0);
                }
            }
            kernel.fft.process(&mut self.fft_input);
            let dest = self.input_spectrum_offset(input_channel, slot);
            if dest + fft_size <= self.input_history.len() {
                self.input_history[dest..dest + fft_size].copy_from_slice(&self.fft_input);
            }
        }

        for output_channel in 0..ch {
            self.fft_output.fill(Complex::new(0.0, 0.0));

            for input_channel in 0..ch {
                let path = kernel.path_for(input_channel, output_channel);
                if path < 0 {
                    continue;
                }
                let path = path as usize;

                for partition in 0..partitions {
                    let history_slot = (slot + partitions - partition) % partitions;
                    let x_off = self.input_spectrum_offset(input_channel, history_slot);
                    let h_off = kernel.spectrum_offset(path, partition);

                    for bin in 0..fft_size {
                        if x_off + bin < self.input_history.len()
                            && h_off + bin < kernel.spectra.len()
                        {
                            let x = self.input_history[x_off + bin];
                            let h = kernel.spectra[h_off + bin];
                            self.fft_output[bin] += Complex::new(
                                x.re * h.re - x.im * h.im,
                                x.re * h.im + x.im * h.re,
                            );
                        }
                    }
                }
            }

            kernel.ifft.process(&mut self.fft_output);

            let overlap_off = output_channel * block;
            for frame in 0..block {
                let convolved = if frame + overlap_off < self.overlap.len()
                    && frame < self.fft_output.len()
                {
                    self.fft_output[frame].re + self.overlap[overlap_off + frame]
                } else {
                    0.0
                };
                let wet_idx = frame * ch + output_channel;
                if wet_idx < self.wet_block.len() {
                    self.wet_block[wet_idx] = if convolved.is_finite() {
                        convolved * self.gain_linear
                    } else {
                        0.0
                    };
                }
                let tail = frame + block;
                if tail < self.fft_output.len() && overlap_off + frame < self.overlap.len() {
                    self.overlap[overlap_off + frame] =
                        if self.fft_output[tail].re.is_finite() {
                            self.fft_output[tail].re
                        } else {
                            0.0
                        };
                }
            }
        }

        self.write_partition = (self.write_partition + 1) % partitions.max(1);
    }

    #[inline]
    fn apply_limiter(&mut self, sample: f32) -> f32 {
        if !sample.is_finite() {
            return 0.0;
        }
        let abs_s = sample.abs();
        if abs_s > 0.95 {
            let over = abs_s / 0.95;
            let target_gain = 0.95 / over;
            if target_gain < self.limiter_gain {
                self.limiter_gain = target_gain;
            }
        }
        self.limiter_gain = self.limiter_gain
            + (1.0 - self.limiter_gain) * self.limiter_release;
        sample * self.limiter_gain
    }
}

impl Default for Convolver {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kernel_from_short_ir() {
        let ir = vec![1.0_f32, 0.0, 0.0, 0.0];
        let k = ConvolverKernel::new(&ir, 4, 1, 44100, 2);
        assert!(k.is_some());
        let k = k.unwrap();
        assert!(k.partition_size >= 256);
        assert!(k.partition_count >= 1);
    }

    #[test]
    fn convolver_passes_through_without_kernel() {
        let mut conv = Convolver::new();
        let mut pcm = vec![0.5_f32, 0.3, 0.5, 0.3];
        conv.process(&mut pcm, 2);
        assert!((pcm[0] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn convolver_disabled_outputs_dry() {
        let ir = vec![1.0_f32; 512];
        let k = ConvolverKernel::new(&ir, 512, 1, 44100, 2).unwrap();
        let mut conv = Convolver::new();
        conv.load_kernel(Arc::new(k));
        conv.set_enabled(false);
        conv.set_wet_dry(1.0, 0.0);
        let mut pcm = vec![0.5_f32; 512 * 2];
        conv.process(&mut pcm, 512);
        let max_val = pcm.iter().cloned().fold(0.0_f32, f32::max);
        assert!(max_val < 0.01, "disabled convolver should be near-silent, got {max_val}");
    }
}
