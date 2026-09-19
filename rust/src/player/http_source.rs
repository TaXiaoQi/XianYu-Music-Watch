
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use bytes::{Buf, Bytes};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const READ_TIMEOUT: Duration = Duration::from_secs(30);

static HTTP_RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn http_runtime() -> &'static tokio::runtime::Runtime {
    HTTP_RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .expect("HTTP 源 tokio runtime 构建失败")
    })
}

fn io_err(e: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::Other, e.to_string())
}

struct Inner {
    pos: u64,
    resp: Option<reqwest::Response>,
    resp_start: u64,
    resp_pos: u64,
    pending: Bytes,
}

pub struct HttpSeekableReader {
    url: String,
    client: reqwest::Client,
    inner: Mutex<Inner>,
    total: Option<u64>,
}

struct RangeResponse {
    resp: reqwest::Response,
    total: Option<u64>,
    start: u64,
}

impl HttpSeekableReader {
    pub fn open(url: &str) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(CONNECT_TIMEOUT)
            .read_timeout(READ_TIMEOUT)
            .redirect(crate::security::ssrf::ip_literal_redirect_policy())
            .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
            .build()
            .map_err(|e| format!("HTTP client 构建失败: {e}"))?;

        let rr = http_runtime().block_on(Self::request_range(&client, url, 0))?;
        Ok(Self {
            url: url.to_string(),
            client,
            inner: Mutex::new(Inner {
                pos: rr.start,
                resp: Some(rr.resp),
                resp_start: rr.start,
                resp_pos: rr.start,
                pending: Bytes::new(),
            }),
            total: rr.total,
        })
    }

    async fn request_range(
        client: &reqwest::Client,
        url: &str,
        start: u64,
    ) -> Result<RangeResponse, String> {
        let resp = client
            .get(url)
            .header("Range", format!("bytes={start}-"))
            .send()
            .await
            .map_err(|e| format!("HTTP 请求失败: {e}"))?;

        let status = resp.status();
        if status == reqwest::StatusCode::PARTIAL_CONTENT {
            let total = resp
                .headers()
                .get(reqwest::header::CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                .and_then(parse_content_range_total);
            Ok(RangeResponse {
                resp,
                total,
                start,
            })
        } else if status == reqwest::StatusCode::OK {
            let total = resp.content_length().map(|n| n as u64);
            Ok(RangeResponse { resp, total, start: 0 })
        } else {
            Err(format!("HTTP 状态异常: {status}"))
        }
    }

    fn next_chunk(inner: &mut Inner) -> io::Result<Option<Bytes>> {
        let resp = match inner.resp.as_mut() {
            Some(r) => r,
            None => return Ok(None),
        };
        let chunk = http_runtime()
            .block_on(resp.chunk())
            .map_err(io_err)?;
        Ok(chunk)
    }

    fn ensure_stream(inner: &mut Inner, client: &reqwest::Client, url: &str, total_out: &mut Option<u64>) -> io::Result<()> {
        const SKIP_REOPEN_THRESHOLD: u64 = 2 * 1024 * 1024;
        let need_reopen = match &inner.resp {
            None => true,
            Some(_) => {
                inner.pos < inner.resp_start
                    || inner.pos.saturating_sub(inner.resp_pos) > SKIP_REOPEN_THRESHOLD
            }
        };
        if !need_reopen {
            return Ok(());
        }
        inner.resp = None;
        inner.pending = Bytes::new();
        let rr = http_runtime()
            .block_on(Self::request_range(client, url, inner.pos))
            .map_err(io_err)?;
        if rr.total.is_some() {
            *total_out = rr.total;
        }
        inner.resp_start = rr.start;
        inner.resp_pos = rr.start;
        inner.resp = Some(rr.resp);
        Ok(())
    }
}

fn parse_content_range_total(v: &str) -> Option<u64> {
    let idx = v.rfind('/')?;
    let total = v[idx + 1..].trim();
    if total == "*" {
        return None;
    }
    total.parse().ok()
}

impl Read for HttpSeekableReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let mut inner = self.inner.lock().map_err(|e| io_err(e))?;

        loop {
            Self::ensure_stream(&mut inner, &self.client, &self.url, &mut self.total)?;

            while inner.pos > inner.resp_pos {
                if inner.pending.is_empty() {
                    match Self::next_chunk(&mut inner)? {
                        Some(b) => inner.pending = b,
                        None => return Err(io_err("流在目标位置前提前结束")),
                    }
                }
                let skip = (inner.pos - inner.resp_pos) as usize;
                let n = skip.min(inner.pending.len());
                inner.pending.advance(n);
                inner.resp_pos += n as u64;
            }

            let mut cap = buf.len();
            if let Some(total) = self.total {
                let remain = total.saturating_sub(inner.pos) as usize;
                cap = cap.min(remain);
                if cap == 0 {
                    return Ok(0);
                }
            }
            while inner.pending.is_empty() {
                match Self::next_chunk(&mut inner)? {
                    Some(b) => inner.pending = b,
                    None => return Ok(0),
                }
            }
            let n = cap.min(inner.pending.len());
            buf[..n].copy_from_slice(&inner.pending[..n]);
            inner.pending.advance(n);
            inner.pos += n as u64;
            inner.resp_pos += n as u64;
            return Ok(n);
        }
    }
}

impl Seek for HttpSeekableReader {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let mut inner = self.inner.lock().map_err(|e| io_err(e))?;
        let new_pos: i64 = match pos {
            SeekFrom::Start(o) => o as i64,
            SeekFrom::End(o) => self
                .total
                .ok_or_else(|| io_err("流式源未知总长，不支持 End 定位"))?
                as i64
                + o,
            SeekFrom::Current(o) => inner.pos as i64 + o,
        };
        if new_pos < 0 {
            return Err(io_err("seek 位置越界（负数）"));
        }
        inner.pos = new_pos as u64;
        Ok(inner.pos)
    }
}

impl symphonia::core::io::MediaSource for HttpSeekableReader {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        self.total
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_content_range_total_values() {
        assert_eq!(
            parse_content_range_total("bytes 0-1023/45678"),
            Some(45678)
        );
        assert_eq!(parse_content_range_total("bytes 100-199/*"), None);
        assert_eq!(parse_content_range_total("bytes 0-1/abc"), None);
        assert_eq!(parse_content_range_total("garbage"), None);
    }
}
