pub(crate) fn extract_audio_info_from_json(body: &str) -> Option<(String, Option<String>)> {
	let value: serde_json::Value = match serde_json::from_str(body) {
		Ok(v) => v,
		Err(_) => {
			let trimmed = body.trim().trim_matches('"');
			if trimmed != body.trim() {
				if let Ok(v) = serde_json::from_str(trimmed) {
					v
				} else {
					return None;
				}
			} else {
				return None;
			}
		}
	};

	let priority_keys = [
		"url",
		"musicUrl",
		"audioUrl",
		"playUrl",
		"play_url",
		"music_url",
		"link",
		"src",
		"file",
		"fileUrl",
		"file_url",
		"data",
		"result",
		"music",
		"audio",
		"source",
		"sourceUrl",
		"source_url",
		"media",
		"mediaUrl",
		"stream",
		"streamUrl",
		"stream_url",
		"cdn",
		"cdnUrl",
		"play",
		"download",
		"downloadUrl",
		"download_url",
	];

	for key in &priority_keys {
		if let Some(found) = find_url_by_key(&value, key) {
			let ekey = find_ekey_in_json(&value);
			return Some((found, ekey));
		}
	}

	if let Some(url) = find_any_audio_url(&value) {
		let ekey = find_ekey_in_json(&value);
		return Some((url, ekey));
	}

	if let Some(url) = find_any_http_url(&value) {
		let ekey = find_ekey_in_json(&value);
		return Some((url, ekey));
	}

	None
}

pub(crate) fn sanitize_extracted_audio_url(url: &str) -> String {
	url
		.trim()
		.trim_matches(|c: char| {
			c.is_whitespace()
				|| matches!(
					c,
					'`' | '\'' | '"' | ',' | '，' | ';' | '；' | '‘' | '’' | '“' | '”'
				)
		})
		.to_string()
}

pub(crate) fn extract_audio_info_from_text(body: &str) -> Option<(String, Option<String>)> {
	if let Some(info) = extract_audio_info_from_json(body) {
		return Some(info);
	}

	let trimmed = sanitize_extracted_audio_url(body);
	if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
		if looks_like_audio_url(&trimmed) || !is_obviously_non_audio_url(&trimmed) {
			return Some((trimmed, None));
		}
	}

	if let Some(url) = extract_url_from_raw_text(body) {
		return Some((url, None));
	}

	None
}

pub(crate) fn find_ekey_in_json(value: &serde_json::Value) -> Option<String> {
	let ekey_keys = ["ekey", "eKey", "encryptKey", "encryptionKey"];
	find_string_by_keys(value, &ekey_keys)
}

pub(crate) fn find_string_by_keys(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
	match value {
		serde_json::Value::Object(map) => {
			for &key in keys {
				if let Some(v) = map.get(key) {
					if let Some(s) = v.as_str() {
						if !s.is_empty() {
							return Some(s.to_string());
						}
					}
				}
			}
			for v in map.values() {
				if let Some(found) = find_string_by_keys(v, keys) {
					return Some(found);
				}
			}
			None
		}
		serde_json::Value::Array(arr) => {
			for v in arr {
				if let Some(found) = find_string_by_keys(v, keys) {
					return Some(found);
				}
			}
			None
		}
		_ => None,
	}
}

pub(crate) fn find_url_by_key(value: &serde_json::Value, key: &str) -> Option<String> {
	match value {
		serde_json::Value::Object(map) => {
			if let Some(v) = map.get(key) {
				if let Some(s) = v.as_str() {
					let clean = sanitize_extracted_audio_url(s);
					if clean.starts_with("http://") || clean.starts_with("https://") {
						return Some(clean);
					}
				}
				if let Some(found) = find_url_by_key(v, key) {
					return Some(found);
				}
			}
			for v in map.values() {
				if let Some(found) = find_url_by_key(v, key) {
					return Some(found);
				}
			}
			None
		}
		serde_json::Value::Array(arr) => {
			for v in arr {
				if let Some(found) = find_url_by_key(v, key) {
					return Some(found);
				}
			}
			None
		}
		_ => None,
	}
}

pub(crate) fn find_any_audio_url(value: &serde_json::Value) -> Option<String> {
	match value {
		serde_json::Value::String(s) => {
			let clean = sanitize_extracted_audio_url(s);
			if (clean.starts_with("http://") || clean.starts_with("https://"))
				&& looks_like_audio_url(&clean)
			{
				Some(clean)
			} else {
				None
			}
		}
		serde_json::Value::Object(map) => {
			for v in map.values() {
				if let Some(found) = find_any_audio_url(v) {
					return Some(found);
				}
			}
			None
		}
		serde_json::Value::Array(arr) => {
			for v in arr {
				if let Some(found) = find_any_audio_url(v) {
					return Some(found);
				}
			}
			None
		}
		_ => None,
	}
}

