//! QQ 音乐（tx）榜单：fcg_v8_toplist_cp 固定 ID 并发探测 + 详情分页。

use super::*;

const TX_BOARD_IDS: [u32; 12] = [26, 4, 27, 62, 60, 63, 58, 65, 66, 6, 3, 17];

const TX_HEADERS: &[(&str, &str)] = &[("Referer", "https://y.qq.com/")];

fn tx_toplist_url(topid: &str, song_begin: u32, song_num: u32) -> String {
    format!(
        "https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg?topid={}&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq&needNewCode=0&song_begin={}&song_num={}",
        topid, song_begin, song_num
    )
}

async fn tx_probe_board(id: u32) -> Option<LxToplistBoard> {
    let url = tx_toplist_url(&id.to_string(), 0, 1);
    // 必须带 Referer: https://y.qq.com/，否则接口不返回数据
    let data = tokio::time::timeout(Duration::from_secs(6), http_get_json(&url, TX_HEADERS))
        .await
        .ok()?
        .ok()?;
    let topinfo = data.get("topinfo")?;
    let title = topinfo
        .get("ListName")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())?;
    let cover = topinfo
        .get("headPic_v12")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .or_else(|| topinfo.get("MacListPicUrl").and_then(|v| v.as_str()))
        .map(|s| s.to_string());
    Some(LxToplistBoard {
        id: id.to_string(),
        title,
        cover_img: cover,
        description: "QQ音乐榜单".into(),
        source: "tx".into(),
    })
}

pub(crate) async fn tx_boards() -> Vec<LxToplistBoard> {
    let handles: Vec<_> = TX_BOARD_IDS
        .iter()
        .map(|id| tokio::spawn(tx_probe_board(*id)))
        .collect();
    let mut out = Vec::new();
    for h in handles {
        if let Ok(Some(b)) = h.await {
            out.push(b);
        }
    }
    out
}

pub(crate) async fn tx_board_songs(
    board_id: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let url = tx_toplist_url(board_id, (page - 1) * limit, limit);
    let data = tokio::time::timeout(Duration::from_secs(8), http_get_json(&url, TX_HEADERS))
        .await
        .map_err(|_| "TX toplist detail timeout".to_string())??;

    let songlist = data
        .get("songlist")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(songlist
        .iter()
        .filter_map(|entry| {
            let s = entry.get("data")?;
            let songmid = s.get("songmid").map(value_to_id)?;
            if songmid.is_empty() {
                return None;
            }
            let singer = s
                .get("singer")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
                .iter()
                .filter_map(|x| x.get("name").and_then(|n| n.as_str()))
                .collect::<Vec<_>>()
                .join("/");
            let albummid = s
                .get("albummid")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let interval = s.get("interval").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let img = if albummid.is_empty() {
                None
            } else {
                Some(format!(
                    "https://y.gtimg.cn/music/photo_new/T002R300x300M000{}.jpg",
                    albummid
                ))
            };
            let (types, lx_types) = base_128k_types(None);
            Some(LxSearchItem {
                name: decode_name(s.get("songname").and_then(|v| v.as_str()).unwrap_or("")),
                singer: decode_name(&singer),
                album_name: decode_name(s.get("albumname").and_then(|v| v.as_str()).unwrap_or("")),
                album_id: serde_json::Value::Null,
                songmid,
                source: "tx".into(),
                interval: format_play_time(interval),
                img,
                hash: None,
                str_media_mid: None,
                song_id: None,
                album_mid: if albummid.is_empty() {
                    None
                } else {
                    Some(albummid)
                },
                copyright_id: None,
                types,
                lx_types: Some(lx_types),
            })
        })
        .collect())
}
