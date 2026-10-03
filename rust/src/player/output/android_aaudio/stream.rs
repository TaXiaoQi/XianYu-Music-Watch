use super::*;

pub(crate) fn create_aaudio_stream(
    lib: &AAudioLib,
    device_id: i32,
    sample_rate: u32,
    channels: u16,
    shared: bool,
) -> Result<(*mut AAudioStream, DeviceFormat, u32, u16), String> {
    let formats = [DeviceFormat::Float32, DeviceFormat::Int16];

    for &fmt in &formats {
        let stream =
            unsafe { try_open_stream(lib, device_id, sample_rate, channels, fmt, shared) };
        match stream {
            Ok(s) => {
                let actual_rate = unsafe { (lib.stream_get_sample_rate)(s) } as u32;
                let actual_channels = unsafe { (lib.stream_get_channel_count)(s) } as u16;
                let actual_fmt = if shared {
                    device_format_of(unsafe { (lib.stream_get_format)(s) })
                } else {
                    Some(fmt)
                };
                let actual_fmt = match actual_fmt {
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

    Err(if shared {
        "无法创建 AAudio 共享流（需要 Android API 26+）".to_string()
    } else {
        "无法创建 AAudio 独占流（设备不支持独占模式或已被占用）".to_string()
    })
}

pub(crate) fn create_aaudio_stream_bitperfect(
    lib: &AAudioLib,
    device_id: i32,
    sample_rate: u32,
    channels: u16,
    source_depth: Option<u8>,
) -> Result<(*mut AAudioStream, DeviceFormat, u32, u16), String> {
    let preferred: DeviceFormat = match source_depth {
        Some(d) if d <= 16 => DeviceFormat::Int16,
        Some(_) => DeviceFormat::I24Packed,
        None => DeviceFormat::Int16,
    };

    let mut attempts: Vec<DeviceFormat> = vec![preferred];
    for f in [DeviceFormat::Int16, DeviceFormat::I24Packed, DeviceFormat::Float32] {
        if f != preferred && !attempts.contains(&f) {
            attempts.push(f);
        }
    }

    for &fmt in &attempts {
        let stream =
            unsafe { try_open_stream(lib, device_id, sample_rate, channels, fmt, false) };
        match stream {
            Ok(s) => {
                let actual_rate = unsafe { (lib.stream_get_sample_rate)(s) } as u32;
                let actual_channels = unsafe { (lib.stream_get_channel_count)(s) } as u16;
                return Ok((s, fmt, actual_rate, actual_channels));
            }
            Err(_e) => continue,
        }
    }

    Err("无法创建 AAudio 独占流（设备不支持独占/整数格式）".to_string())
}

pub(crate) fn probe_source_bit_depth(path: &str) -> Option<u8> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).ok()?;
    let mut head = [0u8; 64];
    let n = file.read(&mut head).ok()?;
    let head = &head[..n];
    if head.len() < 12 {
        return None;
    }

    if head.starts_with(b"fLaC") {
        if head.len() < 18 {
            return None;
        }
        let mut u = 0u64;
        for &b in &head[12..18] {
            u = (u << 8) | b as u64;
        }
        let bits = ((u >> 23) & 0x1F) as u8 + 1;
        return Some(bits);
    }

    if head.starts_with(b"RIFF") && &head[8..12] == b"WAVE" {
        let mut off = 12usize;
        while off + 8 <= head.len() {
            if &head[off..off + 4] == b"fmt " {
                let data = off + 8;
                if data + 16 <= head.len() {
                    let bits = u16::from_le_bytes([head[data + 14], head[data + 15]]);
                    return Some(bits as u8);
                }
                return None;
            }
            let size = u32::from_le_bytes([
                head[off + 4],
                head[off + 5],
                head[off + 6],
                head[off + 7],
            ]) as usize;
            off += 8 + size + (size & 1);
        }
        return None;
    }

    if head.starts_with(b"FORM") && &head[8..12] == b"AIFF" {
        let mut off = 12usize;
        while off + 8 <= head.len() {
            let chunk = &head[off..off + 4];
            let size = u32::from_be_bytes([
                head[off + 4],
                head[off + 5],
                head[off + 6],
                head[off + 7],
            ]) as usize;
            if chunk == b"COMM" {
                if off + 8 + 4 > head.len() {
                    return None;
                }
                let bits = u16::from_be_bytes([head[off + 12], head[off + 13]]);
                return Some(bits as u8);
            }
            off += 8 + size + (size & 1);
        }
        return None;
    }

    None
}

pub(crate) unsafe fn try_open_stream(
    lib: &AAudioLib,
    device_id: i32,
    sample_rate: u32,
    channels: u16,
    fmt: DeviceFormat,
    shared: bool,
) -> Result<*mut AAudioStream, String> {
    let mut builder: *mut AAudioStreamBuilder = std::ptr::null_mut();
    let result = (lib.create_stream_builder)(&mut builder);
    if result != AAUDIO_OK || builder.is_null() {
        return Err(lib.result_text(result));
    }

    (lib.builder_set_direction)(builder, AAUDIO_DIRECTION_OUTPUT);
    if device_id >= 0 {
        (lib.builder_set_device_id)(builder, device_id);
    }
    (lib.builder_set_sample_rate)(builder, sample_rate as i32);
    (lib.builder_set_channel_count)(builder, channels as i32);
    (lib.builder_set_format)(builder, fmt.aaudio_format());
    if shared {
        (lib.builder_set_sharing_mode)(builder, AAUDIO_SHARING_MODE_SHARED);
    } else {
        (lib.builder_set_sharing_mode)(builder, AAUDIO_SHARING_MODE_EXCLUSIVE);
        (lib.builder_set_performance_mode)(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    }
    (lib.builder_set_buffer_capacity)(builder, 4096);

    let mut stream: *mut AAudioStream = std::ptr::null_mut();
    let result = (lib.builder_open_stream)(builder, &mut stream);
    (lib.builder_delete)(builder);

    if result != AAUDIO_OK || stream.is_null() {
        return Err(lib.result_text(result));
    }

    let actual_format = (lib.stream_get_format)(stream);
    if !shared && actual_format != fmt.aaudio_format() {
        (lib.stream_close)(stream);
        return Err("设备拒绝了请求的格式".to_string());
    }

    Ok(stream)
}

fn device_format_of(format: i32) -> Option<DeviceFormat> {
    match format {
        AAUDIO_FORMAT_PCM_FLOAT => Some(DeviceFormat::Float32),
        AAUDIO_FORMAT_PCM_I16 => Some(DeviceFormat::Int16),
        AAUDIO_FORMAT_PCM_I24_PACKED => Some(DeviceFormat::I24Packed),
        _ => None,
    }
}
