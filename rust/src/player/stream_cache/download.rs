use super::*;

pub fn start_streaming_download(
	url: &str,
	headers: Option<&std::collections::HashMap<String, String>>,
	user_agent: Option<&str>,
	ekey: Option<&str>,
	cek: Option<&str>,
) -> Result<StreamingTempFileState, String> {
	let cleaned_url = sanitize_stream_url(url);
	let url = cleaned_url.as_str();
	let hash = url_hash(url);
	let mut mgr = cache().lock().map_err(|e| e.to_string())?;

	if let Some(entry) = mgr.entries.get(&hash) {
		if entry.download_failed.load(Ordering::Relaxed) {
			if let Some(failed) = mgr.entries.remove(&hash) {
				let _ = std::fs::remove_file(&failed.path);
				mgr.current_size = mgr.current_size.saturating_sub(failed.size);
			}
		}
	}

	if let Some(entry) = mgr.entries.get_mut(&hash) {
		entry.last_accessed = SystemTime::now();
		if entry.download_complete.load(Ordering::Relaxed)
			&& !entry.download_failed.load(Ordering::Relaxed)
		{
			if let Some(cek_str) = cek {
				if decrypt_cenc_file(&entry.path, cek_str).is_err() {
					let failed = mgr.entries.remove(&hash);
					if let Some(failed) = failed {
						let _ = std::fs::remove_file(&failed.path);
						mgr.current_size = mgr.current_size.saturating_sub(failed.size);
					}
				}
			}
			if let Some(entry) = mgr.entries.get_mut(&hash) {
				let downloaded = entry.size;
				return Ok(StreamingTempFileState {
					path: entry.path.to_string_lossy().to_string(),
					downloaded_bytes: Arc::new(AtomicU64::new(downloaded)),
					download_complete: Arc::new(AtomicBool::new(true)),
					download_failed: Arc::new(AtomicBool::new(false)),
					total_bytes: Some(downloaded),
					ekey: Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string()))),
					cek: Arc::new(std::sync::Mutex::new(cek.map(|s| s.to_string()))),
					post_check_pending: None,
					cenc_metadata: Arc::new(std::sync::Mutex::new(None)),
					cenc_streaming: Arc::new(AtomicBool::new(false)),
					download_error: Arc::new(std::sync::Mutex::new(None)),
				});
			}
		} else {
			return Ok(StreamingTempFileState {
				path: entry.path.to_string_lossy().to_string(),
				downloaded_bytes: entry.downloaded_bytes.clone(),
				download_complete: entry.download_complete.clone(),
				download_failed: entry.download_failed.clone(),
				total_bytes: None,
				ekey: Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string()))),
				cek: Arc::new(std::sync::Mutex::new(cek.map(|s| s.to_string()))),
				post_check_pending: None,
				cenc_metadata: Arc::new(std::sync::Mutex::new(None)),
				cenc_streaming: Arc::new(AtomicBool::new(false)),
				download_error: Arc::new(std::sync::Mutex::new(None)),
			});
		}
	}

	let temp_path = cache_dir().join(format!("{}.dat", hash));

	let file = OpenOptions::new()
		.write(true)
		.create(true)
		.truncate(true)
		.open(&temp_path)
		.map_err(|e| format!("创建缓存文件失败: {}", e))?;
	drop(file);

	let downloaded_bytes = Arc::new(AtomicU64::new(0));
	let download_complete = Arc::new(AtomicBool::new(false));
	let download_failed = Arc::new(AtomicBool::new(false));
	let post_check_pending = Arc::new(AtomicBool::new(false));
	let shared_ekey = Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string())));
	let shared_cek = Arc::new(std::sync::Mutex::new(cek.map(|s| s.to_string())));
	let download_error: Arc<std::sync::Mutex<Option<String>>> = Arc::new(std::sync::Mutex::new(None));
	let cenc_metadata = Arc::new(std::sync::Mutex::new(None));
	let cenc_streaming = Arc::new(AtomicBool::new(false));

	let url_clone = url.to_string();
	let hash_clone = hash.clone();
	let headers_clone = headers.cloned();
	let ua_clone = user_agent.map(|s| s.to_string());
	let path_clone = temp_path.clone();
	let dl_bytes = downloaded_bytes.clone();
	let dl_complete = download_complete.clone();
	let dl_failed = download_failed.clone();
	let dl_post_check = post_check_pending.clone();
	let dl_ekey = shared_ekey.clone();
	let dl_cek = shared_cek.clone();
	let dl_error = download_error.clone();
	let dl_cenc_metadata = cenc_metadata.clone();
	let dl_cenc_streaming = cenc_streaming.clone();

	let handle = std::thread::spawn(move || {
		let rt = match tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
		{
			Ok(rt) => rt,
			Err(e) => {
				dl_failed.store(true, Ordering::Relaxed);
				if let Ok(mut err) = dl_error.lock() {
					*err = Some(format!("创建下载运行时失败: {}", e));
				}
				return;
			}
		};
		rt.block_on(download_thread(
			&url_clone,
			&hash_clone,
			headers_clone.as_ref(),
			ua_clone.as_deref(),
			path_clone,
			dl_bytes,
			dl_complete,
			dl_failed,
			dl_post_check,
			dl_ekey,
			dl_cek,
			dl_error,
			dl_cenc_metadata,
			dl_cenc_streaming,
		));
	});

	mgr.entries.insert(
		hash,
		CacheEntry {
			path: temp_path.clone(),
			size: 0,
			last_accessed: SystemTime::now(),
			downloaded_bytes: downloaded_bytes.clone(),
			download_complete: download_complete.clone(),
			download_failed: download_failed.clone(),
			_download_handle: Some(handle),
		},
	);
	mgr.evict_if_needed();

	Ok(StreamingTempFileState {
		path: temp_path.to_string_lossy().to_string(),
		downloaded_bytes,
		download_complete,
		download_failed,
		total_bytes: None,
		ekey: shared_ekey,
		cek: shared_cek,
		post_check_pending: Some(post_check_pending),
		cenc_metadata,
		cenc_streaming,
		download_error,
	})
}

