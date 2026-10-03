pub(crate) use sha2::{Digest, Sha256};
pub(crate) use std::collections::HashMap;
pub(crate) use std::fs::{File, OpenOptions};
pub(crate) use std::io::{Read, Seek, SeekFrom, Write};
pub(crate) use std::path::PathBuf;
pub(crate) use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
pub(crate) use std::sync::{Arc, Mutex, OnceLock};
pub(crate) use std::time::{Duration, SystemTime};

mod download;
mod temp_file;
mod url_probe;

pub use download::*;
pub use temp_file::*;
pub(crate) use url_probe::*;

pub(crate) fn sanitize_stream_url(raw: &str) -> String {
	let trimmed = raw.trim();
	let http_idx = trimmed.find("http://");
	let https_idx = trimmed.find("https://");
	let start = match (http_idx, https_idx) {
		(Some(h), Some(s)) => h.min(s),
		(Some(h), None) => h,
		(None, Some(s)) => s,
		(None, None) => return trimmed.to_string(),
	};
	let candidate = &trimmed[start..];
	let end =
		candidate
			.find(|c: char| {
				matches!(
					c,
					'`'
						| '\'' | '"'
						| '<' | '>'
						| ' ' | '\t'
						| '\n' | '\r'
						| '\u{2018}'
						| '\u{2019}'
						| '\u{201c}'
						| '\u{201d}'
						| '\u{ff02}'
						| '\u{ff07}'
				)
			})
			.unwrap_or(candidate.len());
	let mut result = candidate[..end].to_string();
	loop {
		let trimmed_end = result.trim_end_matches(|c: char| {
			matches!(
				c,
				','
					| '，'
					| ';' | '；'
					| '`' | '\''
					| '"' | ' '
					| '\u{2018}'
					| '\u{2019}'
					| '\u{201c}'
					| '\u{201d}'
					| '\u{ff02}'
					| '\u{ff07}'
			)
		});
		if trimmed_end.len() == result.len() {
			break;
		}
		result = trimmed_end.to_string();
	}
	result
}

pub trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

pub fn decrypt_cenc_file(path: &std::path::Path, cek: &str) -> Result<(), String> {
	let mut data = std::fs::read(path).map_err(|e| format!("读取缓存文件失败: {}", e))?;
	let key = crate::player::cenc::cek_to_key(cek).map_err(|e| e.to_string())?;
	let decrypted = crate::player::cenc::decrypt_cenc_in_place(&mut data, &key)
		.map_err(|e| format!("CENC 解密失败: {}", e))?;
	if decrypted {
		let mut f = OpenOptions::new()
			.write(true)
			.open(path)
			.map_err(|e| format!("打开缓存文件写回失败: {}", e))?;
		f.seek(SeekFrom::Start(0))
			.map_err(|e| format!("定位缓存文件失败: {}", e))?;
		f.write_all(&data)
			.map_err(|e| format!("写回解密文件失败: {}", e))?;
		f.set_len(data.len() as u64)
			.map_err(|e| format!("设置文件长度失败: {}", e))?;
		f.flush().map_err(|e| format!("刷新文件失败: {}", e))?;
	}
	Ok(())
}

pub const MIN_BUFFER_BYTES: u64 = 256 * 1024;

pub(crate) struct CacheEntry {
	path: PathBuf,
	size: u64,
	last_accessed: SystemTime,
	downloaded_bytes: Arc<AtomicU64>,
	download_complete: Arc<AtomicBool>,
	download_failed: Arc<AtomicBool>,
	_download_handle: Option<std::thread::JoinHandle<()>>,
}

pub(crate) struct StreamCacheManager {
	entries: HashMap<String, CacheEntry>,
	max_size_bytes: u64,
	current_size: u64,
}

impl StreamCacheManager {
	fn evict_if_needed(&mut self) {
		while self.current_size > self.max_size_bytes && !self.entries.is_empty() {
			let oldest_key = self
				.entries
				.iter()
				.filter(|(_, entry)| entry.download_complete.load(Ordering::Relaxed))
				.min_by_key(|(_, entry)| entry.last_accessed)
				.map(|(k, _)| k.clone());

			let Some(key) = oldest_key else {
				break;
			};
			if let Some(entry) = self.entries.remove(&key) {
				let _ = std::fs::remove_file(&entry.path);
				self.current_size = self.current_size.saturating_sub(entry.size);
			}
		}
	}

	fn update_size(&mut self, hash: &str, new_size: u64) {
		if let Some(entry) = self.entries.get_mut(hash) {
			self.current_size = self.current_size.saturating_sub(entry.size);
			entry.size = new_size;
			self.current_size += new_size;
		}
	}

