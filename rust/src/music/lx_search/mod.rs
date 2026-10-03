use crate::music::url_resolver::LxTypeEntry;
use base64::Engine;
use regex::Regex;
use serde::Serialize;
use sha1::{Digest, Sha1};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

mod kg;
mod kw;
mod mg;
mod tx;
mod wy;

pub use tx::{tx_album_songs, tx_batch_track_interval, tx_search_albums};

pub(crate) use kg::*;
pub(crate) use kw::*;
pub(crate) use mg::*;
pub(crate) use tx::*;
pub(crate) use wy::*;

#[derive(Serialize, Clone, Debug)]
pub struct LxSearchItem {
    pub name: String,
    pub singer: String,
    pub album_name: String,
    pub album_id: serde_json::Value,
    pub songmid: String,
    pub source: String,
    pub interval: String,
    pub img: Option<String>,
    pub hash: Option<String>,
    pub str_media_mid: Option<String>,
    pub song_id: Option<serde_json::Value>,
    pub album_mid: Option<String>,
    pub copyright_id: Option<String>,
    pub types: Vec<LxTypeTuple>,
    pub lx_types: Option<HashMap<String, LxTypeEntry>>,
}

#[derive(Serialize, Clone, Debug)]
pub struct LxTypeTuple {
    #[serde(rename = "type")]
    pub quality_type: String,
    pub size: Option<String>,
    pub hash: Option<String>,
}

struct SearchCacheEntry {
    items: Vec<LxSearchItem>,
    expires_at: Instant,
    last_access: Instant,
}

static SEARCH_CACHE: OnceLock<Arc<RwLock<HashMap<String, SearchCacheEntry>>>> = OnceLock::new();

fn search_cache() -> &'static Arc<RwLock<HashMap<String, SearchCacheEntry>>> {
    SEARCH_CACHE.get_or_init(|| Arc::new(RwLock::new(HashMap::new())))
}

const SEARCH_CACHE_TTL_SECS: u64 = 300;
const SEARCH_CACHE_MAX_ENTRIES: usize = 200;

fn make_search_cache_key(source: &str, keyword: &str, limit: u32) -> String {
    format!("{}/{}/{}", source, keyword, limit)
}

async fn get_cached_search(source: &str, keyword: &str, limit: u32) -> Option<Vec<LxSearchItem>> {
    let key = make_search_cache_key(source, keyword, limit);
    let mut cache = search_cache().write().await;
    let now = Instant::now();
    let entry = cache.get_mut(&key)?;
    if entry.expires_at <= now {
        cache.remove(&key);
        return None;
    }
    entry.last_access = now;
    Some(entry.items.clone())
}

async fn set_cached_search(source: &str, keyword: &str, limit: u32, items: Vec<LxSearchItem>) {
    let mut cache = search_cache().write().await;
    let key = make_search_cache_key(source, keyword, limit);
    let now = Instant::now();
    cache.insert(
        key,
        SearchCacheEntry {
            items,
            expires_at: now + Duration::from_secs(SEARCH_CACHE_TTL_SECS),
            last_access: now,
        },
    );

    evict_search_cache(&mut cache, now);
}

fn evict_search_cache(cache: &mut HashMap<String, SearchCacheEntry>, now: Instant) {
    cache.retain(|_, e| e.expires_at > now);
    let excess = cache.len().saturating_sub(SEARCH_CACHE_MAX_ENTRIES);
    if excess == 0 {
        return;
    }
    let mut keys: Vec<(String, Instant)> = cache
        .iter()
        .map(|(k, e)| (k.clone(), e.last_access))
        .collect();
    keys.sort_unstable_by_key(|(_, t)| *t);
    for (k, _) in keys.into_iter().take(excess) {
        cache.remove(&k);
    }
}

pub async fn clear_lx_search_cache() {
    let mut cache = search_cache().write().await;
    cache.clear();
}

pub(crate) fn format_play_time(seconds: f64) -> String {
    if seconds.is_nan() || seconds <= 0.0 {
        return "00:00".to_string();
    }
    let total = seconds as u64;
    let m = total / 60;
    let s = total % 60;
    format!("{:02}:{:02}", m, s)
}

