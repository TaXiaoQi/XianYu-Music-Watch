
use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

const DEFAULT_API_SECRET: &str = "bf027fedb4d1b4f969c10495f12f17042bf0de02de128200";

const OFFICIAL_AUTH_BASE_URL: &str = "https://api.xianyumusic.cn/api";

const DEFAULT_AUTH_BASE_URL: &str = OFFICIAL_AUTH_BASE_URL;

const TOKEN_FILE: &str = "auth-token.txt";

const DEFAULT_FETCH_TIMEOUT_MS: u64 = 40_000;

const TIME_OFFSET_FILE: &str = "time_offset.txt";

static HTTP_CLIENT: OnceLock<Result<reqwest::Client, String>> = OnceLock::new();

fn http_client() -> &'static Result<reqwest::Client, String> {
    HTTP_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .redirect(crate::security::ssrf::ip_literal_redirect_policy())
            .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
            .build()
            .map_err(|e| format!("创建 HTTP 客户端失败: {e}"))
    })
}

// ─── 辅助结构 ──────────────────────────────────────────

struct SignedHeaders {
    timestamp: String,
    nonce: String,
    sign: String,
}

fn generate_nonce() -> String {
    uuid::Uuid::new_v4().as_simple().to_string()
}

fn build_signed_headers(body: &str, api_secret: &str, timestamp: i64) -> SignedHeaders {
    let nonce = generate_nonce();
    let sign_input = format!("{}{}{}{}", timestamp, nonce, body, api_secret);
    let digest = md5::compute(sign_input.as_bytes());
    let sign = format!("{:x}", digest);
    SignedHeaders {
        timestamp: timestamp.to_string(),
        nonce,
        sign,
    }
}

fn local_now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn parse_http_date(s: &str) -> Option<i64> {
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let b = s.as_bytes();
    if b.len() < 29 {
        return None;
    }
    let day: i64 = s.get(5..7)?.trim().parse().ok()?;
    let month_part = s.get(8..11)?;
    let mon = MONTHS
        .iter()
        .position(|m| month_part.eq_ignore_ascii_case(m))? as i64;
    let year: i64 = s.get(12..16)?.parse().ok()?;
    let mut t = s.get(17..25)?.split(':');
    let hour: i64 = t.next()?.parse().ok()?;
    let min: i64 = t.next()?.parse().ok()?;
    let sec: i64 = t.next()?.parse().ok()?;
    if !(1..=31).contains(&day)
        || !(0..=23).contains(&hour)
        || !(0..=59).contains(&min)
        || !(0..=60).contains(&sec)
    {
        return None;
    }
    Some(days_from_civil(year, mon + 1, day) * 86400 + hour * 3600 + min * 60 + sec)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

// ─── 凭证存储（文件） ──────────────────────────────────

fn auth_data_dir(data_dir: &Path) -> Result<PathBuf, String> {
    let dir = data_dir.join("auth");
    fs::create_dir_all(&dir).map_err(|e| format!("创建 auth 目录失败: {e}"))?;
    Ok(dir)
}

fn user_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join("user.json"))
}

fn base_url_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join("base_url.txt"))
}

fn api_secret_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join("api_secret.txt"))
}

fn token_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join(TOKEN_FILE))
}

fn read_base_url(data_dir: &Path) -> String {
    match base_url_file_path(data_dir) {
        Ok(path) => {
            if path.exists() {
                let saved = fs::read_to_string(&path)
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if saved.is_empty() {
                    return DEFAULT_AUTH_BASE_URL.to_string();
                }
                let upgraded = saved
                    .replace("http://back.xymusic.cc", "https://api.xianyumusic.cn")
                    .replace("https://back.xymusic.cc", "https://api.xianyumusic.cn");
                if upgraded != saved {
                    let _ = fs::write(&path, &upgraded);
                }
                upgraded
            } else {
                DEFAULT_AUTH_BASE_URL.to_string()
            }
        }
        Err(_) => DEFAULT_AUTH_BASE_URL.to_string(),
    }
}

fn read_api_secret(data_dir: &Path) -> String {
    match api_secret_file_path(data_dir) {
        Ok(path) => {
            if path.exists() {
                let saved = fs::read_to_string(&path)
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if saved.is_empty() {
                    DEFAULT_API_SECRET.to_string()
                } else {
                    saved
                }
            } else {
                DEFAULT_API_SECRET.to_string()
            }
        }
        Err(_) => DEFAULT_API_SECRET.to_string(),
    }
}

