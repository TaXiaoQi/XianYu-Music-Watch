use super::*;

pub async fn save_download_lyrics(content: String, dest_path: String) -> Result<String, String> {
	write_text_file(content, dest_path).await
}

pub async fn write_text_file(content: String, dest_path: String) -> Result<String, String> {
	let dest = path_validator::validate_path(&dest_path, None)?;
	if let Some(parent) = dest.parent() {
		tokio::fs::create_dir_all(parent)
			.await
			.map_err(|e| format!("创建目录失败: {e}"))?;
	}
	tokio::fs::write(&dest, content)
		.await
		.map_err(|e| format!("写入文件失败: {e}"))?;
	Ok(dest.to_string_lossy().to_string())
}

#[derive(Debug, Serialize)]
pub struct FetchedImage {
	pub data: Vec<u8>,
	pub mime: String,
}

pub async fn fetch_image_bytes(url: String) -> Result<FetchedImage, String> {
	if !(url.starts_with("http://") || url.starts_with("https://")) {
		return Err("无效的图片链接".to_string());
	}

	crate::security::ssrf::validate_outbound_url(&url)
		.await
		.map_err(|e| format!("图片链接校验失败: {e}"))?;

	let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .redirect(crate::security::ssrf::ssrf_redirect_policy())
        .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .build()
        .map_err(|e| format!("创建请求客户端失败: {e}"))?;

	let response = client
		.get(&url)
		.send()
		.await
		.map_err(|e| format!("请求图片失败: {e}"))?;

	if !response.status().is_success() {
		return Err(format!("图片服务器返回错误状态: {}", response.status()));
	}

	let mime = response
		.headers()
		.get(reqwest::header::CONTENT_TYPE)
		.and_then(|v| v.to_str().ok())
		.unwrap_or("image/jpeg")
		.to_string();

	let data = response
		.bytes()
		.await
		.map_err(|e| format!("读取图片数据失败: {e}"))?
		.to_vec();

	if data.is_empty() {
		return Err("图片数据为空".to_string());
	}

	Ok(FetchedImage { data, mime })
}

pub async fn save_download_bytes(data: Vec<u8>, dest_path: String) -> Result<String, String> {
	if data.is_empty() {
		return Err("下载数据为空".to_string());
	}
	let dest = path_validator::validate_path(&dest_path, None)?;
	if let Some(parent) = dest.parent() {
		tokio::fs::create_dir_all(parent)
			.await
			.map_err(|e| format!("创建下载目录失败: {e}"))?;
	}
	tokio::fs::write(&dest, &data)
		.await
		.map_err(|e| format!("写入文件失败: {e}"))?;
	Ok(dest.to_string_lossy().to_string())
}

pub async fn embed_audio_metadata(request: EmbedMetadataRequest) -> Result<(), String> {
	let request = request.clone();
	tokio::task::spawn_blocking(move || write_metadata_to_file(&request))
		.await
		.map_err(|e| format!("元数据嵌入任务失败: {e}"))?
}

pub async fn fetch_announcement() -> Result<String, String> {
	let url = "https://xy.zh2026.cn/chaoguan/public/api/app.php?action=app_announcement";

	let client = reqwest::Client::builder()
		.timeout(std::time::Duration::from_secs(15))
		.dns_resolver(crate::security::ssrf::pinned_dns_resolver())
		.user_agent("XY-Music-Updater")
		.http1_only()
		.build()
		.map_err(|e| format!("创建请求客户端失败: {e}"))?;

	let resp = client
		.get(url)
		.header("Accept", "application/json")
		.header("Cache-Control", "no-cache")
		.send()
		.await
		.map_err(|e| format!("请求公告接口失败: {e}"))?;

	let status = resp.status();
	let text = resp
		.text()
		.await
		.map_err(|e| format!("读取公告数据失败: {e}"))?;

	if !status.is_success() {
		let snippet: String = text.chars().take(200).collect();
		return Err(format!("公告接口返回错误状态: {status} | 响应: {snippet}"));
	}

	match serde_json::from_str::<serde_json::Value>(&text) {
		Ok(v) => {
			let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(0);
			if code == 200 {
				match v.get("data") {
					Some(d) if !d.is_null() => return Ok(d.to_string()),
					_ => return Ok("{}".to_string()),
				}
			}
			let msg = v
				.get("msg")
				.and_then(|m| m.as_str())
				.unwrap_or("公告接口返回未知错误");
			Err(format!("公告接口返回错误: {msg}"))
		}
		Err(_) => {
			let snippet: String = text.chars().take(200).collect();
			Err(format!("公告数据解析失败，原始响应: {snippet}"))
		}
	}
}
