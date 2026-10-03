use super::*;

pub(crate) fn try_extract_ekey_from_file(path: &Path) -> Option<String> {
	let metadata = fs::metadata(path).ok()?;
	let file_size = metadata.len();
	if file_size < 8 {
		return None;
	}

	let tail_size = (file_size.min(4096)) as usize;
	let mut file = fs::File::open(path).ok()?;
	use std::io::{Read, Seek, SeekFrom};
	file
		.seek(SeekFrom::Start(file_size - tail_size as u64))
		.ok()?;
	let mut tail = vec![0u8; tail_size];
	file.read_exact(&mut tail).ok()?;

	crate::player::qmc2::extract_ekey_from_footer(&tail)
}

pub(crate) fn decrypt_qmc_file_inplace(path: &Path, ekey: &str) -> Result<u64, String> {
	let crypto =
		crate::player::qmc2::QmcCrypto::from_ekey(ekey).map_err(|e| format!("ekey 解析失败: {e}"))?;
	decrypt_with_crypto_inplace(path, &crypto)
}

pub(crate) fn decrypt_with_crypto_inplace(
	path: &Path,
	crypto: &crate::player::qmc2::QmcCrypto,
) -> Result<u64, String> {
	use std::io::{Read, Write};

	let file_size = fs::metadata(path)
		.map_err(|e| format!("读取文件元数据失败: {e}"))?
		.len();

	let temp_path = path.with_extension("qmc_tmp_dec");

	let write_result: Result<(), String> = (|| {
		let mut input = fs::File::open(path).map_err(|e| format!("打开加密文件失败: {e}"))?;
		let mut output =
			fs::File::create(&temp_path).map_err(|e| format!("创建临时解密文件失败: {e}"))?;

		let mut offset: u64 = 0;
		let mut buf = vec![0u8; 64 * 1024];

		loop {
			let n = input
				.read(&mut buf)
				.map_err(|e| format!("读取加密数据失败: {e}"))?;
			if n == 0 {
				break;
			}
			crypto.decrypt(offset as usize, &mut buf[..n]);
			output
				.write_all(&buf[..n])
				.map_err(|e| format!("写入解密数据失败: {e}"))?;
			offset += n as u64;
		}

		output.flush().map_err(|e| format!("刷新解密文件失败: {e}"))
	})();

	if let Err(e) = write_result {
		let _ = fs::remove_file(&temp_path);
		return Err(e);
	}

	fs::rename(&temp_path, path).map_err(|e| {
		let _ = fs::remove_file(&temp_path);
		format!("替换原文件失败: {e}")
	})?;

	Ok(file_size)
}

pub(crate) fn read_file_header(path: &Path) -> Result<Vec<u8>, String> {
	use std::io::Read;
	let mut file = fs::File::open(path).map_err(|e| format!("打开文件失败: {e}"))?;
	let mut header = vec![0u8; 16];
	let mut filled = 0;
	while filled < header.len() {
		let n = file
			.read(&mut header[filled..])
			.map_err(|e| format!("读取文件头失败: {e}"))?;
		if n == 0 {
			break;
		}
		filled += n;
	}
	header.truncate(filled);
	Ok(header)
}

pub(crate) fn is_qmc1_extension(path: &Path) -> bool {
	let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
		return false;
	};
	let lower = name.to_lowercase();
	matches!(
		lower.as_str(),
		"qmcflac" | "qmcmp3" | "qmcogg" | "qmcwav" | "qmcape" | "qmcwma"
	) || lower.starts_with("qmc")
}

pub(crate) fn rename_to_audio_extension(path: &Path) -> Result<Option<PathBuf>, String> {
	let header = read_file_header(path)?;
	let Some(real_ext) = crate::player::qmc2::detect_audio_extension(&header) else {
		return Ok(None);
	};
	let cur_ext = path
		.extension()
		.and_then(|e| e.to_str())
		.map(|e| e.to_lowercase())
		.unwrap_or_default();
	if cur_ext == real_ext {
		return Ok(None);
	}
	let stem = path.file_stem().unwrap_or_default();
	let new_path = path.with_file_name(format!("{}.{}", stem.to_string_lossy(), real_ext));
	if new_path.exists() && new_path != path {
		return Ok(None);
	}
	fs::rename(path, &new_path).map_err(|e| format!("修正扩展名失败: {e}"))?;
	Ok(Some(new_path))
}

pub fn decrypt_qmc_file_standalone(
	file_path: String,
	ekey: Option<String>,
) -> Result<String, String> { // 实现
	let path = path_validator::validate_path(&file_path, None)?;

	if !path.is_file() {
		return Err(format!("文件不存在: {}", path.display()));
	}

	let actual_ekey = if let Some(ref ek) = ekey {
		if !ek.is_empty() {
			Some(ek.clone())
		} else {
			try_extract_ekey_from_file(&path)
		}
	} else {
		try_extract_ekey_from_file(&path)
	};

	let (decrypt_result, crypto_name) = if let Some(ek) = actual_ekey {
		let crypto =
			crate::player::qmc2::QmcCrypto::from_ekey(&ek).map_err(|e| format!("ekey 解析失败: {e}"))?;
		(decrypt_with_crypto_inplace(&path, &crypto), "QMC2")
	} else if is_qmc1_extension(&path) {
		let crypto = crate::player::qmc2::QmcCrypto::qmc1();
		let backup = path.with_extension("qmc_tmp_backup");
		fs::copy(&path, &backup).map_err(|e| format!("备份原文件失败: {e}"))?;
		let result = decrypt_with_crypto_inplace(&path, &crypto);
		match result {
			Ok(_) => {
				let header = read_file_header(&path).unwrap_or_default();
				if crate::player::qmc2::detect_audio_extension(&header).is_none() {
					let _ = fs::rename(&backup, &path);
					return Err("解密结果不是有效音频（该文件可能不是 QMC1 格式）".to_string());
				}
				let _ = fs::remove_file(&backup);
				(Ok(0), "QMC1")
			}
			Err(e) => {
				let _ = fs::rename(&backup, &path);
				return Err(format!("QMC1 解密失败: {e}"));
			}
		}
	} else {
		return Ok(
			serde_json::json!({
					"status": "not_encrypted",
					"outputPath": path.to_string_lossy(),
					"renamedTo": null,
			})
			.to_string(),
		);
	};

	match decrypt_result {
		Ok(_) => {
			let renamed_to = rename_to_audio_extension(&path)?;
			let output = renamed_to.as_ref().unwrap_or(&path);
			Ok(
				serde_json::json!({
						"status": "decrypted",
						"outputPath": output.to_string_lossy(),
						"renamedTo": renamed_to.as_ref().map(|p| p.to_string_lossy().to_string()),
						"crypto": crypto_name,
				})
				.to_string(),
			)
		}
		Err(e) => Err(format!("{crypto_name} 解密失败: {e}")),
	}
}
