
use serde::{Deserialize, Serialize};

#[cfg(target_os = "android")]
pub(crate) mod android_aaudio;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExclusivePlayRequest {
    pub path: String,
    pub device_id: i32,
    pub volume: f32,
    pub start_time_secs: f64,
    pub is_playing: bool,
    pub volume_balance_gain: f32,
    pub equalizer_settings_json: String,
    pub sound_effect_settings_json: String,
    pub bit_perfect: bool,
    pub dsd_native_passthrough: bool,
    #[serde(default)]
    pub shared_mode: bool,
}

// =========================================================================
// 跨平台 API（非 Android 为桩实现）
// =========================================================================

pub fn start_exclusive_playback(request: ExclusivePlayRequest) -> Result<String, String> {
    #[cfg(target_os = "android")]
    {
        android_aaudio::start_exclusive_playback(request)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = request;
        Err("USB 独占模式仅在 Android 端可用".to_string())
    }
}

pub fn stop_exclusive_playback() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::stop_exclusive_playback();
    }
}

pub fn seek_exclusive(time_secs: f64, is_playing: bool) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::seek_exclusive(time_secs, is_playing);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (time_secs, is_playing);
    }
}

pub fn pause_exclusive() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::pause_exclusive();
    }
}

pub fn resume_exclusive() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::resume_exclusive();
    }
}

pub fn set_exclusive_volume(volume: f32) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_volume(volume);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = volume;
    }
}

pub fn set_exclusive_volume_balance_gain(gain: f32) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_volume_balance_gain(gain);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = gain;
    }
}

pub fn set_exclusive_equalizer(settings_json: String) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_equalizer(&settings_json)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = settings_json;
        Ok(())
    }
}

pub fn set_exclusive_sound_effect(settings_json: String) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_sound_effect(&settings_json)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = settings_json;
        Ok(())
    }
}

pub fn set_exclusive_bit_perfect(enabled: bool) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_bit_perfect(enabled);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = enabled;
    }
}

pub fn is_exclusive_bit_perfect() -> bool {
    #[cfg(target_os = "android")]
    {
        android_aaudio::is_exclusive_bit_perfect()
    }
    #[cfg(not(target_os = "android"))]
    {
        false
    }
}

pub fn is_exclusive_active() -> bool {
    #[cfg(target_os = "android")]
    {
        android_aaudio::is_exclusive_active()
    }
    #[cfg(not(target_os = "android"))]
    {
        false
    }
}

pub fn get_exclusive_position_secs() -> f64 {
    #[cfg(target_os = "android")]
    {
        android_aaudio::get_exclusive_position_secs()
    }
    #[cfg(not(target_os = "android"))]
    {
        0.0
    }
}

pub fn get_exclusive_sample_rate() -> u32 {
    #[cfg(target_os = "android")]
    {
        android_aaudio::get_exclusive_sample_rate()
    }
    #[cfg(not(target_os = "android"))]
    {
        0
    }
}

pub fn get_exclusive_device_info() -> String {
    #[cfg(target_os = "android")]
    {
        android_aaudio::get_exclusive_device_info()
    }
    #[cfg(not(target_os = "android"))]
    {
        serde_json::json!({
            "active": false,
            "deviceName": "",
            "sampleRate": 0,
            "channels": 0,
            "bitPerfect": false,
        })
        .to_string()
    }
}

pub fn get_exclusive_channels() -> u16 {
    #[cfg(target_os = "android")]
    {
        android_aaudio::get_exclusive_channels()
    }
    #[cfg(not(target_os = "android"))]
    {
        0
    }
}
