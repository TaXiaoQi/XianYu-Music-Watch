// lx_toplist - LX 音源榜单（兜底模块 lx_toplist 的 Rust builtin 后端）
//
// 聚合 wy/kg/kw/tx 四平台榜单：列表页各平台并发拉取（失败平台跳过、按入参
// 顺序合并进单组），详情页返回与 lx_search::LxSearchItem 完全同构的条目。
// Dart 侧经 lxToplistBoards/lxToplistBoardSongs 桥接；服务端下发的同名 JS
// 模块优先于本实现执行（见 fallback_host 与 plugin_host_fallback）。

mod kg;
mod kw;
mod tx;
mod wy;

use std::collections::HashMap;
use std::time::Duration;

use serde::Serialize;

use crate::music::lx_search::{
    decode_name, format_play_time, http_get_json, LxSearchItem, LxTypeTuple,
};
use crate::music::url_resolver::LxTypeEntry;

/// 榜单条目（camelCase 输出：id/title/coverImg/description/source）
#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LxToplistBoard {
    pub id: String,
    pub title: String,
    pub cover_img: Option<String>,
    pub description: String,
    pub source: String,
}

/// 拉取各平台榜单列表：四平台并发，失败平台跳过，结果按入参 sources 顺序合并。
pub async fn lx_toplist_boards(sources: &[String]) -> Vec<LxToplistBoard> {
    let mut seen = std::collections::HashSet::new();
    let keys: Vec<&str> = sources
        .iter()
        .map(|s| s.as_str())
        .filter(|s| seen.insert(*s))
        .collect();

    // 未入选平台跑空 future，避免动态 Future 组合的类型体操
    let wy_fut = async {
        if keys.contains(&"wy") {
            wy::wy_boards().await.unwrap_or_default()
        } else {
            Vec::new()
        }
    };
    let kg_fut = async {
        if keys.contains(&"kg") {
            kg::kg_boards().await.unwrap_or_default()
        } else {
            Vec::new()
        }
    };
    let kw_fut = async {
        if keys.contains(&"kw") {
            kw::kw_boards().await
        } else {
            Vec::new()
        }
    };
    let tx_fut = async {
        if keys.contains(&"tx") {
            tx::tx_boards().await
        } else {
            Vec::new()
        }
    };
    let (wy, kg, kw, tx) = tokio::join!(wy_fut, kg_fut, kw_fut, tx_fut);

    let mut out = Vec::new();
    for key in keys {
        match key {
            "wy" => out.extend(wy.iter().cloned()),
            "kg" => out.extend(kg.iter().cloned()),
            "kw" => out.extend(kw.iter().cloned()),
            "tx" => out.extend(tx.iter().cloned()),
            _ => {}
        }
    }
    out
}

/// 拉取单个榜单的歌曲页（limit 0 视为默认 30，其余 clamp 至 1..=100）。
pub async fn lx_toplist_board_songs(
    source: &str,
    board_id: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let limit = if limit == 0 { 30 } else { limit.clamp(1, 100) };
    match source {
        "wy" => wy::wy_board_songs(board_id, page, limit).await,
        "kg" => kg::kg_board_songs(board_id, page, limit).await,
        "kw" => kw::kw_board_songs(board_id, page, limit).await,
        "tx" => tx::tx_board_songs(board_id, page, limit).await,
        _ => Err(format!("Unknown LX toplist source: {}", source)),
    }
}

/// 详情条目保底音质：types 至少 [128k]；可选携带 hash（kg 直链解析依赖）。
pub(crate) fn base_128k_types(hash: Option<String>) -> (Vec<LxTypeTuple>, HashMap<String, LxTypeEntry>) {
    let types = vec![LxTypeTuple {
        quality_type: "128k".into(),
        size: None,
        hash: hash.clone(),
    }];
    let mut lx_types = HashMap::new();
    lx_types.insert(
        "128k".into(),
        LxTypeEntry {
            size: None,
            hash,
        },
    );
    (types, lx_types)
}

/// Value → 平台原始 ID 字符串（数字不带引号；String 的 to_string 会带引号，需区分）
pub(crate) fn value_to_id(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_value_to_id_number_and_string() {
        assert_eq!(value_to_id(&serde_json::json!(19723756)), "19723756");
        assert_eq!(value_to_id(&serde_json::json!("19723756")), "19723756");
    }

    #[test]
    fn test_base_128k_types_with_and_without_hash() {
        let (types, lx) = base_128k_types(Some("abc".into()));
        assert_eq!(types.len(), 1);
        assert_eq!(types[0].quality_type, "128k");
        assert_eq!(types[0].hash.as_deref(), Some("abc"));
        assert_eq!(lx["128k"].hash.as_deref(), Some("abc"));

        let (types, lx) = base_128k_types(None);
        assert_eq!(types.len(), 1);
        assert_eq!(types[0].hash, None);
        assert_eq!(lx["128k"].hash, None);
    }

    #[test]
    fn test_board_serialization_camel_case() {
        let board = LxToplistBoard {
            id: "19723756".into(),
            title: "飙升榜".into(),
            cover_img: Some("https://example.com/a.jpg".into()),
            description: "日榜".into(),
            source: "wy".into(),
        };
        let json = serde_json::to_string(&board).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["id"], "19723756");
        assert_eq!(v["title"], "飙升榜");
        assert_eq!(v["coverImg"], "https://example.com/a.jpg");
        assert_eq!(v["description"], "日榜");
        assert_eq!(v["source"], "wy");
    }
}
