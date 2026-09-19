
use crate::security::path_validator;
use image::{GenericImageView, ImageEncoder};
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::time::Duration;

const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const MAX_BACKGROUND_VIDEO_BYTES: u64 = 512 * 1024 * 1024;

fn shrink_to_fit(img: image::DynamicImage, max_edge: u32) -> image::DynamicImage {
    let (w, h) = img.dimensions();
    let largest = w.max(h);
    if largest <= max_edge || w == 0 || h == 0 {
        return img;
    }
    if w >= h {
        img.resize(max_edge, (h * max_edge) / w, image::imageops::FilterType::Lanczos3)
    } else {
        img.resize((w * max_edge) / h, max_edge, image::imageops::FilterType::Lanczos3)
    }
}

pub fn read_plugin_file(path: String) -> Result<String, String> {
    let validated = path_validator::validate_path(&path, None)
        .map_err(|e| format!("路径校验失败: {} (路径: {})", e, path))?;
    let path_obj = validated.as_path();
    if !path_obj.is_file() {
        return Err(format!("插件文件不存在: {}", path));
    }

    let ext = path_obj
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !matches!(ext.as_str(), "js" | "json" | "txt" | "m3u" | "m3u8") {
        return Err(format!(
            "不支持的文件类型: .{} (仅支持 .js/.json/.txt/.m3u/.m3u8)",
            ext
        ));
    }

    let metadata =
        fs::metadata(path_obj).map_err(|error| format!("读取文件元数据失败: {}", error))?;
    let max_size = if ext == "json" {
        50 * 1024 * 1024
    } else {
        5 * 1024 * 1024
    };
    if metadata.len() > max_size {
        return Err(format!(
            "文件过大: {} MB (上限 {} MB)",
            metadata.len() / 1024 / 1024,
            max_size / 1024 / 1024
        ));
    }

    fs::read_to_string(path_obj).map_err(|error| format!("读取文件内容失败: {}", error))
}

pub async fn proxy_image(url: String, referer: Option<String>) -> Result<String, String> {
    crate::security::ssrf::validate_outbound_url(&url)
        .await
        .map_err(|e| format!("图片链接校验失败: {e}"))?;

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .redirect(crate::security::ssrf::ssrf_redirect_policy())
        .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
        .user_agent(USER_AGENT)
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = client.get(&url);
    let ref_url = referer.unwrap_or_else(|| {
        if url.contains("hdslb.com") || url.contains("bilivideo.com") {
            "https://www.bilibili.com".to_string()
        } else if url.contains("126.net") || url.contains("163.com") {
            "https://music.163.com/".to_string()
        } else if url.contains("kuwo.cn") || url.contains("kuwo.com") {
            "http://www.kuwo.cn/".to_string()
        } else if url.contains("kugou.com") || url.contains("kgmusic.com") {
            "http://www.kugou.com/".to_string()
        } else if url.contains("gtimg.cn") || url.contains("qq.com") {
            "https://y.qq.com/".to_string()
        } else if url.contains("migu.cn") {
            "https://m.music.migu.cn/".to_string()
        } else {
            String::new()
        }
    });
    if !ref_url.is_empty() {
        req = req.header("Referer", &ref_url);
    }

    let response = req.send().await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }

    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();

    let bytes = response.bytes().await.map_err(|e| e.to_string())?;

    const MAX_NETWORK_BYTES: usize = 20 * 1024 * 1024;
    if bytes.len() > MAX_NETWORK_BYTES {
        return Err("Image too large".to_string());
    }

    use base64::{engine::general_purpose, Engine as _};

    const MAX_DATA_BYTES: usize = 5 * 1024 * 1024;
    if bytes.len() > MAX_DATA_BYTES {
        let Ok(img) = image::load_from_memory(&bytes) else {
            return Err("Image too large".to_string());
        };
        const MAX_EDGE: u32 = 800;
        let img = shrink_to_fit(img, MAX_EDGE);
        let rgba = img.to_rgba8();
        let mut png = Vec::new();
        if image::codecs::png::PngEncoder::new(&mut png)
            .write_image(
                rgba.as_raw(),
                rgba.width(),
                rgba.height(),
                image::ExtendedColorType::Rgba8,
            )
            .is_ok()
        {
            return Ok(format!(
                "data:image/png;base64,{}",
                general_purpose::STANDARD.encode(&png)
            ));
        }
        let mut jpeg = Vec::new();
        if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 82)
            .write_image(
                rgba.as_raw(),
                rgba.width(),
                rgba.height(),
                image::ExtendedColorType::Rgba8,
            )
            .is_ok()
        {
            return Ok(format!(
                "data:image/jpeg;base64,{}",
                general_purpose::STANDARD.encode(&jpeg)
            ));
        }
        return Err("Image too large".to_string());
    }

    let b64 = general_purpose::STANDARD.encode(&bytes);
    Ok(format!("data:{};base64,{}", content_type, b64))
}

