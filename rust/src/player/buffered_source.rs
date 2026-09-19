
use std::collections::VecDeque;
use std::marker::PhantomData;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

pub const BLOCK_SAMPLES: usize = 1024;

const CHANNEL_BLOCKS: usize = 64;

const BACKOFF: Duration = Duration::from_micros(400);

#[cfg(test)]
const CONSUMER_WAIT_TIMEOUT: Duration = Duration::from_millis(500);
#[cfg(not(test))]
const CONSUMER_WAIT_TIMEOUT: Duration = BACKOFF;

#[cfg(target_os = "windows")]
#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentThread() -> isize;
    fn SetThreadPriority(handle: isize, priority: i32) -> i32;
}
#[cfg(target_os = "windows")]
const THREAD_PRIORITY_ABOVE_NORMAL: i32 = 1;

#[cfg(target_os = "windows")]
fn elevate_thread_priority() {
    unsafe {
        let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    }
}
#[cfg(not(target_os = "windows"))]
#[inline]
fn elevate_thread_priority() {}

enum Command {
    Seek(Duration),
    Stop,
}

enum SeekAck {
    Ok,
    Failed,
}

pub struct BufferedMonitor {
    pub starved: AtomicBool,
    pub produced: AtomicBool,
}

impl BufferedMonitor {
    pub fn new() -> Self {
        Self {
            starved: AtomicBool::new(false),
            produced: AtomicBool::new(false),
        }
    }
}

impl Default for BufferedMonitor {
    fn default() -> Self {
        Self::new()
    }
}

pub trait BlockProducer {
    fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>>;
    fn try_seek(&mut self, pos: Duration) -> Result<(), String>;
}

pub struct BufferedSource<P> {
    sample_rx: Receiver<Vec<f32>>,
    cmd_tx: SyncSender<Command>,
    ack_rx: Receiver<SeekAck>,
    sample_rate: u32,
    channels: u16,
    total_duration: Option<Duration>,
    current_block: VecDeque<f32>,
    exhausted: bool,
    monitor: Option<Arc<BufferedMonitor>>,
    thread_handle: Option<thread::JoinHandle<()>>,
    _marker: PhantomData<P>,
}

