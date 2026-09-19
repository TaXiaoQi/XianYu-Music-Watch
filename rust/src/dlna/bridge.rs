
use super::types::{DmrHost, DmrPlaybackReport, TransportState};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone)]
struct Snapshot {
    state: TransportState,
    position_secs: f64,
    duration_secs: f64,
    volume_percent: u8,
    muted: bool,
}

impl Default for Snapshot {
    fn default() -> Self {
        Self {
            state: TransportState::NoMedia,
            position_secs: 0.0,
            duration_secs: 0.0,
            volume_percent: 100,
            muted: false,
        }
    }
}

fn snapshot() -> &'static Mutex<Snapshot> {
    static SNAP: OnceLock<Mutex<Snapshot>> = OnceLock::new();
    SNAP.get_or_init(|| Mutex::new(Snapshot::default()))
}

pub fn report_playback(
    state: TransportState,
    position_secs: f64,
    duration_secs: f64,
    volume_percent: u8,
    muted: bool,
) {
    let mut snap = snapshot().lock().unwrap_or_else(|e| e.into_inner());
    snap.state = state;
    snap.position_secs = position_secs.max(0.0);
    snap.duration_secs = duration_secs.max(0.0);
    snap.volume_percent = volume_percent.clamp(0, 100);
    snap.muted = muted;
}

pub fn reset_playback() {
    *snapshot().lock().unwrap_or_else(|e| e.into_inner()) = Snapshot::default();
}

struct MobileDmrHost;

impl DmrHost for MobileDmrHost {
    fn playback_snapshot(&self) -> DmrPlaybackReport {
        let snap = snapshot().lock().unwrap_or_else(|e| e.into_inner());
        DmrPlaybackReport {
            state: snap.state,
            position_secs: snap.position_secs,
            duration_secs: snap.duration_secs,
        }
    }

    fn volume_snapshot(&self) -> (u8, bool) {
        let snap = snapshot().lock().unwrap_or_else(|e| e.into_inner());
        (snap.volume_percent, snap.muted)
    }
}

pub fn host() -> Arc<dyn DmrHost> {
    Arc::new(MobileDmrHost)
}