fn read_token(data_dir: &Path) -> Option<String> {
    token_file_path(data_dir)
        .ok()
        .filter(|path| path.exists())
        .and_then(|path| fs::read_to_string(&path).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn time_offset_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join(TIME_OFFSET_FILE))
}

fn read_time_offset(data_dir: &Path) -> i64 {
    time_offset_file_path(data_dir)
        .ok()
        .filter(|path| path.exists())
        .and_then(|path| fs::read_to_string(&path).ok())
        .and_then(|s| s.trim().parse::<i64>().ok())
        .unwrap_or(0)
}

fn save_time_offset(data_dir: &Path, offset: i64) {
    if let Ok(path) = time_offset_file_path(data_dir) {
        let _ = fs::write(&path, offset.to_string());
    }
}

fn save_token(data_dir: &Path, token: &str) -> Result<(), String> {
    let path = token_file_path(data_dir)?;
    fs::write(&path, token).map_err(|e| format!("token 写入失败: {e}"))
}

fn delete_token(data_dir: &Path) -> Result<(), String> {
    let path = token_file_path(data_dir)?;
    if path.exists() {
        fs::remove_file(&path).map_err(|e| format!("token 删除失败: {e}"))?;
    }
    Ok(())
}

// ─── 公开 API ──────────────────────────────────────────

#[derive(Serialize)]
pub struct AuthCredentials {
    pub token: String,
    pub user: Value,
}

pub async fn authed_request(
    data_dir: &Path,
    action: String,
    body: Value,
    fetch_timeout_ms: Option<u64>,
) -> Result<Value, String> {
    let base_url = read_base_url(data_dir);
    let url = format!("{}/?action={}", base_url, action);
    let api_secret = read_api_secret(data_dir);

    do_signed_post(data_dir, &url, &action, body, fetch_timeout_ms, &api_secret).await
}

pub async fn signed_post_json(
    data_dir: &Path,
    url: String,
    body: Value,
    fetch_timeout_ms: Option<u64>,
) -> Result<Value, String> {
    let api_secret = read_api_secret(data_dir);
    do_signed_post(data_dir, &url, "signedPostJson", body, fetch_timeout_ms, &api_secret).await
}

async fn do_signed_post(
    data_dir: &Path,
    url: &str,
    action: &str,
    body: Value,
    fetch_timeout_ms: Option<u64>,
    api_secret: &str,
) -> Result<Value, String> {
    let body_str = serde_json::to_string(&body).unwrap_or_default();
    let timeout_ms = fetch_timeout_ms.unwrap_or(DEFAULT_FETCH_TIMEOUT_MS);
    let client = http_client().as_ref().map_err(|e| e.clone())?;
    let mut offset = read_time_offset(data_dir);

    for attempt in 0..2 {
        let headers = build_signed_headers(&body_str, api_secret, local_now_secs() + offset);
        let start = std::time::Instant::now();

        let response = match client
            .post(url)
            .timeout(Duration::from_millis(timeout_ms))
            .header("Content-Type", "application/json")
            .header("X-Timestamp", &headers.timestamp)
            .header("X-Nonce", &headers.nonce)
            .header("X-Sign", &headers.sign)
            .body(body_str.clone())
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                if attempt == 0 {
                    continue;
                }
                let elapsed = start.elapsed().as_millis();
                let msg = e.to_string();
                let is_timeout = msg.contains("timeout") || msg.contains("elapsed");
                return Err(if is_timeout {
                    format!("请求超时（{}s），action={}", timeout_ms / 1000, action)
                } else {
                    format!("网络请求失败（action={}, {}ms）: {}", action, elapsed, msg)
                });
            }
        };

        let status = response.status();
        let date_header = response
            .headers()
            .get(reqwest::header::DATE)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());
        let text = response
            .text()
            .await
            .map_err(|e| format!("响应体读取失败（action={}）: {}", action, e))?;

        if let Some(server_secs) = date_header.as_deref().and_then(parse_http_date) {
            let new_offset = server_secs - local_now_secs();
            if (new_offset - offset).abs() >= 3 {
                offset = new_offset;
                save_time_offset(data_dir, offset);
            }
        }

        if attempt == 0 && status.as_u16() == 403 && text.contains("签名验证失败") {
            continue;
        }

        if text.contains("宝塔WAF") || text.contains("缓冲区溢出") {
            return Err(format!(
                "服务器WAF拦截（action={}, HTTP {}）: 请求体过大，触发Nginx缓冲区溢出",
                action, status
            ));
        }

        let payload: Value = serde_json::from_str(&text).map_err(|e| {
            if !status.is_success() {
                format!(
                    "HTTP {}（action={}）: 服务器返回非 JSON 响应",
                    status, action
                )
            } else {
                format!("响应解析失败（action={}, HTTP {}）: {}", action, status, e)
            }
        })?;
        return Ok(payload);
    }
    unreachable!("重试循环两次尝试内必然返回")
}

