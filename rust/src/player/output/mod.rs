//! Android AAudio 共享模式音频输出模块。
//!
//! 共享流走系统混音器，承接全效果链 DSP 管线（手表音效页/蓝牙同步手机音效）。
//!
//! 仅在 `target_os = "android"` 编译；其他平台提供桩函数返回不支持。

use serde::{Deserialize, Serialize};

#[cfg(target_os = "android")]
pub(crate) mod android_aaudio;

/// DSP 管线播放启动请求。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExclusivePlayRequest {
    /// 本地文件路径或流缓存直链 URL
    pub path: String,
    /// 初始音量 0.0–1.0
    pub volume: f32,
    /// 起始播放位置（秒）
    pub start_time_secs: f64,
    /// true = 启动即播放；false = 暂停等待 resume
    pub is_playing: bool,
    /// 音量平衡增益（响度归一化，1.0 = 不变）
    pub volume_balance_gain: f32,
    /// EQ 设置 JSON（camelCase），空串 = 默认
    pub equalizer_settings_json: String,
    /// 音效设置 JSON（camelCase），空串 = 默认
    pub sound_effect_settings_json: String,
    /// 在线流缓存直读 URL：Some(url) 时解码输入经 Rust 流缓存 Reader
    /// （复用/启动 `start_streaming_download` 下载线程，单上游连接），
    /// 对齐桌面端 StreamingTempFile 模型；`path` 字段此时仅作扩展名探测。
    #[serde(default)]
    pub stream_cache_url: Option<String>,
    /// 流缓存直链的上游请求头（Referer/User-Agent/Cookie 等），
    /// 供 `start_streaming_download` 冷启动下载使用；命中已预热的缓存
    /// 条目时忽略。
    #[serde(default)]
    pub stream_cache_headers: Option<std::collections::HashMap<String, String>>,
    /// 跳过静音初始开关（Dart 起播后也会用 `set_exclusive_skip_silence`
    /// 下发一次，这里只作为管线启动时的初值）。
    #[serde(default)]
    pub skip_silence_enabled: bool,
    /// 静音判定阈值（dBFS，负值；默认 -45）
    #[serde(default)]
    pub skip_silence_threshold_db: f32,
    /// 静音段保留时长（毫秒；默认 500）
    #[serde(default)]
    pub skip_silence_keep_ms: u32,
}

// =========================================================================
// 跨平台 API（非 Android 为桩实现）
// =========================================================================

/// 启动共享模式 DSP 管线播放。返回设备描述或错误信息。
pub fn start_exclusive_playback(request: ExclusivePlayRequest) -> Result<String, String> {
    #[cfg(target_os = "android")]
    {
        android_aaudio::start_exclusive_playback(request)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = request;
        Err("AAudio DSP 管线仅在 Android 端可用".to_string())
    }
}

/// 停止独占播放并释放设备。
pub fn stop_exclusive_playback() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::stop_exclusive_playback();
    }
}

/// 跳转到指定位置（秒）。`is_playing` 控制跳转后是否恢复播放。
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

/// 暂停独占播放（不改变进度）。
pub fn pause_exclusive() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::pause_exclusive();
    }
}

/// 从暂停恢复独占播放（不改变进度）。
pub fn resume_exclusive() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::resume_exclusive();
    }
}

/// 设置用户音量（0.0–1.0）。
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

/// 运行时更新音量平衡（ReplayGain）目标增益，平滑渐变不中断播放。
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

/// 更新 EQ 设置。
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

/// 更新音效设置。
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

/// 运行时切换跳过静音（开关 + 阈值 dBFS + 保留时长 ms），不需要重启管线。
pub fn set_exclusive_skip_silence(enabled: bool, threshold_db: f32, keep_ms: u32) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_skip_silence(enabled, threshold_db, keep_ms);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (enabled, threshold_db, keep_ms);
    }
}

/// 预排下一首用于无缝拼接（格式不一致/准备失败时退回普通切歌）。
pub fn set_exclusive_next(
    path: String,
    stream_cache_url: Option<String>,
    stream_cache_headers_json: Option<String>,
) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_next(path, stream_cache_url, stream_cache_headers_json);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (path, stream_cache_url, stream_cache_headers_json);
    }
}

/// 取消预排。
pub fn cancel_exclusive_next() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::cancel_exclusive_next();
    }
}

/// 取出并清空管线诊断（seek / 无缝拼接 / 交叉 / 跳过静音等关键事件）。
pub fn take_exclusive_pipeline_diag() -> String {
    #[cfg(target_os = "android")]
    {
        android_aaudio::take_pipeline_diag()
    }
    #[cfg(not(target_os = "android"))]
    {
        String::new()
    }
}

/// 设置曲间交叉淡入淡出时长（毫秒，0 = 关闭）。
pub fn set_exclusive_crossfade(ms: u32) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_crossfade(ms);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = ms;
    }
}

/// 独占播放是否活跃。
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

/// 获取当前播放位置（秒）。
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

/// 查询当前独占播放输出设备/格式信息（JSON），用于前端展示已选输出。
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
        })
        .to_string()
    }
}
