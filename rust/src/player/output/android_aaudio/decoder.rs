use super::*;

// =========================================================================
// Symphonia 解码器（BlockProducer）
// =========================================================================

pub(crate) struct SymphoniaDecoder {
    format_reader: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    pub(crate) sample_rate: u32,
    pub(crate) channels: u16,
    pub(crate) total_duration: Option<Duration>,
    sample_buf: Option<symphonia::core::audio::SampleBuffer<f32>>,
    sample_buf_frames: usize,
    leftover: Vec<f32>,
    eof: bool,
}

impl SymphoniaDecoder {
    pub(crate) fn open(path: &str) -> Result<Self, String> {
        use symphonia::core::codecs::{CODEC_TYPE_NULL, DecoderOptions};
        use symphonia::core::formats::FormatOptions;
        use symphonia::core::io::MediaSourceStream;
        use symphonia::core::meta::MetadataOptions;
        use symphonia::core::probe::Hint;

        let is_http = path.starts_with("http://") || path.starts_with("https://");

        let mut hint = Hint::new();
        let mss: MediaSourceStream = if is_http {
            if let Some(ext) = url_path_extension(path) {
                hint.with_extension(&ext);
            }
            let reader = crate::player::http_source::HttpSeekableReader::open(path)?;
            MediaSourceStream::new(Box::new(reader), Default::default())
        } else {
            let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;

            let mut header = [0u8; 8];
            let header_len = file.read(&mut header).unwrap_or(0);
            file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;

            let is_qmc = header_len >= 4 && looks_like_qmc_encrypted(&header[..header_len]);

            if is_qmc {
                let file_size = file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
                let tail_size = (file_size.min(1024)) as usize;
                file.seek(SeekFrom::End(-(tail_size as i64))).map_err(|e| e.to_string())?;
                let mut tail = vec![0u8; tail_size];
                file.read_exact(&mut tail).ok();
                file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;

                let crypto = if let Some(ekey) = extract_ekey_from_footer(&tail) {
                    QmcCrypto::from_ekey(&ekey).unwrap_or_else(|_| QmcCrypto::qmc1())
                } else {
                    QmcCrypto::qmc1()
                };
                let reader = QmcDecryptReader::new(file, crypto);
                MediaSourceStream::new(Box::new(reader), Default::default())
            } else {
                MediaSourceStream::new(Box::new(file), Default::default())
            }
        };

        if !is_http {
            if let Some(ext) = std::path::Path::new(path).extension().and_then(|e| e.to_str()) {
                hint.with_extension(ext);
            }
        }

        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
            .map_err(|e| e.to_string())?;

        let track = probed
            .format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or("未找到音频轨道")?;

        let track_id = track.id;
        let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
        let channels = track
            .codec_params
            .channels
            .map(|c| c.count())
            .unwrap_or(2) as u16;

        let total_duration = track
            .codec_params
            .time_base
            .and_then(|tb| track.codec_params.n_frames.map(|n| tb.calc_time(n)))
            .map(|t| Duration::from_secs(t.seconds));

        let decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())
            .map_err(|e| e.to_string())?;

        Ok(Self {
            format_reader: probed.format,
            decoder,
            track_id,
            sample_rate,
            channels,
            total_duration,
            sample_buf: None,
            sample_buf_frames: 0,
            leftover: Vec::new(),
            eof: false,
        })
    }
}

impl BlockProducer for SymphoniaDecoder {
    fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>> {
        if self.eof {
            return None;
        }

        if !self.leftover.is_empty() {
            let take = self.leftover.len().min(max_samples);
            let out = self.leftover.drain(..take).collect::<Vec<_>>();
            return Some(out);
        }

        use symphonia::core::audio::SampleBuffer;

        loop {
            let packet = match self.format_reader.next_packet() {
                Ok(p) => p,
                Err(symphonia::core::errors::Error::ResetRequired) => {
                    self.decoder.reset();
                    continue;
                }
                Err(symphonia::core::errors::Error::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    self.eof = true;
                    return None;
                }
                Err(_) => {
                    self.eof = true;
                    return None;
                }
            };

            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                Err(_) => continue,
            };

            let frames = decoded.frames();
            if frames == 0 {
                continue;
            }

            let spec = *decoded.spec();
            if self.sample_buf.is_none() || self.sample_buf_frames < frames {
                self.sample_buf = Some(SampleBuffer::<f32>::new(frames as u64, spec));
                self.sample_buf_frames = frames;
            }

            if let Some(ref mut buf) = self.sample_buf {
                buf.copy_interleaved_ref(decoded);
                let samples = buf.samples().to_vec();
                if samples.len() > max_samples {
                    self.leftover = samples[max_samples..].to_vec();
                    return Some(samples[..max_samples].to_vec());
                }
                return Some(samples);
            }
        }
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
        use symphonia::core::formats::{SeekMode, SeekTo};
        use symphonia::core::units::Time;

        let seek_to = SeekTo::Time {
            time: Time::new(pos.as_secs(), 0.0),
            track_id: Some(self.track_id),
        };

        self.format_reader
            .seek(SeekMode::Accurate, seek_to)
            .map_err(|e| e.to_string())?;

        self.decoder.reset();
        self.leftover.clear();
        self.eof = false;
        Ok(())
    }
}