pub(crate) fn size_formate(bytes: f64) -> String {
    if bytes <= 0.0 {
        return "0B".to_string();
    }
    if bytes < 1024.0 {
        return format!("{}B", bytes as u64);
    }
    if bytes < 1024.0 * 1024.0 {
        return format!("{:.1}KB", bytes / 1024.0);
    }
    if bytes < 1024.0 * 1024.0 * 1024.0 {
        return format!("{:.1}MB", bytes / (1024.0 * 1024.0));
    }
    format!("{:.1}GB", bytes / (1024.0 * 1024.0 * 1024.0))
}

static HTML_NUMERIC_RE: OnceLock<Regex> = OnceLock::new();

fn decode_numeric_entities(s: &str) -> String {
    let re = HTML_NUMERIC_RE.get_or_init(|| Regex::new(r"&#(x?[0-9a-fA-F]+);").unwrap());
    re.replace_all(s, |caps: &regex::Captures| {
        let digits = &caps[1];
        let parsed = if let Some(hex) = digits
            .strip_prefix('x')
            .or_else(|| digits.strip_prefix('X'))
        {
            u32::from_str_radix(hex, 16)
        } else {
            digits.parse::<u32>()
        };
        match parsed {
            Ok(cp) if cp != 0 => char::from_u32(cp)
                .map(|c| c.to_string())
                .unwrap_or_else(|| caps[0].to_string()),
            _ => caps[0].to_string(),
        }
    })
    .into_owned()
}

pub(crate) fn decode_name(s: &str) -> String {
    let named = s
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ");
    decode_numeric_entities(&named)
}

pub(crate) fn format_singer_name(singers: &serde_json::Value, name_key: &str) -> String {
    if let Some(arr) = singers.as_array() {
        let names: Vec<String> = arr
            .iter()
            .filter_map(|item| {
                item.get(name_key)
                    .and_then(|n| n.as_str())
                    .map(|s| decode_name(s.trim()))
                    .filter(|s| !s.is_empty())
            })
            .collect();
        return names.join("、");
    }
    if let Some(s) = singers.as_str() {
        return decode_name(s);
    }
    String::new()
}

static HTTP_CLIENT: OnceLock<Result<reqwest::Client, String>> = OnceLock::new();

fn http_client() -> &'static Result<reqwest::Client, String> {
    HTTP_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
            .build()
            .map_err(|e| e.to_string())
    })
}

pub(crate) async fn http_get_json(url: &str, headers: &[(&str, &str)]) -> Result<serde_json::Value, String> {
    let client = http_client().as_ref().map_err(|e| e.clone())?;
    let mut req = client.get(url);
    for (key, value) in headers {
        req = req.header(*key, *value);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|e| e.to_string())?;

    if status != 200 {
        return Err(format!("HTTP {} for {}", status, url));
    }

    serde_json::from_str(&body).map_err(|e| format!("Invalid JSON: {}", e))
}

