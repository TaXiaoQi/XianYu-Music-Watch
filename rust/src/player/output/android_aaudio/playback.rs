use super::*;

// =========================================================================
// 进度跟踪
// =========================================================================

pub(crate) struct ExclusiveProgress {
    pub(crate) samples_played: AtomicU64,
    pub(crate) sample_rate: AtomicU32,
    pub(crate) channels: AtomicU32,
    duration_ms: AtomicU64,
}

impl ExclusiveProgress {
    fn new() -> Self {
        Self {
            samples_played: AtomicU64::new(0),
            sample_rate: AtomicU32::new(0),
            channels: AtomicU32::new(0),
            duration_ms: AtomicU64::new(0),
        }
    }
}

// =========================================================================
// 运行时命令
// =========================================================================

pub(crate) enum ExclusiveCommand {
    Seek {
        time_secs: f64,
        is_playing: bool,
    },
    Stop,
    Pause,
    Resume,
    SetVolume(f32),
    SetVolumeBalanceGain(f32),
    SetEqualizer(EqualizerSettings),
    SetSoundEffect(SoundEffectSettings),
    SetBitPerfect(bool),
}

// =========================================================================
// 独占播放控制器
// =========================================================================

struct AndroidExclusivePlayback {
    tx: Sender<ExclusiveCommand>,
    join_handle: Option<thread::JoinHandle<()>>,
    progress: Arc<ExclusiveProgress>,
    device_name: String,
    bit_perfect: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
}

impl Drop for AndroidExclusivePlayback {
    fn drop(&mut self) {
        let _ = self.tx.send(ExclusiveCommand::Stop);
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.join();
        }
    }
}

// =========================================================================
// 全局实例
// =========================================================================

static INSTANCE: OnceLock<Mutex<Option<AndroidExclusivePlayback>>> = OnceLock::new();

fn instance() -> &'static Mutex<Option<AndroidExclusivePlayback>> {
    INSTANCE.get_or_init(|| Mutex::new(None))
}

// =========================================================================
// 公共 API
// =========================================================================

pub fn start_exclusive_playback(
    mut request: ExclusivePlayRequest,
) -> Result<String, String> {
    if request.shared_mode {
        request.bit_perfect = false;
    }
    if request.path.starts_with("http://") || request.path.starts_with("https://") {
        crate::security::ssrf::validate_url_ip_literal(&request.path)
            .map_err(|e| format!("播放链接校验失败: {e}"))?;
    }
    stop_exclusive_playback();

    let progress = Arc::new(ExclusiveProgress::new());
    let (tx, rx) = mpsc::channel::<ExclusiveCommand>();
    let (init_tx, init_rx) = mpsc::sync_channel::<Result<(String, u32, u16), String>>(1);
    let progress_clone = progress.clone();
    let bit_perfect = Arc::new(AtomicBool::new(request.bit_perfect));
    let bit_perfect_clone = bit_perfect.clone();
    let running = Arc::new(AtomicBool::new(true));
    let running_clone = running.clone();

    let shared_mode = request.shared_mode;

    let handle = thread::Builder::new()
        .name("xy-aaudio-exclusive".to_string())
        .spawn(move || {
            run_exclusive_playback(request, rx, init_tx, progress_clone, bit_perfect_clone, running_clone);
        })
        .map_err(|e| e.to_string())?;

    let init_wait = if shared_mode {
        Duration::from_secs(6)
    } else {
        Duration::from_secs(3)
    };
    let device_name = match init_rx.recv_timeout(init_wait) {
        Ok(Ok((name, sr, ch))) => {
            progress.sample_rate.store(sr, Ordering::Relaxed);
            progress.channels.store(ch as u32, Ordering::Relaxed);
            name
        }
        Ok(Err(e)) => {
            let _ = handle.join();
            return Err(e);
        }
        Err(_) => {
            let _ = handle.join();
            return Err("AAudio 管线初始化超时".to_string());
        }
    };

    let playback = AndroidExclusivePlayback {
        tx,
        join_handle: Some(handle),
        progress,
        device_name: device_name.clone(),
        bit_perfect,
        running,
    };

    let mut guard = instance().lock().map_err(|e| e.to_string())?;
    *guard = Some(playback);

    Ok(device_name)
}

