use super::*;

pub struct StreamingTempFileReader {
	file: File,
	downloaded_bytes: Arc<AtomicU64>,
	download_complete: Arc<AtomicBool>,
	download_failed: Arc<AtomicBool>,
	pos: u64,
	total_bytes: Option<u64>,
	post_check_pending: Option<Arc<AtomicBool>>,
}

impl Read for StreamingTempFileReader {
	fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
		loop {
			if let Some(ref flag) = self.post_check_pending {
				if flag.load(Ordering::Relaxed) {
					if self.download_failed.load(Ordering::Relaxed) {
						return Ok(0);
					}
					std::thread::sleep(Duration::from_millis(3));
					continue;
				}
			}

			let downloaded = self.downloaded_bytes.load(Ordering::Relaxed);
			if self.pos < downloaded {
				let max_read = (downloaded - self.pos).min(buf.len() as u64) as usize;
				let n = self.file.read(&mut buf[..max_read])?;
				self.pos += n as u64;
				return Ok(n);
			}
			if self.download_complete.load(Ordering::Relaxed)
				|| self.download_failed.load(Ordering::Relaxed)
			{
				return Ok(0);
			}
			std::thread::sleep(Duration::from_millis(3));
		}
	}
}

impl Seek for StreamingTempFileReader {
	fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
		let target = match pos {
			SeekFrom::Start(n) => n,
			SeekFrom::Current(n) => (self.pos as i64 + n).max(0) as u64,
			SeekFrom::End(n) => {
				if self.total_bytes.is_some() || self.download_complete.load(Ordering::Relaxed) {
					return self.file.seek(SeekFrom::End(n)).map(|p| {
						self.pos = p;
						p
					});
				}
				return Err(std::io::Error::new(
					std::io::ErrorKind::Unsupported,
					"Cannot seek from end while download is in progress",
				));
			}
		};

		loop {
			let downloaded = self.downloaded_bytes.load(Ordering::Relaxed);
			if target < downloaded
				|| self.download_complete.load(Ordering::Relaxed)
				|| self.download_failed.load(Ordering::Relaxed)
			{
				self.pos = target;
				return self.file.seek(SeekFrom::Start(target)).map(|_| target);
			}
			std::thread::sleep(Duration::from_millis(3));
		}
	}
}

#[derive(Clone)]
pub struct StreamingTempFileState {
	pub path: String,
	pub downloaded_bytes: Arc<AtomicU64>,
	pub download_complete: Arc<AtomicBool>,
	pub download_failed: Arc<AtomicBool>,
	pub total_bytes: Option<u64>,
	pub ekey: Arc<std::sync::Mutex<Option<String>>>,
	pub cek: Arc<std::sync::Mutex<Option<String>>>,
	pub cenc_metadata: Arc<std::sync::Mutex<Option<crate::player::cenc::CencMetadata>>>,
	pub cenc_streaming: Arc<AtomicBool>,
	pub post_check_pending: Option<Arc<AtomicBool>>,
	pub download_error: Arc<std::sync::Mutex<Option<String>>>,
}

impl std::fmt::Debug for StreamingTempFileState {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.debug_struct("StreamingTempFileState")
			.field("path", &self.path)
			.field(
				"downloaded_bytes",
				&self.downloaded_bytes.load(Ordering::Relaxed),
			)
			.field(
				"download_complete",
				&self.download_complete.load(Ordering::Relaxed),
			)
			.field(
				"download_failed",
				&self.download_failed.load(Ordering::Relaxed),
			)
			.field("total_bytes", &self.total_bytes)
			.field(
				"ekey",
				&self.ekey.lock().map(|e| e.is_some()).unwrap_or(false),
			)
			.field(
				"cek",
				&self.cek.lock().map(|c| c.is_some()).unwrap_or(false),
			)
			.field(
				"cenc_streaming",
				&self.cenc_streaming.load(Ordering::Relaxed),
			)
			.finish()
	}
}

impl StreamingTempFileState {
	pub fn new_reader(&self) -> std::io::Result<StreamingTempFileReader> {
		let file = File::open(&self.path)?;
		Ok(StreamingTempFileReader {
			file,
			downloaded_bytes: self.downloaded_bytes.clone(),
			download_complete: self.download_complete.clone(),
			download_failed: self.download_failed.clone(),
			pos: 0,
			total_bytes: self.total_bytes,
			post_check_pending: self.post_check_pending.clone(),
		})
	}

	pub fn ekey(&self) -> Option<String> {
		self.ekey.lock().ok().and_then(|e| e.clone())
	}

	pub fn cek(&self) -> Option<String> {
		self.cek.lock().ok().and_then(|c| c.clone())
	}

	pub fn new_reader_with_decryption(
		&self,
	) -> std::io::Result<Box<dyn ReadSeek + Send + Sync + 'static>> {
		let reader = self.new_reader()?;

		if self.cenc_streaming.load(Ordering::Relaxed) {
			if let Ok(md_lock) = self.cenc_metadata.lock() {
				if let Some(ref metadata) = *md_lock {
					if let Some(cek_str) = self.cek() {
						if let Ok(key) = crate::player::cenc::cek_to_key(&cek_str) {
							return Ok(Box::new(crate::player::cenc::CencDecryptReader::new(
								reader,
								key,
								metadata.clone(),
							)));
						}
					}
				}
			}
		}

		let ekey = self.ekey();
		if let Some(ekey_str) = ekey {
			match crate::player::qmc2::QmcCrypto::from_ekey(&ekey_str) {
				Ok(crypto) => Ok(Box::new(crate::player::qmc2::QmcDecryptReader::new(
					reader, crypto,
				))),
				Err(_) => Ok(Box::new(reader)),
			}
		} else {
			Ok(Box::new(reader))
		}
	}

	pub fn is_download_finished(&self) -> bool {
		self.download_complete.load(Ordering::Relaxed) || self.download_failed.load(Ordering::Relaxed)
	}

	pub fn downloaded_bytes(&self) -> u64 {
		self.downloaded_bytes.load(Ordering::Relaxed)
	}

	pub fn download_error(&self) -> Option<String> {
		self.download_error.lock().ok().and_then(|e| e.clone())
	}
}
