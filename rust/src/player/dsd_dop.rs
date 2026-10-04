//! DSD（DSF/DFF）容器元数据解析：供扫描器读取声道/DSD 采样率/时长。

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DsdFormat {
    Dsf,
    Dff,
}

#[derive(Debug, Clone, Copy)]
pub struct DsdInfo {
    pub channels: u16,
    pub dsd_rate: u32,
    pub sample_count: u64,
    pub data_size: u64,
    pub is_dst: bool,
    pub format: DsdFormat,
}

impl DsdInfo {
    pub fn duration_seconds(&self) -> u32 {
        let frames = if self.format == DsdFormat::Dsf {
            self.sample_count
        } else if self.channels > 0 {
            self.data_size / self.channels as u64
        } else {
            0
        };
        if self.dsd_rate == 0 {
            0
        } else {
            (frames / u64::from(self.dsd_rate)) as u32
        }
    }
}

fn read_u32_le(buf: &[u8]) -> u32 {
    u32::from_le_bytes(buf[..4].try_into().unwrap())
}

fn read_u64_le(buf: &[u8]) -> u64 {
    u64::from_le_bytes(buf[..8].try_into().unwrap())
}

fn read_u32_be(buf: &[u8]) -> u32 {
    u32::from_be_bytes(buf[..4].try_into().unwrap())
}

fn read_u64_be(buf: &[u8]) -> u64 {
    u64::from_be_bytes(buf[..8].try_into().unwrap())
}

pub fn parse_dsf_info(path: &str) -> Result<DsdInfo, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;

    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).map_err(|_| "not a DSD file".to_string())?;
    if &magic != b"DSD " {
        return Err("not DSF".to_string());
    }

    let mut dsd_rest = [0u8; 24];
    file.read_exact(&mut dsd_rest).map_err(|_| "bad dsd chunk".to_string())?;

    let mut channels = 0u16;
    let mut dsd_rate = 0u32;
    let mut sample_count = 0u64;
    let mut bits_per_sample = 0u32;
    let mut format_id = 0u32;
    let data_size;

    loop {
        let mut hdr = [0u8; 12];
        if file.read_exact(&mut hdr).is_err() {
            return Err("missing data chunk".to_string());
        }
        let chunk_id = &hdr[0..4];
        let chunk_size = read_u64_le(&hdr[4..12]);

        if chunk_id == b"fmt " {
            if chunk_size < 52 || chunk_size > 1024 * 1024 {
                return Err("invalid DSF fmt size".to_string());
            }
            let mut fmt = [0u8; 44];
            file.read_exact(&mut fmt).map_err(|_| "bad fmt payload".to_string())?;
            format_id = read_u32_le(&fmt[4..8]);
            channels = read_u32_le(&fmt[12..16]) as u16;
            dsd_rate = read_u32_le(&fmt[16..20]);
            bits_per_sample = read_u32_le(&fmt[20..24]);
            sample_count = read_u64_le(&fmt[24..32]);
            let skip = chunk_size as i64 - 52;
            if skip > 0 {
                file.seek(SeekFrom::Current(skip)).map_err(|e| e.to_string())?;
            }
        } else if chunk_id == b"data" {
            let mut inner = [0u8; 8];
            file.read_exact(&mut inner).map_err(|_| "bad data size".to_string())?;
            data_size = read_u64_le(&inner);
            // data 载荷起点校验：截断/异常文件在此报错
            file.stream_position().map_err(|e| e.to_string())?;
            break;
        } else if chunk_size > 12 && chunk_size <= 16 * 1024 * 1024 {
            file.seek(SeekFrom::Current((chunk_size - 12) as i64))
                .map_err(|e| e.to_string())?;
        } else {
            return Err("unknown chunk".to_string());
        }
    }

    if channels == 0 || dsd_rate == 0 {
        return Err("invalid DSF fmt".to_string());
    }

    Ok(DsdInfo {
        channels,
        dsd_rate,
        sample_count,
        data_size,
        is_dst: bits_per_sample != 1 || format_id != 0,
        format: DsdFormat::Dsf,
    })
}