impl<P> BufferedSource<P>
where
    P: BlockProducer + Send + 'static,
{
    #[inline]
    fn set_starvation(&self, value: bool) {
        if let Some(monitor) = &self.monitor {
            monitor.starved.store(value, Ordering::Relaxed);
        }
    }

    pub fn new(
        producer: P,
        sample_rate: u32,
        channels: u16,
        total_duration: Option<Duration>,
    ) -> Self {
        Self::new_tracked(producer, sample_rate, channels, total_duration, None)
    }

    pub fn new_tracked(
        producer: P,
        sample_rate: u32,
        channels: u16,
        total_duration: Option<Duration>,
        monitor: Option<Arc<BufferedMonitor>>,
    ) -> Self {
        let (cmd_tx, cmd_rx) = mpsc::sync_channel::<Command>(8);
        let (sample_tx, sample_rx) = mpsc::sync_channel::<Vec<f32>>(CHANNEL_BLOCKS);
        let (ack_tx, ack_rx) = mpsc::channel::<SeekAck>();

        let stop_flag = Arc::new(AtomicBool::new(false));
        let stop_flag_clone = stop_flag.clone();
        let monitor_clone = monitor.clone();

        let thread_handle = thread::Builder::new()
            .name("xy-buffered-source".to_string())
            .spawn(move || producer_loop(producer, cmd_rx, sample_tx, ack_tx, stop_flag_clone, monitor_clone))
            .ok();

        let mut source = Self {
            sample_rx,
            cmd_tx,
            ack_rx,
            sample_rate,
            channels,
            total_duration,
            current_block: VecDeque::with_capacity(BLOCK_SAMPLES),
            exhausted: false,
            monitor,
            thread_handle,
            _marker: PhantomData,
        };
        source.prefill_one_block();
        source
    }

    fn prefill_one_block(&mut self) {
        const PREFILL_TIMEOUT: Duration = Duration::from_millis(500);
        match self.sample_rx.recv_timeout(PREFILL_TIMEOUT) {
            Ok(block) => {
                self.set_starvation(false);
                if block.is_empty() {
                    self.exhausted = true;
                } else {
                    self.current_block = block.into_iter().collect();
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                self.exhausted = true;
            }
        }
    }

    pub fn channel_capacity(&self) -> usize {
        CHANNEL_BLOCKS
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> u16 {
        self.channels
    }

    pub fn total_duration(&self) -> Option<Duration> {
        self.total_duration
    }

    pub fn next_block(&mut self) -> Option<Vec<f32>> {
        if self.exhausted {
            return None;
        }

        if !self.current_block.is_empty() {
            let out: Vec<f32> = self.current_block.drain(..).collect();
            return Some(out);
        }

        match self.sample_rx.recv_timeout(CONSUMER_WAIT_TIMEOUT) {
            Ok(block) => {
                self.set_starvation(false);
                if block.is_empty() {
                    self.exhausted = true;
                    None
                } else {
                    Some(block)
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.set_starvation(true);
                Some(vec![0.0; BLOCK_SAMPLES])
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                self.exhausted = true;
                self.set_starvation(false);
                None
            }
        }
    }

    pub fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
        if self.cmd_tx.send(Command::Seek(pos)).is_err() {
            return Err("BufferedSource 后台线程已退出".to_string());
        }

        match self.ack_rx.recv_timeout(Duration::from_secs(2)) {
            Ok(SeekAck::Ok) => {}
            _ => return Err("BufferedSource seek 失败或超时".to_string()),
        }

        while self.sample_rx.try_recv().is_ok() {}
        self.current_block.clear();
        self.exhausted = false;
        self.prefill_one_block();
        Ok(())
    }
}

fn producer_loop<P: BlockProducer + Send>(
    mut producer: P,
    cmd_rx: Receiver<Command>,
    sample_tx: SyncSender<Vec<f32>>,
    ack_tx: std::sync::mpsc::Sender<SeekAck>,
    stop_flag: Arc<AtomicBool>,
    monitor: Option<Arc<BufferedMonitor>>,
) {
    elevate_thread_priority();

    let mut eof = false;

    loop {
        if stop_flag.load(Ordering::Relaxed) {
            return;
        }

        match cmd_rx.try_recv() {
            Ok(Command::Stop) => return,
            Ok(Command::Seek(pos)) => {
                let ack = if producer.try_seek(pos).is_ok() {
                    SeekAck::Ok
                } else {
                    SeekAck::Failed
                };
                let _ = ack_tx.send(ack);
                eof = false;
                continue;
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => return,
        }

        if eof {
            match cmd_rx.recv_timeout(BACKOFF) {
                Ok(Command::Stop) => return,
                Ok(Command::Seek(pos)) => {
                    let _ = ack_tx.send(if producer.try_seek(pos).is_ok() {
                        SeekAck::Ok
                    } else {
                        SeekAck::Failed
                    });
                    eof = false;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if stop_flag.load(Ordering::Relaxed) {
                        return;
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
            continue;
        }

        let block = match producer.produce(BLOCK_SAMPLES) {
            Some(b) => b,
            None => {
                return;
            }
        };

        if !block.is_empty() {
            let mut block = block;
            loop {
                if stop_flag.load(Ordering::Relaxed) {
                    return;
                }
                match cmd_rx.try_recv() {
                    Ok(Command::Stop) => return,
                    Ok(Command::Seek(pos)) => {
                        let _ = ack_tx.send(if producer.try_seek(pos).is_ok() {
                            SeekAck::Ok
                        } else {
                            SeekAck::Failed
                        });
                        eof = false;
                        break;
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                    Err(mpsc::TryRecvError::Disconnected) => return,
                }

                match sample_tx.try_send(block) {
                    Ok(()) => {
                        if let Some(monitor) = &monitor {
                            monitor.produced.store(true, Ordering::Relaxed);
                        }
                        break;
                    }
                    Err(mpsc::TrySendError::Full(b)) => {
                        block = b;
                        thread::sleep(BACKOFF);
                    }
                    Err(mpsc::TrySendError::Disconnected(_)) => return,
                }
            }
        }

        if eof {
            return;
        }
    }
}

impl<P> Drop for BufferedSource<P> {
    fn drop(&mut self) {
        let _ = self.cmd_tx.try_send(Command::Stop);
        if let Some(handle) = self.thread_handle.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct SineProducer {
        samples: Vec<f32>,
        idx: usize,
    }

    impl SineProducer {
        fn new(rate: u32, ch: u16, secs: f32) -> Self {
            let n = (secs * rate as f32 * ch as f32).round() as usize;
            let samples: Vec<f32> = (0..n)
                .map(|i| {
                    let t = i as f32 / (rate * ch as u32) as f32;
                    (t * 440.0 * std::f32::consts::TAU).sin() * 0.5
                })
                .collect();
            Self { samples, idx: 0 }
        }
    }

    impl BlockProducer for SineProducer {
        fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>> {
            if self.idx >= self.samples.len() {
                return None;
            }
            let end = (self.idx + max_samples).min(self.samples.len());
            let out = self.samples[self.idx..end].to_vec();
            self.idx = end;
            Some(out)
        }
        fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
            self.idx = (pos.as_secs_f64() * 44100.0 * 2.0).round() as usize;
            self.idx = self.idx.min(self.samples.len());
            Ok(())
        }
    }

    #[test]
    fn passthrough_preserves_samples() {
        let inner = SineProducer::new(44100, 2, 1.0);
        let expected: Vec<f32> = (0..44100 * 2)
            .map(|i| {
                let t = i as f32 / (44100 * 2) as f32;
                (t * 440.0 * std::f32::consts::TAU).sin() * 0.5
            })
            .collect();

        let mut buf = BufferedSource::new(inner, 44100, 2, Some(Duration::from_secs(1)));
        let mut out = Vec::with_capacity(expected.len());
        while let Some(block) = buf.next_block() {
            out.extend_from_slice(&block);
            if out.len() >= expected.len() {
                break;
            }
        }

        assert_eq!(out.len(), expected.len(), "样本数应一致");
        for (i, (a, b)) in out.iter().zip(expected.iter()).enumerate() {
            assert!((a - b).abs() < 1e-6, "样本 {} 不匹配: {} vs {}", i, a, b);
        }
    }

    #[test]
    fn reports_metadata() {
        let inner = SineProducer::new(48000, 2, 2.0);
        let buf = BufferedSource::new(inner, 48000, 2, Some(Duration::from_secs(2)));
        assert_eq!(buf.sample_rate, 48000);
        assert_eq!(buf.channels, 2);
        assert_eq!(buf.total_duration, Some(Duration::from_secs(2)));
    }

    #[test]
    fn eof_returns_none() {
        let inner = SineProducer::new(44100, 1, 0.05);
        let expected_samples = 2205;
        let mut buf = BufferedSource::new(inner, 44100, 1, Some(Duration::from_millis(50)));
        let mut non_zero = 0;
        let mut total = 0;
        while let Some(block) = buf.next_block() {
            non_zero += block.iter().filter(|&&s| s.abs() > 1e-6).count();
            total += block.len();
            if total > expected_samples + 5000 {
                panic!("EOF 未正确检测，产生过多样本");
            }
        }
        assert!(non_zero > 0, "应产生非零样本");
    }

    #[test]
    fn seek_resets_position() {
        let inner = SineProducer::new(44100, 2, 2.0);
        let mut buf = BufferedSource::new(inner, 44100, 2, Some(Duration::from_secs(2)));

        buf.try_seek(Duration::from_millis(500)).unwrap();
        let mut got = Vec::new();
        for _ in 0..1000 {
            if let Some(block) = buf.next_block() {
                got.extend_from_slice(&block);
            }
        }
        let non_zero = got.iter().filter(|&&s| s.abs() > 1e-6).count();
        assert!(non_zero > 0, "seek 后应有有效音频样本");
    }

    #[test]
    fn handles_empty_source() {
        struct Empty;
        impl BlockProducer for Empty {
            fn produce(&mut self, _max_samples: usize) -> Option<Vec<f32>> {
                None
            }
            fn try_seek(&mut self, _pos: Duration) -> Result<(), String> {
                Ok(())
            }
        }

        let mut buf = BufferedSource::new(Empty, 44100, 2, Some(Duration::ZERO));
        let mut none_count = 0;
        for _ in 0..2000 {
            match buf.next_block() {
                Some(b) if b.iter().all(|&s| s == 0.0) => {  }
                Some(_) => panic!("空源不应产生非零样本"),
                None => {
                    none_count += 1;
                    break;
                }
            }
        }
        assert!(none_count > 0, "空源最终应返回 None");
    }
}