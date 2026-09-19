
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct CookieEntry {
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub domain: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct PluginStoreData {
    #[serde(default)]
    pub cookies: HashMap<String, CookieEntry>,
    #[serde(default)]
    pub storage: HashMap<String, String>,
}

pub struct PluginStore {
    data: Mutex<PluginStoreData>,
    path: Option<std::path::PathBuf>,
    dirty: AtomicBool,
    last_persist_secs: AtomicU64,
}

fn url_hostname(url: &str) -> String {
    url::Url::parse(url)
        .map(|u| u.host_str().unwrap_or_default().to_lowercase())
        .unwrap_or_default()
}

impl PluginStore {
    pub fn load(path: Option<std::path::PathBuf>) -> Self {
        let data = path
            .as_deref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|raw| serde_json::from_str::<PluginStoreData>(&raw).ok())
            .unwrap_or_default();
        Self {
            data: Mutex::new(data),
            path,
            dirty: AtomicBool::new(false),
            last_persist_secs: AtomicU64::new(0),
        }
    }

    fn persist(&self, data: &PluginStoreData) {
        let Some(path) = &self.path else { return };
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        if let Ok(json) = serde_json::to_string(data) {
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(&tmp, path);
            }
        }
    }

    fn unix_secs() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }

    fn persist_throttled(&self, data: &PluginStoreData) {
        self.dirty.store(true, Ordering::Release);
        let now = Self::unix_secs();
        if now.saturating_sub(self.last_persist_secs.load(Ordering::Relaxed)) < 2 {
            return;
        }
        self.last_persist_secs.store(now, Ordering::Relaxed);
        self.dirty.store(false, Ordering::Release);
        self.persist(data);
    }

    pub fn flush_if_dirty(&self) {
        if !self.dirty.swap(false, Ordering::AcqRel) {
            return;
        }
        self.last_persist_secs.store(Self::unix_secs(), Ordering::Relaxed);
        let data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        self.persist(&data);
    }

    pub fn set_cookie(&self, url: &str, name: &str, value: &str, domain: Option<&str>) -> bool {
        let host = url_hostname(url);
        if name.is_empty() {
            return false;
        }
        let mut data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        let domain = domain
            .filter(|d| !d.is_empty())
            .map(|d| d.to_string())
            .unwrap_or(host);
        data.cookies.insert(
            name.to_string(),
            CookieEntry {
                value: value.to_string(),
                domain,
            },
        );
        self.persist_throttled(&data);
        true
    }

    pub fn get_cookies_for_url(&self, url: &str) -> HashMap<String, CookieEntry> {
        let host = url_hostname(url);
        if host.is_empty() {
            return HashMap::new();
        }
        let data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        data.cookies
            .iter()
            .filter(|(_, c)| {
                !c.domain.is_empty()
                    && (host.contains(&c.domain) || c.domain.contains(&host))
            })
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    pub fn cookie_header_for_url(&self, url: &str) -> String {
        self.get_cookies_for_url(url)
            .iter()
            .map(|(name, c)| format!("{}={}", name, c.value))
            .collect::<Vec<_>>()
            .join("; ")
    }

    pub fn cookie_header_for_domain(&self, domain_filter: &str) -> String {
        let filter = domain_filter.to_lowercase();
        let data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        data.cookies
            .iter()
            .filter(|(_, c)| c.domain.to_lowercase().contains(&filter) && !c.value.is_empty())
            .map(|(name, c)| format!("{}={}", name, c.value))
            .collect::<Vec<_>>()
            .join("; ")
    }

    pub fn capture_set_cookies(&self, url: &str, set_cookie_values: &[String]) {
        if set_cookie_values.is_empty() {
            return;
        }
        let host = url_hostname(url);
        if host.is_empty() {
            return;
        }
        let mut changed = false;
        let mut data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        for raw in set_cookie_values {
            let first = raw.split(';').next().unwrap_or("");
            let mut parts = first.splitn(2, '=');
            let name = parts.next().unwrap_or("").trim();
            let value = parts.next().unwrap_or("").trim();
            if name.is_empty() || value.is_empty() {
                continue;
            }
            data.cookies.insert(
                name.to_string(),
                CookieEntry {
                    value: value.to_string(),
                    domain: host.clone(),
                },
            );
            changed = true;
        }
        if changed {
            self.persist_throttled(&data);
        }
    }

    pub fn storage_set(&self, key: &str, value: &str) {
        let mut data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        data.storage.insert(key.to_string(), value.to_string());
        self.persist_throttled(&data);
    }

    pub fn storage_get(&self, key: &str) -> Option<String> {
        self.data.lock().unwrap_or_else(|e| e.into_inner()).storage.get(key).cloned()
    }

    pub fn storage_remove(&self, key: &str) {
        let mut data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        if data.storage.remove(key).is_some() {
            self.persist_throttled(&data);
        }
    }

    pub fn import_local(
        &self,
        cookies: HashMap<String, CookieEntry>,
        storage: HashMap<String, String>,
    ) {
        let mut changed = false;
        let mut data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        for (name, entry) in cookies {
            if name.is_empty() || entry.value.is_empty() {
                continue;
            }
            data.cookies.entry(name).or_insert(entry);
            changed = true;
        }
        for (key, value) in storage {
            data.storage.entry(key).or_insert(value);
            changed = true;
        }
        if changed {
            self.persist_throttled(&data);
        }
    }

    pub fn upsert_cookies(&self, cookies: HashMap<String, CookieEntry>) {
        let mut changed = false;
        let mut data = self.data.lock().unwrap_or_else(|e| e.into_inner());
        for (name, entry) in cookies {
            if name.is_empty() || entry.value.is_empty() {
                continue;
            }
            data.cookies.insert(name, entry);
            changed = true;
        }
        if changed {
            self.persist_throttled(&data);
        }
    }

    pub fn cookie_snapshot(&self) -> HashMap<String, CookieEntry> {
        self.data.lock().unwrap_or_else(|e| e.into_inner()).cookies.clone()
    }

    pub fn storage_snapshot(&self) -> HashMap<String, String> {
        self.data.lock().unwrap_or_else(|e| e.into_inner()).storage.clone()
    }
}