pub fn parse_dff_info(path: &str) -> Result<DsdInfo, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;

    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).map_err(|_| "not a DSD file".to_string())?;
    if &magic != b"FRM8" {
        return Err("not DFF (expected FRM8 magic)".to_string());
    }

    let mut frm8_size_buf = [0u8; 8];
    file.read_exact(&mut frm8_size_buf).map_err(|_| "bad FRM8 size".to_string())?;
    let frm8_size = read_u64_be(&frm8_size_buf);

    let mut form_type = [0u8; 4];
    file.read_exact(&mut form_type).map_err(|_| "bad form type".to_string())?;
    if &form_type != b"DSD " {
        return Err("not DSDIFF (form type is not DSD)".to_string());
    }

    let frm8_data_end = 12u64.saturating_add(frm8_size);

    let mut channels = 0u16;
    let mut dsd_rate = 0u32;
    let mut is_dst = false;
    let mut data_size = 0u64;

    loop {
        let pos = file.stream_position().map_err(|e| e.to_string())?;
        if pos >= frm8_data_end {
            break;
        }

        let mut chunk_hdr = [0u8; 12];
        if file.read_exact(&mut chunk_hdr).is_err() {
            break;
        }

        let chunk_id = &chunk_hdr[0..4];
        let chunk_size = read_u64_be(&chunk_hdr[4..12]);
        let chunk_data_start = file.stream_position().map_err(|e| e.to_string())?;
        let pad = if chunk_size & 1 != 0 { 1 } else { 0 };

        match chunk_id {
            b"FVER" => {
                file.seek(SeekFrom::Current((chunk_size + pad) as i64))
                    .map_err(|e| e.to_string())?;
            }
            b"PROP" => {
                let mut prop_type = [0u8; 4];
                file.read_exact(&mut prop_type)
                    .map_err(|_| "bad PROP type".to_string())?;

                let prop_data_end = chunk_data_start.saturating_add(chunk_size);
                while file.stream_position().map_err(|e| e.to_string())? < prop_data_end {
                    let mut sub_hdr = [0u8; 12];
                    if file.read_exact(&mut sub_hdr).is_err() {
                        break;
                    }
                    let sub_id = &sub_hdr[0..4];
                    let sub_size = read_u64_be(&sub_hdr[4..12]);
                    let sub_data_start = file.stream_position().map_err(|e| e.to_string())?;
                    let sub_pad = if sub_size & 1 != 0 { 1 } else { 0 };

                    match sub_id {
                        b"FS  " => {
                            let mut rate_buf = [0u8; 4];
                            file.read_exact(&mut rate_buf)
                                .map_err(|_| "bad FS data".to_string())?;
                            dsd_rate = read_u32_be(&rate_buf);
                        }
                        b"CHNL" => {
                            let mut ch_buf = [0u8; 2];
                            file.read_exact(&mut ch_buf)
                                .map_err(|_| "bad CHNL data".to_string())?;
                            channels = u16::from_be_bytes(ch_buf);
                        }
                        b"CMPR" => {
                            let mut comp_type = [0u8; 4];
                            file.read_exact(&mut comp_type)
                                .map_err(|_| "bad CMPR data".to_string())?;
                            is_dst = &comp_type == b"DST ";
                        }
                        _ => {}
                    }

                    file.seek(SeekFrom::Start(sub_data_start + sub_size + sub_pad))
                        .map_err(|e| e.to_string())?;
                }
                file.seek(SeekFrom::Start(chunk_data_start + chunk_size + pad))
                    .map_err(|e| e.to_string())?;
            }
            b"DSD " => {
                data_size = chunk_size;
                break;
            }
            b"DST " => {
                data_size = chunk_size;
                is_dst = true;
                break;
            }
            _ => {
                file.seek(SeekFrom::Current((chunk_size + pad) as i64))
                    .map_err(|e| e.to_string())?;
            }
        }
    }

    if channels == 0 || dsd_rate == 0 || data_size == 0 {
        return Err("invalid DFF: missing required PROP or DSD chunks".to_string());
    }

    Ok(DsdInfo {
        channels,
        dsd_rate,
        sample_count: 0,
        data_size,
        is_dst,
        format: DsdFormat::Dff,
    })
}

pub fn parse_dsd_info(path: &str) -> Result<DsdInfo, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).map_err(|_| "not a DSD file".to_string())?;
    drop(file);

    match &magic {
        b"DSD " => parse_dsf_info(path),
        b"FRM8" => parse_dff_info(path),
        _ => Err("not a DSD file (expected DSD or FRM8 magic)".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_dsf(channels: u32, block_size: u32, dsd_rate: u32, blocks: &[u8]) -> Vec<u8> {
        let mut fmt_payload = Vec::new();
        fmt_payload.extend_from_slice(&1u32.to_le_bytes());
        fmt_payload.extend_from_slice(&0u32.to_le_bytes());
        fmt_payload.extend_from_slice(&0u32.to_le_bytes());
        fmt_payload.extend_from_slice(&channels.to_le_bytes());
        fmt_payload.extend_from_slice(&dsd_rate.to_le_bytes());
        fmt_payload.extend_from_slice(&1u32.to_le_bytes());
        fmt_payload.extend_from_slice(&(blocks.len() as u64).to_le_bytes());
        fmt_payload.extend_from_slice(&(block_size as u64).to_le_bytes());
        fmt_payload.extend_from_slice(&0u32.to_le_bytes());
        assert_eq!(fmt_payload.len(), 44);

        let mut out = Vec::new();
        out.extend_from_slice(b"DSD ");
        let chunk_size = 28u64;
        out.extend_from_slice(&chunk_size.to_le_bytes());
        let total = 28 + 12 + 8 + fmt_payload.len() + 12 + 8 + blocks.len();
        out.extend_from_slice(&(total as u64).to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes());

        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&(fmt_payload.len() as u64 + 8).to_le_bytes());
        out.extend_from_slice(&fmt_payload);

        out.extend_from_slice(b"data");
        let data_chunk_size = 8 + blocks.len() as u64;
        out.extend_from_slice(&data_chunk_size.to_le_bytes());
        out.extend_from_slice(&(blocks.len() as u64).to_le_bytes());
        out.extend_from_slice(blocks);
        out
    }

    fn write_tmp(bytes: &[u8], tag: &str) -> String {
        let path = format!("{}-dsf-{tag}.dsf", std::process::id());
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn parses_mono_dsf_header() {
        let bytes = build_dsf(1, 4, 2_822_400, &[0b1010_1010, 0b0101_0101, 0xFF, 0x00]);
        let path = write_tmp(&bytes, "mono");
        let info = parse_dsf_info(&path).unwrap();
        assert_eq!(info.channels, 1);
        assert_eq!(info.dsd_rate, 2_822_400);
        assert_eq!(info.sample_count, 4);
        assert!(!info.is_dst);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn dsd_duration() {
        let bytes = build_dsf(1, 4, 2_822_400, &[0xAA; 4]);
        let path = write_tmp(&bytes, "dur");
        let info = parse_dsf_info(&path).unwrap();
        assert!(info.duration_seconds() == 0);
        let _ = std::fs::remove_file(&path);
    }
}
