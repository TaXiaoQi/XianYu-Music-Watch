use super::*;

const TX_PART_1_INDEXES: [usize; 8] = [23, 14, 6, 36, 16, 40, 7, 19];
const TX_PART_2_INDEXES: [usize; 8] = [16, 1, 32, 12, 19, 27, 8, 5];
const TX_SCRAMBLE_VALUES: [u8; 20] = [
    89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
];

pub(crate) fn sha1_hex(text: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(text.as_bytes());
    let result = hasher.finalize();
    hex::encode(result)
}

pub(crate) fn pick_hash_by_idx(hash: &str, indexes: &[usize]) -> String {
    indexes
        .iter()
        .map(|&idx| hash.chars().nth(idx).unwrap_or('0'))
        .collect()
}

pub(crate) fn zzc_sign(text: &str) -> String {
    let hash = sha1_hex(text);
    let part1 = pick_hash_by_idx(&hash, &TX_PART_1_INDEXES);
    let part2 = pick_hash_by_idx(&hash, &TX_PART_2_INDEXES);

    let mut part3_bytes = Vec::with_capacity(20);
    for (i, &scramble) in TX_SCRAMBLE_VALUES.iter().enumerate() {
        let hex_pair = &hash[i * 2..i * 2 + 2];
        let hash_byte = u8::from_str_radix(hex_pair, 16).unwrap_or(0);
        part3_bytes.push(scramble ^ hash_byte);
    }

    let b64 = base64::engine::general_purpose::STANDARD.encode(&part3_bytes);
    let b64_clean: String = b64
        .chars()
        .filter(|c| !matches!(c, '/' | '\\' | '+' | '='))
        .collect();

    format!("zzc{}{}{}", part1, b64_clean, part2).to_lowercase()
}

fn tx_string_field(item: &serde_json::Value, keys: &[&str]) -> String {
    for key in keys {
        if let Some(value) = item.get(*key) {
            if let Some(text) = value.as_str() {
                if !text.is_empty() {
                    return text.to_string();
                }
            } else if let Some(number) = value.as_i64() {
                return number.to_string();
            } else if let Some(number) = value.as_u64() {
                return number.to_string();
            }
        }
    }
    String::new()
}

fn tx_pick_search_raw_list(data: &serde_json::Value) -> Option<&serde_json::Value> {
    const PATHS: &[&str] = &[
        "/body/song/list",
        "/body/song/songlist",
        "/body/song/itemlist",
        "/body/song/items",
        "/body/song/item_song",
        "/body/songlist/list",
        "/body/songlist/songlist",
        "/body/songlist/itemlist",
        "/body/songlist/items",
        "/body/songlist",
        "/body/item_song",
        "/song/list",
        "/songlist",
        "/item_song",
    ];

    for path in PATHS {
        if let Some(value) = data.pointer(path) {
            if value.as_array().map_or(false, |arr| !arr.is_empty()) {
                return Some(value);
            }
        }
    }

    None
}

