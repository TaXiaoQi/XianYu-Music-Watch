//! 酷狗（kg）榜单：v3 rank/list 列表 + rank/song 详情。

use super::*;

/// 构造酷狗封面 URL（替换 {size} 占位符并升级为 HTTPS）。
/// 腕端 lx_search 的同名 helper 未公开复用路径，此处内联等价实现。
fn build_kugou_cover_url(url: &str, size: u32) -> Option<String> {
    let u = url.trim();
    if u.is_empty() {
        return None;
    }
    let u = u.replacen("http://", "https://", 1);
    let u = u.replace("{size}", &size.to_string());
    Some(u)
}

pub(crate) async fn kg_boards() -> Result<Vec<LxToplistBoard>, String> {
    let url = "http://mobilecdn.kugou.com/api/v3/rank/list?version=9108&plat=0&showtype=2&parentid=0&apiver=6";
    let data = tokio::time::timeout(Duration::from_secs(6), http_get_json(url, &[]))
        .await
        .map_err(|_| "KG toplist timeout".to_string())??;

    let info = data
        .pointer("/data/info")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(info
        .iter()
        .filter_map(|b| {
            let id = b.get("rankid")?;
            let title = b
                .get("rankname")
                .and_then(|v| v.as_str())
                .map(decode_name)
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())?;
            Some(LxToplistBoard {
                id: value_to_id(id),
                title,
                // imgurl 含 {size} 占位符，必须替换为具体尺寸才能访问
                cover_img: b
                    .get("imgurl")
                    .and_then(|v| v.as_str())
                    .and_then(|u| build_kugou_cover_url(u, 480)),
                description: "酷狗榜单".into(),
                source: "kg".into(),
            })
        })
        .collect())
}

pub(crate) async fn kg_board_songs(
    board_id: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let url = format!(
        "http://mobilecdn.kugou.com/api/v3/rank/song?version=9108&rankid={}&page={}&pagesize={}",
        board_id, page, limit
    );
    let data = tokio::time::timeout(Duration::from_secs(8), http_get_json(&url, &[]))
        .await
        .map_err(|_| "KG toplist detail timeout".to_string())??;

    let info = data
        .pointer("/data/info")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(info
        .iter()
        .map(|s| {
            let hash = s
                .get("hash")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let authors = s
                .get("authors")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            let mut singer = authors
                .iter()
                .filter_map(|a| a.get("author_name").and_then(|n| n.as_str()))
                .map(|n| decode_name(n.trim()))
                .collect::<Vec<_>>()
                .join("/");
            if singer.is_empty() {
                // authors 缺失时回退 filename（形如 "歌手 - 歌名"）
                singer = decode_name(s.get("filename").and_then(|v| v.as_str()).unwrap_or(""));
            }
            // union_cover / album_sizable_cover 均含 {size} 占位符 → 480
            let img = s
                .pointer("/trans_param/union_cover")
                .and_then(|v| v.as_str())
                .or_else(|| s.get("album_sizable_cover").and_then(|v| v.as_str()))
                .and_then(|u| build_kugou_cover_url(u, 480));
            let duration = s.get("duration").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let (types, lx_types) = base_128k_types(Some(hash.clone()));
            LxSearchItem {
                name: decode_name(s.get("songname").and_then(|v| v.as_str()).unwrap_or("")),
                singer,
                album_name: decode_name(s.get("remark").and_then(|v| v.as_str()).unwrap_or("")),
                album_id: serde_json::Value::Null,
                // 榜单接口仅给 hash：kg 的 songmid 即 hash
                songmid: hash,
                source: "kg".into(),
                interval: format_play_time(duration),
                img,
                hash: None,
                str_media_mid: None,
                song_id: None,
                album_mid: None,
                copyright_id: None,
                types,
                lx_types: Some(lx_types),
            }
        })
        .collect())
}