pub(crate) fn find_any_http_url(value: &serde_json::Value) -> Option<String> {
	match value {
		serde_json::Value::String(s) => {
			let clean = sanitize_extracted_audio_url(s);
			if clean.starts_with("http://") || clean.starts_with("https://") {
				if !is_obviously_non_audio_url(&clean) {
					return Some(clean);
				}
			}
			if s.starts_with("//") {
				let full = format!("https:{}", s);
				if !is_obviously_non_audio_url(&full) {
					return Some(full);
				}
			}
			None
		}
		serde_json::Value::Object(map) => {
			for v in map.values() {
				if let Some(found) = find_any_http_url(v) {
					return Some(found);
				}
			}
			None
		}
		serde_json::Value::Array(arr) => {
			for v in arr {
				if let Some(found) = find_any_http_url(v) {
					return Some(found);
				}
			}
			None
		}
		_ => None,
	}
}

pub(crate) fn is_obviously_non_audio_url(url: &str) -> bool {
	let lower = url.to_lowercase();
	lower.contains(".html")
		|| lower.contains(".htm")
		|| lower.contains(".php")
		|| lower.contains(".asp")
		|| lower.contains(".aspx")
		|| lower.contains(".jsp")
		|| lower.contains(".css")
		|| lower.contains(".js")
		|| lower.contains(".png")
		|| lower.contains(".jpg")
		|| lower.contains(".jpeg")
		|| lower.contains(".gif")
		|| lower.contains(".svg")
		|| lower.contains(".webp")
		|| lower.contains(".ico")
		|| lower.contains(".woff")
		|| lower.contains(".ttf")
		|| lower.contains(".pdf")
		|| lower.contains(".zip")
		|| lower.contains(".rar")
		|| lower.contains(".doc")
		|| lower.contains(".docx")
}

pub(crate) fn extract_url_from_raw_text(text: &str) -> Option<String> {
	for prefix in &["https://", "http://"] {
		if let Some(start) = text.find(prefix) {
			let rest = &text[start..];
			let end = rest
				.find(|c: char| {
					c.is_whitespace() || c == '"' || c == '\'' || c == '<' || c == '>' || c == ',' || c == '}'
				})
				.unwrap_or(rest.len());
			let url = &rest[..end];
			if url.len() > 10 && !is_obviously_non_audio_url(url) {
				return Some(sanitize_extracted_audio_url(url));
			}
		}
	}
	None
}

pub(crate) fn looks_like_audio_url(url: &str) -> bool {
	let lower = url.to_lowercase();
	lower.contains(".mp3")
		|| lower.contains(".flac")
		|| lower.contains(".m4a")
		|| lower.contains(".aac")
		|| lower.contains(".ogg")
		|| lower.contains(".wav")
		|| lower.contains(".wma")
		|| lower.contains(".opus")
		|| lower.contains(".mga")
		|| lower.contains(".mgg")
		|| lower.contains("stream.qqmusic")
		|| lower.contains("ws.stream.qqmusic")
		|| lower.contains("dl.stream.qqmusic")
		|| lower.contains("isure.stream")
		|| lower.contains("trackmedia")
		|| lower.contains("music.126.net")
		|| lower.contains("m.kugou")
		|| lower.contains("track.kg")
		|| lower.contains("trackercdn.kugou")
		|| lower.contains("fsandroid.kugou")
		|| lower.contains("fsm.kugou")
		|| lower.contains("mobilesdk.kugou")
		|| lower.contains("kuwo")
		|| lower.contains("car-lv.kuwo")
		|| lower.contains("nmobi.kuwo")
		|| lower.contains("sr.kuwo")
		|| lower.contains("antiserver")
		|| lower.contains("migu.cn")
		|| lower.contains("miguvideo")
		|| lower.contains("haitangw")
		|| lower.contains("musicapi")
		|| (lower.contains("/music")
			|| lower.contains("/song")
			|| lower.contains("/track")
			|| lower.contains("/play"))
}

pub(crate) fn is_valid_audio_header(bytes: &[u8]) -> bool {
	if bytes.len() < 4 {
		return false;
	}

	if &bytes[..3] == b"ID3" {
		return true;
	}

	if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
		return true;
	}

	if &bytes[..4] == b"fLaC" {
		return true;
	}

	if &bytes[..4] == b"RIFF" {
		return true;
	}

	if &bytes[..4] == b"OggS" {
		return true;
	}

	if &bytes[..4] == b"FORM" {
		return true;
	}

	if bytes.len() >= 8 && &bytes[4..8] == b"ftyp" {
		return true;
	}

	false
}