impl Drop for PluginStore {
    fn drop(&mut self) {
        self.flush_if_dirty();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_roundtrip_and_domain_match() {
        let store = PluginStore::load(None);
        assert!(store.set_cookie(
            "https://www.bilibili.com/x",
            "SESSDATA",
            "abc123",
            None
        ));
        assert!(store.set_cookie(
            "https://api.kugou.com/v1",
            "kg_token",
            "xyz",
            None
        ));

        let header = store.cookie_header_for_url("https://www.bilibili.com/foo");
        assert!(header.contains("SESSDATA=abc123"));
        assert!(!header.contains("kg_token"));
        let api = store.cookie_header_for_url("https://api.bilibili.com/foo");
        assert!(!api.contains("SESSDATA"));

        let bili = store.cookie_header_for_domain("bilibili");
        assert!(bili.contains("SESSDATA=abc123"));
        assert!(!bili.contains("kg_token"));
    }

    #[test]
    fn upsert_cookies_overwrites_existing_value() {
        let store = PluginStore::load(None);
        assert!(store.set_cookie(
            "https://www.bilibili.com/x",
            "SESSDATA",
            "old_value",
            None
        ));
        let mut m = HashMap::new();
        m.insert(
            "SESSDATA".to_string(),
            CookieEntry {
                value: "new_value".to_string(),
                domain: "bilibili.com".to_string(),
            },
        );
        store.import_local(m.clone(), HashMap::new());
        assert!(store.cookie_header_for_domain("bilibili").contains("old_value"));
        store.upsert_cookies(m);
        let header = store.cookie_header_for_domain("bilibili");
        assert!(header.contains("SESSDATA=new_value"));
        assert!(!header.contains("old_value"));
        let mut empty = HashMap::new();
        empty.insert(
            "buvid3".to_string(),
            CookieEntry {
                value: String::new(),
                domain: "bilibili.com".to_string(),
            },
        );
        store.upsert_cookies(empty);
        assert!(!store
            .cookie_header_for_domain("bilibili")
            .contains("buvid3"));
    }

    #[test]
    fn capture_set_cookies_parses_attributes() {
        let store = PluginStore::load(None);
        store.capture_set_cookies(
            "https://y.qq.com/api",
            &[
                "uin=12345; Path=/; Domain=.qq.com; HttpOnly".to_string(),
                "qqmusic_key=QK_; expires=Fri, 01-Jan-2027".to_string(),
                "invalid".to_string(),
            ],
        );
        let header = store.cookie_header_for_url("https://y.qq.com/");
        assert!(header.contains("uin=12345"));
        assert!(header.contains("qqmusic_key=QK"));
    }

    #[test]
    fn storage_ops() {
        let store = PluginStore::load(None);
        store.storage_set("plugin-a/state", "{\"v\":1}");
        assert_eq!(
            store.storage_get("plugin-a/state").as_deref(),
            Some("{\"v\":1}")
        );
        store.storage_remove("plugin-a/state");
        assert!(store.storage_get("plugin-a/state").is_none());
    }

    #[test]
    fn import_local_keeps_rust_entries() {
        let store = PluginStore::load(None);
        store.set_cookie("https://a.com/", "k", "rust", None);
        let mut cookies = HashMap::new();
        cookies.insert(
            "k".to_string(),
            CookieEntry {
                value: "local".to_string(),
                domain: "a.com".to_string(),
            },
        );
        cookies.insert(
            "new".to_string(),
            CookieEntry {
                value: "v".to_string(),
                domain: "b.com".to_string(),
            },
        );
        store.import_local(cookies, HashMap::new());
        assert_eq!(store.cookie_header_for_url("https://a.com/"), "k=rust");
        assert_eq!(store.cookie_header_for_url("https://b.com/"), "new=v");
    }
}
