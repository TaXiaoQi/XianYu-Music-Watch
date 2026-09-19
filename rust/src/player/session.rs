
use super::types::PlaybackSessionData;
use rusqlite::Connection;
use std::sync::{Arc, Mutex};
use std::time::{Instant, UNIX_EPOCH};

const POSITION_PERSIST_INTERVAL_MS: u128 = 5000;

pub struct PlaybackSessionState {
    inner: Arc<Mutex<PlaybackSessionData>>,
    last_position_persist: Arc<Mutex<Instant>>,
}

impl PlaybackSessionState {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(PlaybackSessionData::default())),
            last_position_persist: Arc::new(Mutex::new(Instant::now())),
        }
    }

    pub fn load_from_db(&self, conn: &Connection) -> Result<(), String> {
        let result: Result<Option<String>, rusqlite::Error> = conn
            .query_row("SELECT data FROM playback_session WHERE id = 1", [], |row| {
                row.get(0)
            })
            .map(Some)
            .or_else(|e| {
                if matches!(e, rusqlite::Error::QueryReturnedNoRows) {
                    Ok(None)
                } else {
                    Err(e)
                }
            });

        match result {
            Ok(Some(json_str)) => {
                let data: PlaybackSessionData = serde_json::from_str(&json_str)
                    .map_err(|e| format!("反序列化播放会话失败: {}", e))?;
                let mut inner = self.inner.lock().map_err(|e| e.to_string())?;
                *inner = data;
            }
            Ok(None) => {}
            Err(_) => {}
        }
        Ok(())
    }

    fn persist_to_db_internal(data: &PlaybackSessionData, conn: &Connection) -> Result<(), String> {
        let json_str =
            serde_json::to_string(data).map_err(|e| format!("序列化播放会话失败: {}", e))?;
        let now = std::time::SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        conn.execute(
            "INSERT OR REPLACE INTO playback_session (id, data, updated_at) VALUES (1, ?1, ?2)",
            rusqlite::params![json_str, now],
        )
        .map_err(|e| format!("写入播放会话失败: {}", e))?;
        Ok(())
    }

    pub fn save_playback_session(
        &self,
        conn: &Connection,
        mut session: PlaybackSessionData,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        session.updated_at = now;

        {
            let mut inner = self.inner.lock().map_err(|e| e.to_string())?;
            *inner = session.clone();
        }

        Self::persist_to_db_internal(&session, conn)?;

        {
            let mut last = self
                .last_position_persist
                .lock()
                .map_err(|e| e.to_string())?;
            *last = Instant::now();
        }

        Ok(())
    }

    pub fn update_playback_position(
        &self,
        conn: &Connection,
        position_secs: f64,
        is_playing: bool,
    ) -> Result<(), String> {
        let should_persist = {
            let mut inner = self.inner.lock().map_err(|e| e.to_string())?;
            inner.current_position_secs = position_secs;
            inner.is_playing = is_playing;

            let mut last = self
                .last_position_persist
                .lock()
                .map_err(|e| e.to_string())?;
            let elapsed = last.elapsed().as_millis();
            if elapsed >= POSITION_PERSIST_INTERVAL_MS {
                *last = Instant::now();
                true
            } else {
                false
            }
        };

        if should_persist {
            let inner = self.inner.lock().map_err(|e| e.to_string())?;
            Self::persist_to_db_internal(&inner, conn)?;
        }

        Ok(())
    }

    pub fn flush_playback_session(&self, conn: &Connection) -> Result<(), String> {
        let inner = self.inner.lock().map_err(|e| e.to_string())?;
        if inner.current_song_path.is_none() && inner.play_queue_paths.is_empty() {
            return Ok(());
        }
        Self::persist_to_db_internal(&inner, conn)?;
        Ok(())
    }

    pub fn get_playback_session(&self) -> PlaybackSessionData {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.clone()
    }
}

