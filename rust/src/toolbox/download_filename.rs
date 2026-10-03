use super::*;

pub fn resolve_download_path(
	directory: String,
	file_name: String,
	overwrite_existing: bool,
) -> Result<String, String> { 
	let dir = path_validator::validate_path(&directory, None)?;
	let file_name = path_validator::sanitize_filename_component(&file_name)?;
	let direct = dir.join(&file_name);

	if overwrite_existing || !direct.exists() {
		std::fs::create_dir_all(&dir).map_err(|e| format!("创建下载目录失败: {e}"))?;
		return Ok(direct.to_string_lossy().to_string());
	}

	let dot = file_name.rfind('.');
	let (stem, ext) = match dot {
		Some(idx) => (&file_name[..idx], &file_name[idx..]),
		None => (file_name.as_str(), ""),
	};

	for i in 1..1000 {
		let candidate_name = format!("{stem} ({i}){ext}");
		let candidate = dir.join(&candidate_name);
		if !candidate.exists() {
			return Ok(candidate.to_string_lossy().to_string());
		}
	}

	Ok(direct.to_string_lossy().to_string())
}

pub(crate) fn sanitize_download_filename(name: &str) -> String {
	let sanitized: String = name
		.chars()
		.map(|c| {
			if c.is_control() || matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') {
				' '
			} else {
				c
			}
		})
		.collect();
	let collapsed: String = sanitized.split_whitespace().collect::<Vec<_>>().join(" ");
	let trimmed = collapsed.trim();
	if trimmed.is_empty() {
		return "download".to_string();
	}
	trimmed.chars().take(180).collect()
}

pub(crate) fn ext_from_url(url: &str) -> String {
	let path = match reqwest::Url::parse(url) {
		Ok(u) => u.path().to_string(),
		Err(_) => return String::new(),
	};
	let dot = match path.rfind('.') {
		Some(idx) => idx,
		None => return String::new(),
	};
	let ext = path[dot..].to_lowercase();
	match ext.as_str() {
		".mp3" | ".flac" | ".wav" | ".m4a" | ".aac" | ".ape" | ".ogg" | ".wma" => ext,
		_ => String::new(),
	}
}

pub(crate) fn is_lossless_quality(quality: &str) -> bool {
	matches!(quality, "flac" | "flac24bit" | "hires" | "vinyl" | "master")
}

pub(crate) fn ext_from_quality(quality: &str) -> String {
	if is_lossless_quality(quality) {
		".flac".to_string()
	} else {
		".mp3".to_string()
	}
}

pub(crate) fn build_filename_base(title: &str, artist: &str, album: &str, style: &str) -> String {
	let title = if title.is_empty() {
		"未知歌曲"
	} else {
		title
	};
	let parts: Vec<&str> = match style {
		"title-artist" => vec![title, artist],
		"title-artist-album" => vec![title, artist, album],
		_ => vec![artist, title],
	};
	let joined: String = parts
		.iter()
		.map(|p| p.trim().to_string())
		.filter(|p| !p.is_empty())
		.collect::<Vec<_>>()
		.join(" - ");
	if joined.is_empty() {
		title.to_string()
	} else {
		joined
	}
}

pub(crate) fn build_download_filename(
	title: &str,
	artist: &str,
	album: &str,
	url: &str,
	quality: &str,
	keep_source_filename: bool,
	style: &str,
) -> String {
	let ext = {
		let e = ext_from_url(url);
		if e.is_empty() {
			ext_from_quality(quality)
		} else {
			e
		}
	};

	if keep_source_filename {
		if let Ok(u) = reqwest::Url::parse(url) {
			let path = u.path();
			if let Some(base) = path.rsplit('/').next() {
				if let Some(dot_idx) = base.rfind('.') {
					let stem = &base[..dot_idx];
					let decoded = urlencoding::decode(stem)
						.map(|cow| cow.into_owned())
						.unwrap_or_else(|_| stem.to_string());
					if !decoded.is_empty() {
						return format!("{}{}", sanitize_download_filename(&decoded), ext);
					}
				}
			}
		}
	}

	let base = build_filename_base(title, artist, album, style);
	format!("{}{}", sanitize_download_filename(&base), ext)
}

pub fn resolve_download_full_path(
	directory: String,
	title: String,
	artist: String,
	album: String,
	url: String,
	quality: String,
	keep_source_filename: bool,
	file_name_style: String,
	overwrite_existing: bool,
) -> Result<String, String> { // 实现
	let validated_dir = path_validator::validate_path(&directory, None)?;
	let directory = validated_dir.to_string_lossy().to_string();
	let file_name = build_download_filename(
		&title,
		&artist,
		&album,
		&url,
		&quality,
		keep_source_filename,
		&file_name_style,
	);
	let file_name = path_validator::sanitize_filename_component(&file_name)?;
	resolve_download_path(directory, file_name, overwrite_existing)
}

pub fn build_download_basename(
	title: String,
	artist: String,
	album: String,
	file_name_style: String,
) -> String {
	let base = build_filename_base(&title, &artist, &album, &file_name_style);
	let cleaned = sanitize_download_filename(&base);
	path_validator::sanitize_filename_component(&cleaned).unwrap_or_else(|_| "download".to_string())
}