pub(crate) fn tx_handle_result(raw_list: &serde_json::Value) -> Vec<LxSearchItem> {
    let mut list = Vec::new();
    let arr = match raw_list.as_array() {
        Some(a) => a,
        None => return list,
    };

    for raw_item in arr {
        let item = raw_item
            .get("song")
            .or_else(|| raw_item.get("songInfo"))
            .or_else(|| raw_item.get("musicInfo"))
            .unwrap_or(raw_item);
        let songmid = tx_string_field(item, &["mid", "songmid", "songMid", "strMediaMid", "id"]);
        let has_mid = !songmid.is_empty();
        let has_id = item.get("id").is_some();
        if !has_mid && !has_id {
            continue;
        }
        let file = item.get("file").unwrap_or(&serde_json::Value::Null);
        let media_mid = file
            .get("media_mid")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| tx_string_field(item, &["strMediaMid", "mediaMid", "mediamid"]));

        let mut types = Vec::new();
        let mut lx_types = HashMap::new();

        let size_128 = file
            .get("size_128mp3")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let size_320 = file
            .get("size_320mp3")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let size_flac = file
            .get("size_flac")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let size_hires = file
            .get("size_hires")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);

        if size_128 > 0.0 {
            let s = size_formate(size_128);
            types.push(LxTypeTuple {
                quality_type: "128k".into(),
                size: Some(s.clone()),
                hash: None,
            });
            lx_types.insert(
                "128k".into(),
                LxTypeEntry {
                    size: Some(s),
                    hash: None,
                },
            );
        }
        if size_320 > 0.0 {
            let s = size_formate(size_320);
            types.push(LxTypeTuple {
                quality_type: "320k".into(),
                size: Some(s.clone()),
                hash: None,
            });
            lx_types.insert(
                "320k".into(),
                LxTypeEntry {
                    size: Some(s),
                    hash: None,
                },
            );
        }
        if size_flac > 0.0 {
            let s = size_formate(size_flac);
            types.push(LxTypeTuple {
                quality_type: "flac".into(),
                size: Some(s.clone()),
                hash: None,
            });
            lx_types.insert(
                "flac".into(),
                LxTypeEntry {
                    size: Some(s),
                    hash: None,
                },
            );
        }
        let size_master = file
            .get("size_master")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let size_atmos = file
            .get("size_atmos")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let size_dolby = file
            .get("size_dolby")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);

        if size_hires > 0.0 {
            let s = size_formate(size_hires);
            types.push(LxTypeTuple {
                quality_type: "flac24bit".into(),
                size: Some(s.clone()),
                hash: None,
            });
            lx_types.insert(
                "flac24bit".into(),
                LxTypeEntry {
                    size: Some(s),
                    hash: None,
                },
            );
        }
        if size_master > 0.0 {
            let s = size_formate(size_master);
            types.push(LxTypeTuple {
                quality_type: "master".into(),
                size: Some(s.clone()),
                hash: None,
            });
            lx_types.insert(
                "master".into(),
                LxTypeEntry {
                    size: Some(s),
                    hash: None,
                },
            );
        }
        if size_atmos > 0.0 {
            let s = size_formate(size_atmos);
            types.push(LxTypeTuple {
                quality_type: "atmos".into(),
                size: Some(s.clone()),
                hash: None,
            });
            lx_types.insert(
                "atmos".into(),
                LxTypeEntry {
                    size: Some(s),
                    hash: None,
                },
            );
        }
        if size_dolby > 0.0 {
            let s = size_formate(size_dolby);
            types.push(LxTypeTuple {
                quality_type: "dolby".into(),
                size: Some(s.clone()),
                hash: None,
            });
            lx_types.insert(
                "dolby".into(),
                LxTypeEntry {
                    size: Some(s),
                    hash: None,
                },
            );
        }

        let album = item.get("album").unwrap_or(&serde_json::Value::Null);
        let album_id = album
            .get("mid")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| tx_string_field(item, &["albumMid", "albummid", "albumid"]));
        let album_name = album
            .get("name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| tx_string_field(item, &["albumName", "albumname"]));

        let interval = item.get("interval").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let song_id = item.get("id").or_else(|| item.get("songid")).cloned();
        let album_mid = if album_id.is_empty() {
            None
        } else {
            Some(album_id.clone())
        };

        let img = if album_id.is_empty() || album_id == "空" {
            item.pointer("/singer/0/mid")
                .and_then(|v| v.as_str())
                .map(|mid| {
                    format!(
                        "https://y.gtimg.cn/music/photo_new/T001R500x500M000{}.jpg",
                        mid
                    )
                })
        } else {
            Some(format!(
                "https://y.gtimg.cn/music/photo_new/T002R500x500M000{}.jpg",
                album_id
            ))
        };

        list.push(LxSearchItem {
            singer: format_singer_name(
                item.get("singer")
                    .or_else(|| item.get("singerName"))
                    .or_else(|| item.get("singername"))
                    .unwrap_or(&serde_json::Value::Null),
                "name",
            ),
            name: item
                .get("title")
                .or_else(|| item.get("name"))
                .or_else(|| item.get("songname"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            album_name,
            album_id: serde_json::Value::String(album_id),
            source: "tx".into(),
            interval: format_play_time(interval),
            songmid,
            img,
            hash: None,
            str_media_mid: Some(media_mid),
            song_id,
            album_mid,
            copyright_id: None,
            types,
            lx_types: Some(lx_types),
        });
    }
    list
}

pub(crate) async fn search_tx(keyword: &str, limit: u32) -> Result<Vec<LxSearchItem>, String> {
    if let Ok(items) = search_tx_soso(keyword, limit).await {
        if !items.is_empty() {
            return Ok(items);
        }
    }

    let request_data = serde_json::json!({
        "comm": {
            "ct": "24", "cv": "4747474", "v": "4747474", "tmeAppID": "qqmusic",
            "format": "json", "inCharset": "utf-8", "outCharset": "utf-8",
            "platform": "yqq.json", "needNewCode": 0,
            "uin": "0", "guid": "0",
        },
        "req": {
            "module": "music.search.SearchCgiService",
            "method": "DoSearchForQQMusicDesktop",
            "param": {
                "search_type": 0,
                "searchid": format!("{}", chrono_like_random()),
                "query": keyword,
                "page_num": 1,
                "num_per_page": limit,
                "highlight": 0, "nqc_flag": 0, "multi_zhida": 0, "cat": 2, "grp": 1, "sin": 0, "sem": 0,
            },
        },
    });

    let request_str = serde_json::to_string(&request_data).map_err(|e| e.to_string())?;
    let sign = zzc_sign(&request_str);
    let url = format!("https://u.y.qq.com/cgi-bin/musics.fcg?sign={}", sign);

    let body = http_post_json(
        &url,
        &request_str,
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
            ("Content-Type", "application/json"),
            ("Referer", "https://y.qq.com/"),
        ],
    )
    .await?;

    if body.get("code").and_then(|v| v.as_i64()) != Some(0)
        || body.pointer("/req/code").and_then(|v| v.as_i64()) != Some(0)
    {
        return Err("TX search: invalid response code".to_string());
    }

    let data = body
        .pointer("/req/data")
        .unwrap_or(&serde_json::Value::Null);
    let mut result = tx_pick_search_raw_list(data)
        .map(tx_handle_result)
        .unwrap_or_default();
    if !result.is_empty() {
        return Ok(result);
    }

    let mobile_request_data = serde_json::json!({
        "comm": {
            "ct": "24", "cv": "4747474", "v": "4747474", "tmeAppID": "qqmusic",
            "format": "json", "inCharset": "utf-8", "outCharset": "utf-8",
            "platform": "yqq.json", "needNewCode": 0,
            "uin": "0", "guid": "0",
        },
        "req": {
            "module": "music.search.SearchCgiService",
            "method": "DoSearchForQQMusicMobile",
            "param": {
                "search_type": 0,
                "searchid": format!("{}", chrono_like_random()),
                "query": keyword,
                "page_num": 1,
                "num_per_page": limit,
                "highlight": 0, "nqc_flag": 0, "multi_zhida": 0, "cat": 2, "grp": 1, "sin": 0, "sem": 0,
            },
        },
    });
    let mobile_request_str =
        serde_json::to_string(&mobile_request_data).map_err(|e| e.to_string())?;
    let mobile_sign = zzc_sign(&mobile_request_str);
    let mobile_url = format!("https://u.y.qq.com/cgi-bin/musics.fcg?sign={}", mobile_sign);
    let mobile_body = http_post_json(
        &mobile_url,
        &mobile_request_str,
        &[
            ("User-Agent", "Mozilla/5.0 (Linux; Android 12; EBG-AN10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.5304.141 Mobile Safari/537.36"),
            ("Content-Type", "application/json"),
            ("Referer", "https://y.qq.com/"),
        ],
    )
    .await?;

    if mobile_body.get("code").and_then(|v| v.as_i64()) == Some(0)
        && mobile_body.pointer("/req/code").and_then(|v| v.as_i64()) == Some(0)
    {
        let mobile_data = mobile_body
            .pointer("/req/data")
            .unwrap_or(&serde_json::Value::Null);
        result = tx_pick_search_raw_list(mobile_data)
            .map(tx_handle_result)
            .unwrap_or_default();
    }

    Ok(result)
}