pub(crate) async fn http_post_json(
    url: &str,
    body: &str,
    headers: &[(&str, &str)],
) -> Result<serde_json::Value, String> {
    let client = http_client().as_ref().map_err(|e| e.clone())?;
    let mut req = client.post(url).body(body.to_string());
    for (key, value) in headers {
        req = req.header(*key, *value);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body_text = resp.text().await.map_err(|e| e.to_string())?;

    if status != 200 {
        return Err(format!("HTTP {} for {}", status, url));
    }

    serde_json::from_str(&body_text).map_err(|e| format!("Invalid JSON: {}", e))
}

pub async fn lx_search(
    source: &str,
    keyword: &str,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let default_limit = match source {
        "tx" => 50,
        "mg" => 20,
        _ => 30,
    };
    let actual_limit = if limit == 0 { default_limit } else { limit };

    if let Some(cached) = get_cached_search(source, keyword, actual_limit).await {
        return Ok(cached);
    }

    let items = match source {
        "kw" => search_kw(keyword, actual_limit).await,
        "kg" => search_kg(keyword, actual_limit).await,
        "tx" => search_tx(keyword, actual_limit).await,
        "wy" => search_wy(keyword, actual_limit).await,
        "mg" => search_mg(keyword, actual_limit).await,
        _ => Err(format!("Unknown LX source: {}", source)),
    }?;

    set_cached_search(source, keyword, actual_limit, items.clone()).await;

    Ok(items)
}

#[allow(dead_code)]
pub async fn clear_lx_all_cache() -> Result<(), String> {
    clear_lx_search_cache().await;
    let _ = crate::music::url_resolver::clear_lx_url_cache().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ===== format_play_time =====

    #[test]
    fn test_format_play_time_zero() {
        assert_eq!(format_play_time(0.0), "00:00");
    }

    #[test]
    fn test_format_play_time_negative() {
        assert_eq!(format_play_time(-5.0), "00:00");
    }

    #[test]
    fn test_format_play_time_nan() {
        assert_eq!(format_play_time(f64::NAN), "00:00");
    }

    #[test]
    fn test_format_play_time_seconds_only() {
        assert_eq!(format_play_time(45.0), "00:45");
    }

    #[test]
    fn test_format_play_time_minutes_and_seconds() {
        assert_eq!(format_play_time(125.0), "02:05");
    }

    #[test]
    fn test_format_play_time_large_value() {
        assert_eq!(format_play_time(3661.0), "61:01");
    }

    #[test]
    fn test_format_play_time_truncates_fractional() {
        assert_eq!(format_play_time(65.7), "01:05");
    }

    // ===== size_formate =====

    #[test]
    fn test_size_formate_zero() {
        assert_eq!(size_formate(0.0), "0B");
    }

    #[test]
    fn test_size_formate_negative() {
        assert_eq!(size_formate(-100.0), "0B");
    }

    #[test]
    fn test_size_formate_bytes() {
        assert_eq!(size_formate(512.0), "512B");
    }

    #[test]
    fn test_size_formate_kilobytes() {
        assert_eq!(size_formate(2048.0), "2.0KB");
    }

    #[test]
    fn test_size_formate_megabytes() {
        assert_eq!(size_formate(1048576.0), "1.0MB");
    }

    #[test]
    fn test_size_formate_gigabytes() {
        assert_eq!(size_formate(1073741824.0), "1.0GB");
    }

    // ===== decode_name =====

    #[test]
    fn test_decode_name_amp() {
        assert_eq!(decode_name("Tom &amp; Jerry"), "Tom & Jerry");
    }

    #[test]
    fn test_decode_name_lt_gt() {
        assert_eq!(decode_name("&lt;tag&gt;"), "<tag>");
    }

    #[test]
    fn test_decode_name_quot() {
        assert_eq!(decode_name("&quot;hello&quot;"), "\"hello\"");
    }

    #[test]
    fn test_decode_name_multiple_entities() {
        assert_eq!(
            decode_name("&amp;&lt;&gt;&quot;&#39;&apos;&nbsp;"),
            "&<>\"'' "
        );
    }

    #[test]
    fn test_decode_name_no_entities() {
        assert_eq!(decode_name("plain text"), "plain text");
    }

    // ===== format_singer_name =====

    #[test]
    fn test_format_singer_name_array() {
        let singers = serde_json::json!([
            {"name": "周杰伦"},
            {"name": "方文山"}
        ]);
        assert_eq!(format_singer_name(&singers, "name"), "周杰伦、方文山");
    }

    #[test]
    fn test_format_singer_name_string() {
        let singers = serde_json::json!("陈奕迅");
        assert_eq!(format_singer_name(&singers, "name"), "陈奕迅");
    }

    #[test]
    fn test_format_singer_name_empty_array() {
        let singers = serde_json::json!([]);
        assert_eq!(format_singer_name(&singers, "name"), "");
    }

    #[test]
    fn test_format_singer_name_skips_empty_names() {
        let singers = serde_json::json!([
            {"name": "  "},
            {"name": "李荣浩"}
        ]);
        assert_eq!(format_singer_name(&singers, "name"), "李荣浩");
    }

    #[test]
    fn test_format_singer_name_null() {
        let singers = serde_json::Value::Null;
        assert_eq!(format_singer_name(&singers, "name"), "");
    }

    // ===== build_kuwo_cover_url =====

    #[test]
    fn test_build_kuwo_cover_url_normal() {
        let url = build_kuwo_cover_url("/120/albumcover/abc.jpg", 500);
        assert_eq!(
            url.as_deref(),
            Some("https://img3.kuwo.cn/star/albumcover/500/albumcover/abc.jpg")
        );
    }

    #[test]
    fn test_build_kuwo_cover_url_empty() {
        assert_eq!(build_kuwo_cover_url("", 500), None);
    }

    #[test]
    fn test_build_kuwo_cover_url_whitespace_only() {
        assert_eq!(build_kuwo_cover_url("   ", 500), None);
    }

    #[test]
    fn test_build_kuwo_cover_url_no_leading_size() {
        let url = build_kuwo_cover_url("albumcover/abc.jpg", 300);
        assert_eq!(
            url.as_deref(),
            Some("https://img3.kuwo.cn/star/albumcover/albumcover/abc.jpg")
        );
    }

    // ===== build_kugou_cover_url =====

    #[test]
    fn test_build_kugou_cover_url_with_size_placeholder() {
        let url = build_kugou_cover_url("http://imge.kugou.com/album/{size}/abc.jpg", 480);
        assert_eq!(
            url.as_deref(),
            Some("https://imge.kugou.com/album/480/abc.jpg")
        );
    }

    #[test]
    fn test_build_kugou_cover_url_empty() {
        assert_eq!(build_kugou_cover_url("", 480), None);
    }

    #[test]
    fn test_build_kugou_cover_url_https_upgrade() {
        let url = build_kugou_cover_url("http://example.com/cover.jpg", 480);
        assert_eq!(url.as_deref(), Some("https://example.com/cover.jpg"));
    }

    #[test]
    fn test_build_kugou_cover_url_already_https() {
        let url = build_kugou_cover_url("https://example.com/cover.jpg", 480);
        assert_eq!(url.as_deref(), Some("https://example.com/cover.jpg"));
    }

    // ===== make_search_cache_key =====

    #[test]
    fn test_make_search_cache_key() {
        assert_eq!(make_search_cache_key("kw", "周杰伦", 30), "kw/周杰伦/30");
    }

    #[test]
    fn test_make_search_cache_key_different_sources() {
        let key1 = make_search_cache_key("kw", "test", 20);
        let key2 = make_search_cache_key("kg", "test", 20);
        assert_ne!(key1, key2);
    }

    #[test]
    fn test_make_search_cache_key_different_limits() {
        let key1 = make_search_cache_key("kw", "test", 20);
        let key2 = make_search_cache_key("kw", "test", 30);
        assert_ne!(key1, key2);
    }

    // ===== sha1_hex =====

    #[test]
    fn test_sha1_hex_known_value() {
        assert_eq!(
            sha1_hex("hello"),
            "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"
        );
    }

    #[test]
    fn test_sha1_hex_empty_string() {
        assert_eq!(sha1_hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    }

    #[test]
    fn test_sha1_hex_unicode() {
        let hash = sha1_hex("周杰伦");
        assert_eq!(hash.len(), 40);
    }

    // ===== pick_hash_by_idx =====

    #[test]
    fn test_pick_hash_by_idx_normal() {
        let hash = "0123456789abcdef";
        assert_eq!(pick_hash_by_idx(hash, &[0, 5, 10]), "05a");
    }

    #[test]
    fn test_pick_hash_by_idx_out_of_range() {
        let hash = "abc";
        assert_eq!(pick_hash_by_idx(hash, &[0, 10]), "a0");
    }

    #[test]
    fn test_pick_hash_by_idx_empty_indexes() {
        let hash = "0123456789abcdef";
        assert_eq!(pick_hash_by_idx(hash, &[]), "");
    }

    // ===== LxSearchItem serialization =====

    #[test]
    fn test_lx_search_item_serialization() {
        let item = LxSearchItem {
            name: "晴天".into(),
            singer: "周杰伦".into(),
            album_name: "叶惠美".into(),
            album_id: serde_json::json!(12345),
            songmid: "song123".into(),
            source: "kw".into(),
            interval: "04:29".into(),
            img: Some("https://example.com/cover.jpg".into()),
            hash: Some("abc123".into()),
            str_media_mid: None,
            song_id: None,
            album_mid: None,
            copyright_id: None,
            types: vec![LxTypeTuple {
                quality_type: "320k".into(),
                size: Some("10.5MB".into()),
                hash: None,
            }],
            lx_types: None,
        };

        let json = serde_json::to_string(&item).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(v["types"][0]["type"], "320k");
        assert_eq!(v["types"][0]["size"], "10.5MB");
        assert_eq!(v["name"], "晴天");
        assert_eq!(v["singer"], "周杰伦");
        assert_eq!(v["source"], "kw");
    }

    // ===== tx_handle_result fixture =====

    #[test]
    fn test_tx_handle_result_maps_fields_and_orders_types() {
        let raw = serde_json::json!([{
            "title": "晴天",
            "mid": "003",
            "singer": [{"name": "周杰伦"}],
            "album": {"mid": "alb01", "name": "叶惠美"},
            "interval": 240,
            "file": {
                "media_mid": "M001",
                "size_128mp3": 4.1e6,
                "size_320mp3": 8.2e6,
                "size_flac": 20.0e6,
                "size_hires": 0.0
            }
        }]);

        let list = tx_handle_result(&raw);
        assert_eq!(list.len(), 1);
        let it = &list[0];
        assert_eq!(it.name, "晴天");
        assert_eq!(it.singer, "周杰伦");
        assert_eq!(it.album_name, "叶惠美");
        assert_eq!(it.source, "tx");
        assert_eq!(it.songmid, "003");
        assert_eq!(it.str_media_mid.as_deref(), Some("M001"));
        assert_eq!(it.album_mid.as_deref(), Some("alb01"));
        assert_eq!(it.interval, "04:00");

        let types: Vec<&str> = it.types.iter().map(|t| t.quality_type.as_str()).collect();
        assert_eq!(types, vec!["128k", "320k", "flac"]);
    }

    #[test]
    fn test_tx_handle_result_skips_item_without_mid_or_id() {
        let raw = serde_json::json!([
            { "title": "无标识符", "file": { "media_mid": "M001" } },
            { "title": "有 id", "id": 123, "file": { "media_mid": "M002" } },
            { "title": "有 mid", "mid": "M003", "file": {} }
        ]);
        let list = tx_handle_result(&raw);
        assert_eq!(list.len(), 2, "仅跳过无顶层 mid/id 的项");
        assert_eq!(list[0].name, "有 id");
        assert_eq!(list[1].name, "有 mid");
    }

    // ===== mg_filter_data fixture =====

    #[test]
    fn test_mg_filter_data_flattens_and_dedupes_by_copyright() {
        let raw = serde_json::json!([[
            {
                "songId": "s1",
                "copyrightId": "c1",
                "name": "歌一",
                "album": "专辑一",
                "albumId": 42,
                "duration": 180,
                "singerList": [{"name": "歌手一"}],
                "audioFormats": [
                    {"formatType": "PQ", "asize": 3.0e6},
                    {"formatType": "SQ", "asize": 9.0e6}
                ]
            },
            {
                "songId": "s1-dup",
                "copyrightId": "c1",
                "name": "重复项(应被去重)",
                "audioFormats": [{"formatType": "PQ", "asize": 3.0e6}]
            }
        ]]);
        let list = mg_filter_data(&raw);
        assert_eq!(list.len(), 1);

        let it = &list[0];
        assert_eq!(it.name, "歌一");
        assert_eq!(it.source, "mg");
        assert_eq!(it.songmid, "s1");
        assert_eq!(it.copyright_id.as_deref(), Some("c1"));
        assert_eq!(it.singer, "歌手一");
        assert_eq!(it.interval, "03:00");
        let types: Vec<&str> = it.types.iter().map(|t| t.quality_type.as_str()).collect();
        assert_eq!(types, vec!["128k", "flac"]);
    }

    #[test]
    fn test_mg_filter_data_dedup_same_quality_using_isize_fallback() {
        let raw = serde_json::json!([[{
            "songId": "s2",
            "copyrightId": "c2",
            "name": "歌二",
            "album": "专辑B",
            "singerList": [{"name": "歌手二"}],
            "audioFormats": [
                {"formatType": "HQ", "asize": 0.0, "isize": 5.0e6},
                {"formatType": "ZQ24", "asize": 0.0, "isize": 30.0e6}
            ]
        }]]);
        let items = mg_filter_data(&raw);
        assert_eq!(items.len(), 1);
        let it = &items[0];
        let types: Vec<&str> = it.types.iter().map(|t| t.quality_type.as_str()).collect();
        assert_eq!(types, vec!["320k", "flac24bit"]);
    }

    // ===== 真实网络探测（仅本地调试用，CI 不跑）=====

    #[tokio::test]
    #[ignore]
    async fn probe_kg_wy_network_search() {
        for source in ["kg", "wy"] {
            let r = lx_search(source, "周杰伦", 10).await;
            match r {
                Ok(items) => {
                    eprintln!("[probe] {source} ok, count={}", items.len());
                    for it in items.iter().take(3) {
                        eprintln!(
                            "[probe] {source} name={} songmid='{}' hash={:?} interval='{}'",
                            it.name, it.songmid, it.hash, it.interval
                        );
                    }
                }
                Err(e) => eprintln!("[probe] {source} err: {e}"),
            }
        }
    }
}