pub fn read_image_base64(path: String) -> Result<String, String> {
    use base64::{engine::general_purpose, Engine as _};

    let validated = path_validator::validate_path(&path, None)
        .map_err(|e| format!("路径校验失败: {} (路径: {})", e, path))?;
    let path_obj = validated.as_path();
    if !path_obj.is_file() {
        return Err(format!("文件不存在: {}", path));
    }

    let metadata = fs::metadata(path_obj).map_err(|error| format!("读取文件元数据失败: {}", error))?;
    let max_size = 5 * 1024 * 1024;
    if metadata.len() > max_size {
        return Err(format!(
            "文件过大: {} MB (上限 {} MB)",
            metadata.len() / 1024 / 1024,
            max_size / 1024 / 1024
        ));
    }

    let bytes = fs::read(path_obj).map_err(|error| format!("读取文件内容失败: {}", error))?;
    let mime = image::guess_format(&bytes)
        .map(|f| match f {
            image::ImageFormat::Jpeg => "image/jpeg",
            image::ImageFormat::Png => "image/png",
            image::ImageFormat::WebP => "image/webp",
            image::ImageFormat::Gif => "image/gif",
            _ => "image/jpeg",
        })
        .unwrap_or("image/jpeg");
    Ok(serde_json::json!({
        "mime": mime,
        "base64": general_purpose::STANDARD.encode(&bytes),
    })
    .to_string())
}

pub async fn download_video_to_cache(
    cache_dir: String,
    url: String,
    headers: Option<HashMap<String, String>>,
) -> Result<String, String> {
    use tokio::io::AsyncWriteExt;

    if !url.starts_with("https://") && !url.starts_with("http://") {
        return Err("Unsupported video URL".to_string());
    }

    crate::security::ssrf::validate_outbound_url(&url)
        .await
        .map_err(|error| error.to_string())?;

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        .redirect(crate::security::ssrf::ssrf_redirect_policy())
        .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
        .gzip(true)
        .brotli(true)
        .deflate(true)
        .user_agent(USER_AGENT)
        .build()
        .map_err(|error| error.to_string())?;

    let mut request = client.get(&url);
    if let Some(request_headers) = headers {
        for (key, value) in request_headers {
            if !key.trim().is_empty() && !value.trim().is_empty() {
                request = request.header(key, value);
            }
        }
    }

    let mut response = request.send().await.map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    if response
        .content_length()
        .is_some_and(|size| size > MAX_BACKGROUND_VIDEO_BYTES)
    {
        return Err("Video is too large for background playback".to_string());
    }

    let video_dir = Path::new(&cache_dir).join("video-background");
    fs::create_dir_all(&video_dir).map_err(|error| error.to_string())?;
    let file_name = format!("xy_music_video_{}.mp4", uuid::Uuid::new_v4());
    let cache_path = video_dir.join(file_name);

    let mut file = tokio::fs::File::create(&cache_path)
        .await
        .map_err(|error| error.to_string())?;

    let mut written = 0_u64;
    let download_result: Result<(), String> = async {
        while let Some(chunk) = response.chunk().await.map_err(|error| error.to_string())? {
            written = written.saturating_add(chunk.len() as u64);
            if written > MAX_BACKGROUND_VIDEO_BYTES {
                return Err("Video is too large for background playback".to_string());
            }
            file.write_all(&chunk)
                .await
                .map_err(|error| error.to_string())?;
        }
        file.flush().await.map_err(|error| error.to_string())?;
        Ok(())
    }
    .await;

    if let Err(error) = download_result {
        drop(file);
        let _ = tokio::fs::remove_file(&cache_path).await;
        return Err(error);
    }
    if written == 0 {
        drop(file);
        let _ = tokio::fs::remove_file(&cache_path).await;
        return Err("Empty video response".to_string());
    }

    Ok(cache_path.to_string_lossy().to_string())
}

pub async fn remove_cached_background_video(
    cache_dir: String,
    path: String,
) -> Result<(), String> {
    let video_dir = Path::new(&cache_dir).join("video-background");
    let candidate = std::path::PathBuf::from(path);
    let file_name = candidate
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    if candidate.parent() != Some(video_dir.as_path()) || !file_name.starts_with("xy_music_video_")
    {
        return Err("Refusing to remove a non-background-video file".to_string());
    }
    if !candidate.exists() {
        return Ok(());
    }
    tokio::fs::remove_file(candidate)
        .await
        .map_err(|error| error.to_string())
}