async fn search_tx_soso(keyword: &str, limit: u32) -> Result<Vec<LxSearchItem>, String> {
    const MOBILE_UA: &str = "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1";

    let url = format!(
        "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?ct=24&qqmusic_ver=1298\
         &remoteplace=txt.yqq.song&t=0&aggr=1&cr=1&catZhida=1&lossless=0\
         &flag_qc=0&p=1&n={}&w={}&format=json&inCharset=utf8&outCharset=utf-8\
         &notice=0&platform=yqq.json&needNewCode=0",
        limit,
        urlencoding::encode(keyword)
    );

    let body = http_get_json(
        &url,
        &[("User-Agent", MOBILE_UA), ("Referer", "https://y.qq.com/")],
    )
    .await?;

    if body.get("code").and_then(|v| v.as_i64()) != Some(0) {
        return Err("TX soso: code != 0".to_string());
    }

    let data = body.pointer("/data").unwrap_or(&serde_json::Value::Null);
    Ok(tx_pick_search_raw_list(data)
        .map(tx_handle_result)
        .unwrap_or_default())
}

fn chrono_like_random() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let mut val = now.as_millis() as u64;
    val = val.wrapping_mul(1000) + (val % 900);
    val
}

pub async fn tx_search_albums(
    keyword: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<serde_json::Value>, String> {
    let request_data = serde_json::json!({
        "comm": {
            "_channelid": "0",
            "_os_version": "6.2.9200-2",
            "ct": "19",
            "cv": "2151",
            "guid": random_tx_guid(),
            "patch": "118",
            "psrf_access_token_expiresAt": 0,
            "psrf_qqaccess_token": "",
            "psrf_qqopenid": "",
            "psrf_qqunionid": "",
            "tmeAppID": "qqmusic",
            "tmeLoginType": 0,
            "uin": "0",
            "wid": random_tx_wid(),
        },
        "req": {
            "module": "music.search.SearchCgiService",
            "method": "DoSearchForQQMusicDesktop",
            "param": {
                "grp": 1,
                "num_per_page": limit,
                "page_num": page,
                "query": keyword,
                "remoteplace": "txt.newclient.top",
                "search_type": 2,
                "searchid": format!("{}{:05}", random_tx_guid(), random_5_digits()),
            },
        },
    });
    let request_str = serde_json::to_string(&request_data).map_err(|e| e.to_string())?;
    let sign = zzc_sign(&request_str);
    let url = format!("https://u.y.qq.com/cgi-bin/musics.fcg?sign={}", sign);
    let body = http_post_json(
        &url,
        &request_str,
        &[
            ("User-Agent", "QQMusic 14090508(android 12)"),
            ("Content-Type", "application/json"),
            ("Referer", "https://y.qq.com/"),
        ],
    )
    .await?;
    if body.get("code").and_then(|v| v.as_i64()) != Some(0)
        || body.pointer("/req/code").and_then(|v| v.as_i64()) != Some(0)
    {
        return Err("TX album search: invalid response code".to_string());
    }
    let data = body
        .pointer("/req/data")
        .unwrap_or(&serde_json::Value::Null);
    Ok(tx_pick_album_raw_list(data))
}

fn tx_pick_album_raw_list(data: &serde_json::Value) -> Vec<serde_json::Value> {
    for path in ["/body/album/list", "/body/item_album/list"] {
        if let Some(arr) = data.pointer(path).and_then(|v| v.as_array()) {
            if !arr.is_empty() {
                return arr.clone();
            }
        }
    }
    if let Some(arr) = data.as_array() {
        return arr.clone();
    }
    Vec::new()
}

pub async fn tx_album_songs(
    album_mid: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let request_data = serde_json::json!({
        "comm": { "ct": "24", "cv": "0" },
        "req": {
            "module": "music.musichallAlbum.AlbumSongList",
            "method": "GetAlbumSongList",
            "param": {
                "albumMid": album_mid,
                "albumID": 0,
                "begin": (page - 1) * limit,
                "num": limit,
                "order": 2,
            },
        },
    });
    let request_str = serde_json::to_string(&request_data).map_err(|e| e.to_string())?;
    let sign = zzc_sign(&request_str);
    let url = format!("https://u.y.qq.com/cgi-bin/musics.fcg?sign={}", sign);
    let body = http_post_json(
        &url,
        &request_str,
        &[
            ("User-Agent", "Mozilla/5.0 (Linux; Android 12; EBG-AN10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.5304.141 Mobile Safari/537.36"),
            ("Content-Type", "application/json"),
            ("Referer", "https://y.qq.com/"),
        ],
    )
    .await?;
    if body.get("code").and_then(|v| v.as_i64()) != Some(0)
        || body.pointer("/req/code").and_then(|v| v.as_i64()) != Some(0)
    {
        return Err("TX album songs: invalid response code".to_string());
    }
    let song_list = body
        .pointer("/req/data/songList")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let normalized: Vec<serde_json::Value> = song_list
        .into_iter()
        .map(|s| s.get("songInfo").cloned().unwrap_or(s))
        .collect();
    Ok(tx_handle_result(&serde_json::Value::Array(normalized)))
}

pub async fn tx_batch_track_interval(song_ids: &[String]) -> Result<HashMap<String, u64>, String> {
    let mut duration_map = HashMap::new();
    const CHUNK_SIZE: usize = 50;
    for chunk in song_ids.chunks(CHUNK_SIZE) {
        let ids: Vec<u64> = chunk
            .iter()
            .filter_map(|id| id.parse::<u64>().ok())
            .collect();
        if ids.is_empty() {
            continue;
        }
        let types: Vec<u32> = ids.iter().map(|_| 1).collect();
        let request_data = serde_json::json!({
            "comm": { "ct": "19", "cv": "1859", "uin": "0" },
            "req": {
                "module": "music.trackInfo.UniformRuleCtrl",
                "method": "CgiGetTrackInfo",
                "param": { "types": types, "ids": ids, "ctx": 0 },
            },
        });
        let request_str = match serde_json::to_string(&request_data) {
            Ok(s) => s,
            Err(e) => return Err(e.to_string()),
        };
        if let Ok(resp) = http_post_json(
            "https://u.y.qq.com/cgi-bin/musicu.fcg",
            &request_str,
            &[
                ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36"),
                ("Content-Type", "application/json"),
                ("Referer", "https://y.qq.com/"),
                ("Cookie", "uin="),
            ],
        )
        .await
        {
            if let Some(tracks) = resp
                .pointer("/req/data/tracks")
                .and_then(|v| v.as_array())
            {
                for track in tracks {
                    let interval = track
                        .get("interval")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);
                    let id = track
                        .get("id")
                        .and_then(|v| v.as_i64())
                        .map(|v| v.to_string());
                    if let Some(id) = id {
                        if interval > 0 {
                            duration_map.insert(id, interval as u64);
                        }
                    }
                }
            }
        }
    }
    Ok(duration_map)
}

pub(crate) fn random_tx_guid() -> String {
    let mut state = chrono_like_random();
    let mut s = String::with_capacity(32);
    for _ in 0..32 {
        s.push(
            char::from_digit((state % 16) as u32, 16)
                .unwrap()
                .to_ascii_uppercase(),
        );
        state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
    }
    s
}

fn random_tx_wid() -> String {
    let mut state = chrono_like_random().wrapping_mul(76263).wrapping_add(17);
    let mut s = String::with_capacity(19);
    s.push(char::from_digit(1 + (state % 9) as u32, 10).unwrap());
    while s.len() < 19 {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        s.push(char::from_digit((state % 10) as u32, 10).unwrap());
    }
    s
}

pub(crate) fn random_5_digits() -> u64 {
    chrono_like_random().wrapping_mul(7919).wrapping_add(104729) % 100000
}