pub fn stop_exclusive_playback() {
    if let Ok(mut guard) = instance().lock() {
        if let Some(mut playback) = guard.take() {
            let _ = playback.tx.send(ExclusiveCommand::Stop);
            if let Some(handle) = playback.join_handle.take() {
                let _ = handle.join();
            }
        }
    }
}

pub fn seek_exclusive(time_secs: f64, is_playing: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Seek {
                time_secs,
                is_playing,
            });
        }
    }
}

pub fn set_exclusive_volume(volume: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetVolume(volume));
        }
    }
}

pub fn set_exclusive_volume_balance_gain(gain: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetVolumeBalanceGain(gain));
        }
    }
}

pub fn set_exclusive_equalizer(settings_json: &str) -> Result<(), String> {
    let settings: EqualizerSettings = if settings_json.is_empty() {
        EqualizerSettings::default()
    } else {
        serde_json::from_str(settings_json).map_err(|e| e.to_string())?
    };
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetEqualizer(settings));
        }
    }
    Ok(())
}

pub fn set_exclusive_sound_effect(settings_json: &str) -> Result<(), String> {
    let settings: SoundEffectSettings = if settings_json.is_empty() {
        SoundEffectSettings::default()
    } else {
        serde_json::from_str(settings_json).map_err(|e| e.to_string())?
    };
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetSoundEffect(settings));
        }
    }
    Ok(())
}

pub fn pause_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Pause);
        }
    }
}

pub fn resume_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Resume);
        }
    }
}

pub fn set_exclusive_bit_perfect(enabled: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetBitPerfect(enabled));
        }
    }
}

pub fn is_exclusive_bit_perfect() -> bool {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.bit_perfect.load(Ordering::Relaxed);
        }
    }
    false
}

pub fn is_exclusive_active() -> bool {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.running.load(Ordering::Relaxed);
        }
    }
    false
}

pub fn get_exclusive_position_secs() -> f64 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let samples = playback.progress.samples_played.load(Ordering::Relaxed);
            let rate = playback.progress.sample_rate.load(Ordering::Relaxed);
            let channels = playback.progress.channels.load(Ordering::Relaxed).max(1);
            if rate > 0 {
                return samples as f64 / (rate as f64 * channels as f64);
            }
        }
    }
    0.0
}

pub fn get_exclusive_sample_rate() -> u32 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.progress.sample_rate.load(Ordering::Relaxed);
        }
    }
    0
}

pub fn get_exclusive_channels() -> u16 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.progress.channels.load(Ordering::Relaxed) as u16;
        }
    }
    0
}

pub fn get_exclusive_device_info() -> String {
    let (active, device_name, sample_rate, channels, bit_perfect, duration_ms) =
        if let Ok(guard) = instance().lock() {
            if let Some(playback) = guard.as_ref() {
                (
                    playback.running.load(Ordering::Relaxed),
                    playback.device_name.clone(),
                    playback.progress.sample_rate.load(Ordering::Relaxed),
                    playback.progress.channels.load(Ordering::Relaxed) as u16,
                    playback.bit_perfect.load(Ordering::Relaxed),
                    playback.progress.duration_ms.load(Ordering::Relaxed),
                )
            } else {
                (false, String::new(), 0, 0, false, 0)
            }
        } else {
            (false, String::new(), 0, 0, false, 0)
        };
    serde_json::json!({
        "active": active,
        "deviceName": device_name,
        "sampleRate": sample_rate,
        "channels": channels,
        "bitPerfect": bit_perfect,
        "durationSecs": duration_ms as f64 / 1000.0,
    })
    .to_string()
}

// =========================================================================
// 工作线程
// =========================================================================

