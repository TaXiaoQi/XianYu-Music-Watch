//! AAudio 流创建与格式协商：共享模式 Float32/Int16 协商与实际格式回读。

use super::*;

/// 协商创建 AAudio 共享流（走系统混音器，输出到当前默认设备）：
/// 先试 Float32 失败再试 Int16，按实际协商出的格式回读。
pub(crate) fn create_aaudio_stream(
    lib: &AAudioLib,
    sample_rate: u32,
    channels: u16,
) -> Result<(*mut AAudioStream, DeviceFormat, u32, u16), String> {
    let formats = [DeviceFormat::Float32, DeviceFormat::Int16];

    for &fmt in &formats {
        let stream = unsafe { try_open_stream(lib, sample_rate, channels, fmt) };
        match stream {
            Ok(s) => {
                let actual_rate = unsafe { (lib.stream_get_sample_rate)(s) } as u32;
                let actual_channels = unsafe { (lib.stream_get_channel_count)(s) } as u16;
                // 共享模式下系统可能重协商格式，按实际格式回读供字节转换使用。
                let actual_fmt = match device_format_of(unsafe { (lib.stream_get_format)(s) }) {
                    Some(f) => f,
                    None => {
                        unsafe { (lib.stream_close)(s) };
                        continue;
                    }
                };
                return Ok((s, actual_fmt, actual_rate, actual_channels));
            }
            Err(_e) => continue,
        }
    }

    Err("无法创建 AAudio 共享流（需要 Android API 26+）".to_string())
}

pub(crate) unsafe fn try_open_stream(
    lib: &AAudioLib,
    sample_rate: u32,
    channels: u16,
    fmt: DeviceFormat,
) -> Result<*mut AAudioStream, String> {
    let mut builder: *mut AAudioStreamBuilder = std::ptr::null_mut();
    let result = (lib.create_stream_builder)(&mut builder);
    if result != AAUDIO_OK || builder.is_null() {
        return Err(lib.result_text(result));
    }

    (lib.builder_set_direction)(builder, AAUDIO_DIRECTION_OUTPUT);
    (lib.builder_set_sample_rate)(builder, sample_rate as i32);
    (lib.builder_set_channel_count)(builder, channels as i32);
    (lib.builder_set_format)(builder, fmt.aaudio_format());
    // 共享模式走系统混音器：不设性能档（默认 NONE，省电）。
    (lib.builder_set_sharing_mode)(builder, AAUDIO_SHARING_MODE_SHARED);
    (lib.builder_set_buffer_capacity)(builder, 4096);

    let mut stream: *mut AAudioStream = std::ptr::null_mut();
    let result = (lib.builder_open_stream)(builder, &mut stream);
    (lib.builder_delete)(builder);

    if result != AAUDIO_OK || stream.is_null() {
        return Err(lib.result_text(result));
    }

    // 共享模式允许系统重协商格式，由调用方按实际格式回读
    Ok(stream)
}

/// AAudio 格式常量 → 管线字节转换格式；未知格式返回 None。
pub(crate) fn device_format_of(format: i32) -> Option<DeviceFormat> {
    match format {
        AAUDIO_FORMAT_PCM_FLOAT => Some(DeviceFormat::Float32),
        AAUDIO_FORMAT_PCM_I16 => Some(DeviceFormat::Int16),
        AAUDIO_FORMAT_PCM_I24_PACKED => Some(DeviceFormat::I24Packed),
        _ => None,
    }
}
