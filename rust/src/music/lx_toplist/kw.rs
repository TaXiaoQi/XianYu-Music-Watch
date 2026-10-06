//! 酷我（kw）榜单：kbangserver 固定榜单 ID 并发探测 + 详情分页。

use super::*;

const KW_BOARD_IDS: [u32; 6] = [93, 17, 95, 89, 66, 112];

fn kw_bang_url(id: &str, page: u32, rn: u32) -> String {
    format!(
        "http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&type=bang&data=content&id={}&p={}&rn={}",
        id, page, rn
    )
}

async fn kw_probe_board(id: u32) -> Option<LxToplistBoard> {
    let url = kw_bang_url(&id.to_string(), 1, 1);
    // 单榜探测 4s 超时：kbangserver 偶发不响应，超时榜直接丢弃
    let data = tokio::time::timeout(Duration::from_secs(4), http_get_json(&url, &[]))
        .await
        .ok()?
        .ok()?;
    let title = data
        .get("name")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())?;
    let cover = data
        .get("pic")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty());
    Some(LxToplistBoard {
        id: id.to_string(),
        title,
        cover_img: cover,
        description: "酷我榜单".into(),
        source: "kw".into(),
    })
}

pub(crate) async fn kw_boards() -> Vec<LxToplistBoard> {
    let handles: Vec<_> = KW_BOARD_IDS
        .iter()
        .map(|id| tokio::spawn(kw_probe_board(*id)))
        .collect();
    let collect = async {
        let mut out = Vec::new();
        for h in handles {
            if let Ok(Some(b)) = h.await {
                out.push(b);
            }
        }
        out
    };
    // 整批 4.5s 总上限：超时剩余榜全部丢弃（spawn 的任务各自有 4s 超时，自行结束）
    tokio::time::timeout(Duration::from_millis(4500), collect)
        .await
        .unwrap_or_default()
}

pub(crate) async fn kw_board_songs(
    board_id: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let url = kw_bang_url(board_id, page, limit);
    let data = tokio::time::timeout(Duration::from_secs(8), http_get_json(&url, &[]))
        .await
        .map_err(|_| "KW toplist detail timeout".to_string())??;

    let musiclist = data
        .get("musiclist")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(musiclist
        .iter()
        .map(|s| {
            let secs = s
                .get("song_duration")
                .and_then(kw_secs)
                .or_else(|| s.get("duration").and_then(kw_secs))
                .unwrap_or(0.0);
            let (types, lx_types) = base_128k_types(None);
            LxSearchItem {
                name: decode_name(s.get("name").and_then(|v| v.as_str()).unwrap_or("")),
                singer: decode_name(s.get("artist").and_then(|v| v.as_str()).unwrap_or("")),
                album_name: decode_name(s.get("album").and_then(|v| v.as_str()).unwrap_or("")),
                album_id: serde_json::Value::Null,
                songmid: s.get("id").map(value_to_id).unwrap_or_default(),
                source: "kw".into(),
                interval: format_play_time(secs),
                img: None,
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

/// 时长字段兼容数字与字符串两种类型
fn kw_secs(v: &serde_json::Value) -> Option<f64> {
    v.as_f64()
        .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
}