fn run_exclusive_playback(
    request: crate::player::output::ExclusivePlayRequest,
    cmd_rx: Receiver<ExclusiveCommand>,
    init_tx: SyncSender<Result<(String, u32, u16), String>>,
    progress: Arc<ExclusiveProgress>,
    bit_perfect: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
) {
    let lib = match AAudioLib::load() {
        Some(l) => l,
        None => {
            let _ = init_tx.send(Err("无法加载 libaaudio.so（需要 Android API 26+）".to_string()));
            return;
        }
    };

    if request.dsd_native_passthrough && !request.shared_mode && is_dsd_path(&request.path) {
        run_dsd_passthrough(request, lib, cmd_rx, init_tx, progress, bit_perfect, running);
        return;
    }

    let decoder = match SymphoniaDecoder::open(&request.path) {
        Ok(d) => d,
        Err(e) => {
            let _ = init_tx.send(Err(format!("打开音频文件失败: {e}")));
            return;
        }
    };

    let source_sample_rate = decoder.sample_rate;
    let source_channels = decoder.channels;
    let total_duration = decoder.total_duration;

    let mut buffered = BufferedSource::new(
        decoder,
        source_sample_rate,
        source_channels,
        total_duration,
    );

    if request.start_time_secs > 0.0 {
        if let Err(e) = buffered.try_seek(Duration::from_secs_f64(request.start_time_secs)) {
            let _ = init_tx.send(Err(format!("跳转失败: {e}")));
            return;
        }
    }

    let initial_bit_perfect = request.bit_perfect;
    let (mut normalizer, normalizer_handle) = VolumeNormalizer::new(
        if initial_bit_perfect {
            1.0
        } else {
            request.volume_balance_gain
        },
        source_sample_rate,
        source_channels,
        100,
    );

    let eq_settings: EqualizerSettings = if initial_bit_perfect {
        EqualizerSettings::default()
    } else if request.equalizer_settings_json.is_empty() {
        EqualizerSettings::default()
    } else {
        serde_json::from_str(&request.equalizer_settings_json).unwrap_or_default()
    };
    let eq_handle = Arc::new(EqualizerHandle::new(eq_settings));
    let mut equalizer = Equalizer::new(source_sample_rate, source_channels, eq_handle.clone());

    let mut sound_effect = SoundEffectBlockProcessor::new(source_sample_rate, source_channels);
    if !initial_bit_perfect && !request.sound_effect_settings_json.is_empty() {
        if let Ok(se_settings) =
            serde_json::from_str::<SoundEffectSettings>(&request.sound_effect_settings_json)
        {
            sound_effect.set_settings(se_settings);
        }
    }

    let mut user_volume_source = UserVolumeSource::new(request.volume, source_sample_rate);
    let mut clip_guard = ClipGuardSource::new();

    let user_volume = Arc::new(AtomicU32::new(request.volume.to_bits()));
    let is_paused = Arc::new(AtomicBool::new(!request.is_playing));

    let (stream, device_format, stream_sample_rate, stream_channels) = if request.shared_mode {
        match create_aaudio_stream(&lib, request.device_id, source_sample_rate, source_channels, true) {
            Ok(result) => result,
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        }
    } else if initial_bit_perfect {
        let depth = probe_source_bit_depth(&request.path);
        match create_aaudio_stream_bitperfect(
            &lib,
            request.device_id,
            source_sample_rate,
            source_channels,
            depth,
        ) {
            Ok(result) => result,
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        }
    } else {
        match create_aaudio_stream(&lib, request.device_id, source_sample_rate, source_channels, false)
        {
            Ok(result) => result,
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        }
    };

    let effective_rate = sound_effect.effective_sample_rate();
    progress.sample_rate.store(effective_rate, Ordering::Relaxed);
    progress.channels.store(stream_channels as u32, Ordering::Relaxed);
    progress.duration_ms.store(
        total_duration.map(|d| d.as_millis() as u64).unwrap_or(0),
        Ordering::Relaxed,
    );
    progress.samples_played.store(
        (request.start_time_secs * source_sample_rate as f64 * source_channels as f64) as u64,
        Ordering::Relaxed,
    );

    let visualizer = global_visualizer();
    visualizer.reset();

    let start_result = unsafe { (lib.stream_request_start)(stream) };
    if start_result != AAUDIO_OK {
        let msg = unsafe { lib.result_text(start_result) };
        let _ = init_tx.send(Err(format!("AAudio 启动失败: {msg}")));
        unsafe { (lib.stream_close)(stream) };
        return;
    }

    let device_name = if request.shared_mode {
        format!("系统混音器 ({}Hz, {}ch shared)", stream_sample_rate, stream_channels)
    } else {
        format!(
            "USB DAC ({}Hz, {}ch, {}bit exclusive)",
            stream_sample_rate,
            stream_channels,
            match device_format {
                DeviceFormat::Float32 => 32,
                DeviceFormat::Int16 => 16,
                DeviceFormat::I24Packed => 24,
            }
        )
    };
    let _ = init_tx.send(Ok((device_name, stream_sample_rate, stream_channels)));

    let timeout_ns: i64 = 20_000_000;
    let bytes_per_sample = device_format.bytes_per_sample();

    loop {
        match cmd_rx.try_recv() {
            Ok(ExclusiveCommand::Stop) => break,
            Ok(ExclusiveCommand::Seek { time_secs, is_playing }) => {
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                if let Err(e) = buffered.try_seek(Duration::from_secs_f64(time_secs)) {
                    let _ = e;
                }
                normalizer.reset();
                equalizer.reset();
                sound_effect.reset();
                progress.samples_played.store(
                    (time_secs * source_sample_rate as f64 * source_channels as f64) as u64,
                    Ordering::Relaxed,
                );
                visualizer.reset();
                is_paused.store(!is_playing, Ordering::Relaxed);
                if is_playing {
                    let _ = unsafe { (lib.stream_request_start)(stream) };
                }
            }
            Ok(ExclusiveCommand::Pause) => {
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                is_paused.store(true, Ordering::Relaxed);
            }
            Ok(ExclusiveCommand::Resume) => {
                is_paused.store(false, Ordering::Relaxed);
                let _ = unsafe { (lib.stream_request_start)(stream) };
            }
            Ok(ExclusiveCommand::SetVolume(vol)) => {
                user_volume.store(vol.to_bits(), Ordering::Relaxed);
            }
            Ok(ExclusiveCommand::SetVolumeBalanceGain(gain)) => {
                normalizer_handle.set_target_gain(gain);
            }
            Ok(ExclusiveCommand::SetEqualizer(settings)) => {
                eq_handle.set_settings(settings);
            }
            Ok(ExclusiveCommand::SetSoundEffect(settings)) => {
                sound_effect.set_settings(settings);
            }
            Ok(ExclusiveCommand::SetBitPerfect(enabled)) => {
                bit_perfect.store(enabled, Ordering::Relaxed);
                if enabled {
                    normalizer.reset();
                    equalizer.reset();
                    sound_effect.reset();
                    if is_paused.load(Ordering::Relaxed) {
                        let _ = unsafe { (lib.stream_request_start)(stream) };
                    }
                    is_paused.store(false, Ordering::Relaxed);
                }
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => break,
        }

        if is_paused.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(10));
            continue;
        }

        let available = unsafe { (lib.stream_get_available_frames)(stream) };
        if available <= 0 {
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        let block = match buffered.next_block() {
            Some(block) => block,
            None => {
                break;
            }
        };

        let do_bypass = bit_perfect.load(Ordering::Relaxed);
        let mut effected = if do_bypass {
            block
        } else {
            let normalized = normalizer.process_block(&block);
            let eq_applied = equalizer.process_block(&normalized);
            sound_effect.process_block(eq_applied)
        };

        if !do_bypass {
            user_volume_source.process_block(&mut effected, source_channels, &user_volume);
        }
        clip_guard.process_block(&mut effected);

        let mut byte_buf: Vec<u8> = Vec::with_capacity(effected.len() * bytes_per_sample);

        let mut chan_sum = 0.0f32;
        let mut chan_count = 0u32;

        for &sample in &effected {
            push_sample_bytes(&mut byte_buf, sample, device_format);

            chan_sum += sample;
            chan_count += 1;
            if chan_count >= stream_channels as u32 {
                visualizer.push_sample(chan_sum / chan_count as f32);
                chan_sum = 0.0;
                chan_count = 0;
            }
        }

        progress
            .samples_played
            .fetch_add(effected.len() as u64, Ordering::Relaxed);

        let frames_written = unsafe {
            (lib.stream_write)(
                stream,
                byte_buf.as_ptr() as *const std::os::raw::c_void,
                (effected.len() / stream_channels as usize) as i32,
                timeout_ns,
            )
        };

        if frames_written < 0 {
            break;
        }

        if frames_written < (effected.len() / stream_channels as usize) as i64 {
            thread::sleep(Duration::from_millis(5));
        }
    }

    running.store(false, Ordering::Relaxed);
    unsafe {
        (lib.stream_request_stop)(stream);
        (lib.stream_close)(stream);
    }
}