pub fn save_auth_credentials(data_dir: &Path, token: String, user: Value) -> Result<(), String> {
    save_token(data_dir, &token)?;

    let user_path = user_file_path(data_dir)?;
    let user_json =
        serde_json::to_string_pretty(&user).map_err(|e| format!("user 序列化失败: {e}"))?;
    fs::write(&user_path, user_json).map_err(|e| format!("user 文件写入失败: {e}"))?;

    Ok(())
}

pub fn get_auth_credentials(data_dir: &Path) -> Result<Option<AuthCredentials>, String> {
    let Some(token) = read_token(data_dir) else {
        return Ok(None);
    };

    let user_path = user_file_path(data_dir)?;
    let user: Value = if user_path.exists() {
        let content =
            fs::read_to_string(&user_path).map_err(|e| format!("user 文件读取失败: {e}"))?;
        serde_json::from_str(&content).map_err(|e| format!("user JSON 解析失败: {e}"))?
    } else {
        Value::Null
    };

    Ok(Some(AuthCredentials { token, user }))
}

pub fn clear_auth_credentials(data_dir: &Path) -> Result<(), String> {
    delete_token(data_dir)?;

    let user_path = user_file_path(data_dir)?;
    if user_path.exists() {
        let _ = fs::remove_file(&user_path);
    }

    Ok(())
}

pub fn set_auth_base_url(data_dir: &Path, base_url: String) -> Result<(), String> {
    let trimmed = base_url.trim();
    let url = if trimmed.is_empty() {
        DEFAULT_AUTH_BASE_URL.to_string()
    } else {
        trimmed.to_string()
    };

    let path = base_url_file_path(data_dir)?;
    fs::write(&path, &url).map_err(|e| format!("base_url 文件写入失败: {e}"))?;
    Ok(())
}

pub fn get_auth_base_url(data_dir: &Path) -> Result<String, String> {
    Ok(read_base_url(data_dir))
}

pub fn set_auth_api_secret(data_dir: &Path, api_secret: String) -> Result<(), String> {
    let trimmed = api_secret.trim();
    let secret = if trimmed.is_empty() {
        DEFAULT_API_SECRET.to_string()
    } else {
        trimmed.to_string()
    };

    let path = api_secret_file_path(data_dir)?;
    fs::write(&path, &secret).map_err(|e| format!("api_secret 文件写入失败: {e}"))?;
    Ok(())
}

pub fn get_auth_api_secret(data_dir: &Path) -> Result<String, String> {
    Ok(read_api_secret(data_dir))
}

#[cfg(test)]
mod time_calibrate_tests {
    use super::*;

    #[test]
    fn parse_http_date_standard() {
        let secs = parse_http_date("Thu, 10 Sep 2026 06:34:48 GMT").expect("应解析成功");
        let local = local_now_secs();
        assert!(
            (secs - local).abs() < 86_400,
            "解析结果 {} 与本地时间 {} 偏差超过一天",
            secs,
            local
        );
        assert_eq!(secs, 1789022088);
    }

    #[test]
    fn parse_http_date_invalid() {
        assert!(parse_http_date("").is_none());
        assert!(parse_http_date("short").is_none());
        assert!(parse_http_date("Thu, Foo Sep 2026 06:34:48 GMT").is_none());
        assert!(parse_http_date("Thu, 10 Sep 2026 06:34:48").is_none());
        assert!(parse_http_date("Thu, 32 Sep 2026 06:34:48 GMT").is_none());
    }

    #[test]
    fn days_from_civil_epoch() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(2000, 3, 1), 11017);
        assert_eq!(days_from_civil(2026, 9, 10), 20706);
    }

    #[test]
    fn offset_sign_semantics() {
        let local = local_now_secs();
        let server = local + 600;
        let offset = server - local;
        assert_eq!(local + offset, server);
    }
}