#![allow(dead_code)]

pub(crate) use crate::player::buffered_source::{BlockProducer, BufferedSource};
pub(crate) use crate::player::output::ExclusivePlayRequest;
pub(crate) use crate::player::dsd_dop::{parse_dsd_info, DopStreamSource};
pub(crate) use crate::player::equalizer::{
    ClipGuardSource, Equalizer, EqualizerHandle, EqualizerSettings, UserVolumeSource,
};
pub(crate) use crate::player::loudness::VolumeNormalizer;
pub(crate) use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
pub(crate) use crate::player::types::global_visualizer;
pub(crate) use crate::player::qmc2::{looks_like_qmc_encrypted, extract_ekey_from_footer, QmcCrypto, QmcDecryptReader};
pub(crate) use std::io::{Read, Seek, SeekFrom};
pub(crate) use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
pub(crate) use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
pub(crate) use std::sync::{Arc, Mutex, OnceLock};
pub(crate) use std::thread;
pub(crate) use std::time::Duration;

mod decoder;
mod dsd;
mod ffi;
mod playback;
mod stream;

pub use playback::{
    get_exclusive_channels, get_exclusive_device_info, get_exclusive_position_secs,
    get_exclusive_sample_rate, is_exclusive_active, is_exclusive_bit_perfect, pause_exclusive,
    resume_exclusive, seek_exclusive, set_exclusive_bit_perfect, set_exclusive_equalizer,
    set_exclusive_sound_effect, set_exclusive_volume, set_exclusive_volume_balance_gain,
    start_exclusive_playback, stop_exclusive_playback,
};
pub(crate) use decoder::*;
pub(crate) use dsd::*;
pub(crate) use ffi::*;
pub(crate) use playback::*;
pub(crate) use stream::*;

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_sample_bytes_float32_roundtrip() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 0.5, DeviceFormat::Float32);
        assert_eq!(buf.len(), 4);
        let val = f32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        assert!((val - 0.5).abs() < 1e-6);
    }

    #[test]
    fn push_sample_bytes_int16_range() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 1.0, DeviceFormat::Int16);
        let val = i16::from_le_bytes([buf[0], buf[1]]);
        assert_eq!(val, 32767);

        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, -1.0, DeviceFormat::Int16);
        let val = i16::from_le_bytes([buf[0], buf[1]]);
        assert_eq!(val, -32767);
    }

    #[test]
    fn push_sample_bytes_clamps_overflow() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 2.0, DeviceFormat::Float32);
        let val = f32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        assert!((val - 1.0).abs() < 1e-6);
    }

    #[test]
    fn device_format_bytes_per_sample() {
        assert_eq!(DeviceFormat::Float32.bytes_per_sample(), 4);
        assert_eq!(DeviceFormat::Int16.bytes_per_sample(), 2);
    }
}