	fn init_from_disk(&mut self) {
		let dir = cache_dir();
		let read_dir = match std::fs::read_dir(&dir) {
			Ok(rd) => rd,
			Err(_) => return,
		};

		for entry in read_dir.flatten() {
			let path = entry.path();
			if path.extension().and_then(|s| s.to_str()) != Some("dat") {
				continue;
			}

			let hash = match path.file_stem().and_then(|s| s.to_str()) {
				Some(h) => h.to_string(),
				None => continue,
			};

			if self.entries.contains_key(&hash) {
				continue;
			}

			let metadata = match entry.metadata() {
				Ok(m) => m,
				Err(_) => continue,
			};

			let size = metadata.len();
			if size == 0 {
				let _ = std::fs::remove_file(&path);
				continue;
			}
			let last_modified = metadata.modified().ok().unwrap_or_else(SystemTime::now);

			self.entries.insert(
				hash,
				CacheEntry {
					path: path.clone(),
					size,
					last_accessed: last_modified,
					downloaded_bytes: Arc::new(AtomicU64::new(size)),
					download_complete: Arc::new(AtomicBool::new(true)),
					download_failed: Arc::new(AtomicBool::new(false)),
					_download_handle: None,
				},
			);
			self.current_size += size;
		}

		self.evict_if_needed();
	}
}

static STREAM_CACHE: OnceLock<Mutex<StreamCacheManager>> = OnceLock::new();

pub(crate) fn cache() -> &'static Mutex<StreamCacheManager> {
	STREAM_CACHE.get_or_init(|| {
		let mut mgr = StreamCacheManager {
			entries: HashMap::new(),
			max_size_bytes: 500 * 1024 * 1024,
			current_size: 0,
		};
		mgr.init_from_disk();
		Mutex::new(mgr)
	})
}

pub fn set_max_cache_size(bytes: u64) {
	let mut mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
	mgr.max_size_bytes = bytes;
	mgr.evict_if_needed();
}

pub fn current_cache_size() -> u64 {
	cache()
		.lock()
		.unwrap_or_else(|e| e.into_inner())
		.current_size
}

pub fn max_cache_size() -> u64 {
	cache()
		.lock()
		.unwrap_or_else(|e| e.into_inner())
		.max_size_bytes
}

pub(crate) fn cache_dir() -> PathBuf {
	#[cfg(target_os = "windows")]
	{
		if let Some(appdata) = std::env::var_os("APPDATA") {
			let dir = PathBuf::from(appdata)
				.join("com.xymusic.desktop")
				.join("stream_cache");
			let _ = std::fs::create_dir_all(&dir);
			return dir;
		}
	}

	let dir = std::env::temp_dir().join("xy-music-stream-cache");
	let _ = std::fs::create_dir_all(&dir);
	dir
}

pub(crate) fn url_hash(url: &str) -> String {
	let mut hasher = Sha256::new();
	hasher.update(url.as_bytes());
	hex::encode(&hasher.finalize()[..16])
}

pub fn is_buffer_ready(state: &StreamingTempFileState) -> bool {
	if let Some(ref flag) = state.post_check_pending {
		if flag.load(Ordering::Relaxed) {
			return false;
		}
	}
	state.downloaded_bytes() >= MIN_BUFFER_BYTES || state.is_download_finished()
}

pub fn is_url_cached(url: &str) -> bool {
	let hash = url_hash(url);
	let mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
	if let Some(entry) = mgr.entries.get(&hash) {
		return entry.download_complete.load(Ordering::Relaxed)
			&& !entry.download_failed.load(Ordering::Relaxed)
			&& entry.size > 0;
	}
	false
}

pub fn copy_cache_to(url: &str, dest_path: &str) -> Result<u64, String> {
	let hash = url_hash(url);
	let src_path = {
		let mut mgr = cache().lock().map_err(|e| e.to_string())?;
		let entry = mgr
			.entries
			.get_mut(&hash)
			.ok_or_else(|| "缓存不存在".to_string())?;
		if !entry.download_complete.load(Ordering::Relaxed)
			|| entry.download_failed.load(Ordering::Relaxed)
			|| entry.size == 0
		{
			return Err("缓存未下载完成".to_string());
		}
		entry.last_accessed = SystemTime::now();
		entry.path.clone()
	};
	std::fs::copy(&src_path, dest_path).map_err(|e| format!("复制缓存文件失败: {}", e))
}

pub fn wait_url_complete(url: &str, timeout_secs: u64) -> bool {
	let hash = url_hash(url);
	let deadline = std::time::Instant::now() + Duration::from_secs(timeout_secs);
	loop {
		let finished = {
			let mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
			if let Some(entry) = mgr.entries.get(&hash) {
				entry.download_complete.load(Ordering::Relaxed)
					|| entry.download_failed.load(Ordering::Relaxed)
			} else {
				return false;
			}
		};
		if finished {
			let mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
			if let Some(entry) = mgr.entries.get(&hash) {
				return entry.download_complete.load(Ordering::Relaxed)
					&& !entry.download_failed.load(Ordering::Relaxed)
					&& entry.size > 0;
			}
			return false;
		}
		if std::time::Instant::now() >= deadline {
			return false;
		}
		std::thread::sleep(Duration::from_millis(200));
	}
}

pub fn clear_all() {
	if let Some(mgr) = STREAM_CACHE.get() {
		if let Ok(mut mgr) = mgr.lock() {
			for (_, entry) in mgr.entries.drain() {
				let _ = std::fs::remove_file(&entry.path);
			}
			mgr.current_size = 0;
		}
	}
}