pub(crate) fn apply_stream_request_headers(
	mut req: reqwest::RequestBuilder,
	headers: Option<&std::collections::HashMap<String, String>>,
	user_agent: Option<&str>,
) -> reqwest::RequestBuilder {
	let has_plugin_user_agent = headers
		.map(|hdrs| {
			hdrs
				.keys()
				.any(|key| key.eq_ignore_ascii_case("user-agent"))
		})
		.unwrap_or(false);

	if !has_plugin_user_agent {
		if let Some(ua) = user_agent {
			req = req.header(reqwest::header::USER_AGENT, ua);
		}
	}

	if let Some(hdrs) = headers {
		for (key, value) in hdrs {
			if !key.trim().is_empty() && !value.trim().is_empty() {
				if let (Ok(name), Ok(val)) = (
					reqwest::header::HeaderName::from_bytes(key.as_bytes()),
					reqwest::header::HeaderValue::from_str(value),
				) {
					req = req.header(name, val);
				}
			}
		}
	}
	req
}

async fn download_thread(
	url: &str,
	hash: &str,
	headers: Option<&std::collections::HashMap<String, String>>,
	user_agent: Option<&str>,
	path: PathBuf,
	downloaded_bytes: Arc<AtomicU64>,
	download_complete: Arc<AtomicBool>,
	download_failed: Arc<AtomicBool>,
	post_check_pending: Arc<AtomicBool>,
	ekey: Arc<std::sync::Mutex<Option<String>>>,
	cek: Arc<std::sync::Mutex<Option<String>>>,
	download_error: Arc<std::sync::Mutex<Option<String>>>,
	cenc_metadata: Arc<std::sync::Mutex<Option<crate::player::cenc::CencMetadata>>>,
	cenc_streaming: Arc<AtomicBool>,
) {
	let fail_download = |reason: &str, bytes_written: u64| {
		downloaded_bytes.store(bytes_written, Ordering::Relaxed);
		download_failed.store(true, Ordering::Relaxed);
		if let Ok(mut err) = download_error.lock() {
			*err = Some(reason.to_string());
		}
		if let Ok(mut mgr) = cache().lock() {
			mgr.update_size(hash, bytes_written);
		}
	};

	let has_cek = cek.lock().map(|c| c.is_some()).unwrap_or(false);
	if has_cek {
		post_check_pending.store(true, Ordering::Relaxed);
	}

	let client = match reqwest::Client::builder()
		.timeout(Duration::from_secs(120))
		.connect_timeout(Duration::from_secs(10))
		.redirect(crate::security::ssrf::ip_literal_redirect_policy())
		.dns_resolver(crate::security::ssrf::pinned_dns_resolver())
		.gzip(true)
		.brotli(true)
		.deflate(true)
		.build()
	{
		Ok(c) => c,
		Err(e) => {
			fail_download(&format!("创建 HTTP 客户端失败: {}", e), 0);
			return;
		}
	};

	let req = apply_stream_request_headers(client.get(url), headers, user_agent);

	let mut response = match req.send().await {
		Ok(r) => r,
		Err(e) => {
			fail_download(&format!("下载请求失败: {}", e), 0);
			return;
		}
	};

	if !response.status().is_success() {
		fail_download(&format!("HTTP {}", response.status()), 0);
		return;
	}

	let content_type = response
		.headers()
		.get(reqwest::header::CONTENT_TYPE)
		.and_then(|v| v.to_str().ok())
		.unwrap_or("")
		.to_lowercase();
	let is_non_audio = content_type.contains("text/html")
		|| content_type.contains("application/json")
		|| content_type.contains("text/plain")
		|| content_type.contains("application/xml")
		|| content_type.contains("text/xml");
	if is_non_audio {
		let body_text: String = response.text().await.unwrap_or_default();
		if let Some((real_url, json_ekey)) = extract_audio_info_from_text(&body_text) {
			if let Some(ref ek) = json_ekey {
				if let Ok(mut ekey_guard) = ekey.lock() {
					if ekey_guard.is_none() {
						*ekey_guard = Some(ek.clone());
					}
				}
			}
			let retry_req = apply_stream_request_headers(client.get(&real_url), headers, user_agent);
			match retry_req.send().await {
				Ok(retry_resp) if retry_resp.status().is_success() => {
					let retry_ct = retry_resp
						.headers()
						.get(reqwest::header::CONTENT_TYPE)
						.and_then(|v| v.to_str().ok())
						.unwrap_or("")
						.to_lowercase();
					if retry_ct.contains("text/html")
						|| retry_ct.contains("application/json")
						|| retry_ct.contains("text/plain")
						|| retry_ct.contains("application/xml")
						|| retry_ct.contains("text/xml")
					{
						let retry_body: String = retry_resp.text().await.unwrap_or_default();
						if let Some((real_url2, _)) = extract_audio_info_from_text(&retry_body) {
							let resp2_req =
								apply_stream_request_headers(client.get(&real_url2), headers, user_agent);
							match resp2_req.send().await {
								Ok(resp2) if resp2.status().is_success() => {
									let ct2 = resp2
										.headers()
										.get(reqwest::header::CONTENT_TYPE)
										.and_then(|v| v.to_str().ok())
										.unwrap_or("")
										.to_lowercase();
									if ct2.contains("text/html")
										|| ct2.contains("application/json")
										|| ct2.contains("text/plain")
									{
										fail_download(
											&format!("二次提取的 URL 仍返回非音频内容 (Content-Type: {})", ct2),
											0,
										);
										return;
									}
									response = resp2;
								}
								Ok(resp2) => {
									fail_download(&format!("二次提取的 URL 返回 HTTP {}", resp2.status()), 0);
									return;
								}
								Err(e) => {
									fail_download(&format!("二次提取的 URL 请求失败: {}", e), 0);
									return;
								}
							}
						} else {
							fail_download(
								&format!(
									"提取的 URL 仍返回非音频内容 (Content-Type: {})，二次提取失败",
									retry_ct
								),
								0,
							);
							return;
						}
					} else {
						response = retry_resp;
					}
				}
				Ok(retry_resp) => {
					fail_download(&format!("提取的 URL 返回 HTTP {}", retry_resp.status()), 0);
					return;
				}
				Err(e) => {
					fail_download(&format!("提取的 URL 请求失败: {}", e), 0);
					return;
				}
			}
		} else {
			fail_download(
				&format!(
					"服务器返回非音频内容 (Content-Type: {})，URL提取失败",
					content_type
				),
				0,
			);
			return;
		}
	}

	let total_bytes = response
		.headers()
		.get(reqwest::header::CONTENT_LENGTH)
		.and_then(|v| v.to_str().ok())
		.and_then(|v| v.parse::<u64>().ok());

	let mut file = match OpenOptions::new().write(true).open(&path) {
		Ok(f) => f,
		Err(e) => {
			fail_download(&format!("打开缓存文件写入失败: {}", e), 0);
			return;
		}
	};

	let mut bytes_written = 0u64;
	let mut error: Option<String> = None;
	let mut cenc_probe_done = false;

	loop {
		match response.chunk().await {
			Ok(Some(chunk)) => {
				if let Err(e) = file.write_all(&chunk) {
					error = Some(format!("写入缓存文件失败: {}", e));
					break;
				}
				bytes_written += chunk.len() as u64;
				downloaded_bytes.store(bytes_written, Ordering::Relaxed);

				if has_cek && !cenc_probe_done && bytes_written >= MIN_BUFFER_BYTES {
					cenc_probe_done = true;
					let probe_len = bytes_written.min(1024 * 1024) as usize;
					let mut probe_buf = vec![0u8; probe_len];
					if let Ok(mut f) = std::fs::File::open(&path) {
						use std::io::Read as _;
						if f.read_exact(&mut probe_buf).is_ok() {
							let cek_str = cek.lock().ok().and_then(|c| c.clone());
							if let Some(ref cek_str) = cek_str {
								if let Ok(key) = crate::player::cenc::cek_to_key(cek_str) {
									if let Ok(Some(metadata)) =
										crate::player::cenc::parse_cenc_metadata(&probe_buf, &key)
									{
										if let Ok(mut md) = cenc_metadata.lock() {
											*md = Some(metadata);
										}
										cenc_streaming.store(true, Ordering::Relaxed);
										post_check_pending.store(false, Ordering::Relaxed);
									}
								}
							}
						}
					}
				}
			}
			Ok(None) => break,
			Err(e) => {
				error = Some(format!("下载流读取错误: {}", e));
				break;
			}
		}
	}

	let _ = file.flush();

	if let Some(error) = error {
		fail_download(&error, bytes_written);
		return;
	}

	if let Some(total) = total_bytes {
		if bytes_written != total {
			fail_download(
				&format!("下载字节数不完整: {} / {}", bytes_written, total),
				bytes_written,
			);
			return;
		}
	}

	let has_ekey = ekey.lock().map(|e| e.is_some()).unwrap_or(false);
	if !has_ekey {
		if let Ok(mut verify_file) = File::open(&path) {
			let mut header = [0u8; 16];
			let header_len = verify_file.read(&mut header).unwrap_or(0);
			if header_len >= 4 && !is_valid_audio_header(&header[..header_len]) {
				let header_hex: String = header[..header_len]
					.iter()
					.map(|b| format!("{:02x}", b))
					.collect::<Vec<_>>()
					.join(" ");
				fail_download(
					&format!("下载内容非有效音频格式 (header: {})", header_hex),
					bytes_written,
				);
				post_check_pending.store(false, Ordering::Relaxed);
				return;
			}
		}
	}

	if has_cek && !cenc_streaming.load(Ordering::Relaxed) {
		let cek_str = cek.lock().ok().and_then(|c| c.clone());
		if let Some(ref cek_str) = cek_str {
			if let Err(e) = decrypt_cenc_file(&path, cek_str) {
				fail_download(&e, bytes_written);
				post_check_pending.store(false, Ordering::Relaxed);
				return;
			}
		}
		post_check_pending.store(false, Ordering::Relaxed);
	}

	download_complete.store(true, Ordering::Relaxed);

	if let Ok(mut mgr) = cache().lock() {
		mgr.update_size(hash, bytes_written);
	}
}