impl Default for PlaybackSessionState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        conn.execute_batch(
            "CREATE TABLE playback_session (
                id INTEGER PRIMARY KEY,
                data TEXT,
                updated_at INTEGER
            );",
        )
        .expect("create playback_session table");
        conn
    }

    #[test]
    fn test_state_new_defaults() {
        let state = PlaybackSessionState::new();
        let data = state.get_playback_session();
        assert!(data.current_song_path.is_none());
        assert!(data.play_queue_paths.is_empty());
    }

    #[test]
    fn test_save_then_load_round_trip() {
        let conn = setup_db();
        let state = PlaybackSessionState::new();

        let mut session = PlaybackSessionData::default();
        session.current_song_path = Some("/music/song.flac".into());
        session.play_queue_paths = vec!["/music/song.flac".into()];
        session.play_mode = 2;
        session.volume = 75.0;
        session.current_position_secs = 42.5;
        session.is_playing = true;

        state
            .save_playback_session(&conn, session.clone())
            .expect("save session");

        let state2 = PlaybackSessionState::new();
        state2.load_from_db(&conn).expect("load session");
        let loaded = state2.get_playback_session();

        assert_eq!(loaded.current_song_path, session.current_song_path);
        assert_eq!(loaded.play_queue_paths, session.play_queue_paths);
        assert_eq!(loaded.play_mode, session.play_mode);
        assert_eq!(loaded.volume, session.volume);
        assert_eq!(loaded.current_position_secs, session.current_position_secs);
        assert_eq!(loaded.is_playing, session.is_playing);
        assert!(loaded.updated_at > 0);
    }

    #[test]
    fn test_flush_skips_when_empty() {
        let conn = setup_db();
        let state = PlaybackSessionState::new();
        state.flush_playback_session(&conn).expect("flush empty ok");

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM playback_session", [], |row| row.get(0))
            .expect("count");
        assert_eq!(count, 0);
    }

    #[test]
    fn test_flutter_camel_case_json_round_trip() {
        let conn = setup_db();
        let state = PlaybackSessionState::new();

        let dart_json = r#"{
            "currentSongPath": "lx://kw/12345",
            "playQueuePaths": ["lx://kw/12345", "/music/local.flac"],
            "sourceSongPaths": ["lx://kw/12345", "/music/local.flac"],
            "playMode": 2,
            "volume": 80.0,
            "currentPositionSecs": 95.5,
            "isPlaying": true,
            "sessionQualityOverride": null,
            "queueSongMeta": {
                "lx://kw/12345": {
                    "path": "lx://kw/12345",
                    "title": "晴天",
                    "artist": "周杰伦",
                    "album": "叶惠美",
                    "durationMs": 269000,
                    "coverUrl": "https://example.com/cover.jpg",
                    "source": "kw",
                    "onlineInfoJson": "{\"songmid\":\"12345\"}"
                },
                "/music/local.flac": {
                    "path": "/music/local.flac",
                    "title": "本地歌",
                    "artist": "歌手",
                    "album": "专辑",
                    "durationMs": 200000,
                    "coverUrl": null,
                    "source": null,
                    "onlineInfoJson": null
                }
            },
            "updatedAt": 1760000000000
        }"#;

        let session: PlaybackSessionData =
            serde_json::from_str(dart_json).expect("反序列化 Dart JSON");
        assert_eq!(session.current_song_path.as_deref(), Some("lx://kw/12345"));
        assert_eq!(session.play_queue_paths.len(), 2);
        assert_eq!(session.queue_song_meta.len(), 2);

        state.save_playback_session(&conn, session).expect("save");

        let state2 = PlaybackSessionState::new();
        state2.load_from_db(&conn).expect("load");
        let loaded = state2.get_playback_session();

        assert_eq!(loaded.current_song_path.as_deref(), Some("lx://kw/12345"));
        assert_eq!(loaded.play_queue_paths.len(), 2);
        assert_eq!(loaded.play_mode, 2);
        assert_eq!(loaded.current_position_secs, 95.5);
        assert!(loaded.is_playing);
        assert_eq!(loaded.queue_song_meta.len(), 2);
        let meta = loaded
            .queue_song_meta
            .get("lx://kw/12345")
            .expect("在线曲目元数据");
        assert_eq!(meta["title"], "晴天");
        assert_eq!(meta["source"], "kw");
    }

    #[test]
    fn test_update_position_persists_after_interval() {
        let conn = setup_db();
        let state = PlaybackSessionState::new();

        let mut session = PlaybackSessionData::default();
        session.current_song_path = Some("/music/song.flac".into());
        state
            .save_playback_session(&conn, session)
            .expect("save session");

        state
            .update_playback_position(&conn, 10.0, true)
            .expect("update position");
        assert_eq!(state.get_playback_session().current_position_secs, 10.0);

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM playback_session", [], |row| row.get(0))
            .expect("count");
        assert_eq!(count, 1);
    }
}