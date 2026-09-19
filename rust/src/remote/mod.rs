pub mod types;
pub mod webdav;
pub(crate) mod cache;
pub(crate) mod repository;
pub(crate) mod scanner;

use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}