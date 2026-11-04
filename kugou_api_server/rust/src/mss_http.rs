//! 小-MSS HTTPS 传输：黑名单等大上行端点专用（request.rs `do_send` 按选项分支调用）。
//!
//! 背景（真机实测，2026-10-11）：部分网络路径存在 **PMTU 黑洞**——设备接口 MTU
//! 1500（TCP MSS 1460），但路径实际只放行 ≤~1300B 的包，且不回 ICMP
//! fragmentation-needed；Android 默认 `tcp_mtu_probing=0`，超限 TCP 段无限重传，
//! 连接表现为 ESTABLISHED 永久挂死（不报错、不吃超时）。黑名单 edit 请求
//! （256 字符 RSA hex 的 p 字段 + items JSON，~1.9KB）是全应用少有的大上行请求，
//! 常规 ureq 管线（整包一次 write，内核按 MSS 1460 切段）在此类网络下必然挂死；
//! 列表 GET 的 Cookie/Token 头也在阈值边缘（时好时坏的间歇现象来源）。
//!
//! 处理（三条保险）：
//! 1. `TCP_MAXSEG` 钳到 1240（libc setsockopt，Unix 生效；Windows 宿主测试
//!    环境自动跳过——宿主网络健康，不需要）；
//! 2. 请求头/请求体**分两次 write+flush**（rustls 每 flush 产出一条 ≤块长的
//!    TLS record，配 TCP_NODELAY → 各自成 ≤1250B 的 TCP 段，绕开黑洞阈值）；
//! 3. 每次 fresh 连接 + `Connection: close` + 显式连接/读写超时——不复用
//!    连接池（LB 静默断开的陈旧连接复用是另一个挂死来源），任何网络异常
//!    都转成确定性的 502，而不是无限等待。
//!
//! 签名/参数/头/SSA 重试构建完全复用 request.rs 既有管线，本模块只替换
//! socket/TLS 层，因此请求字节与 JS 参考实现对齐的逻辑不受影响。

use std::io::{Read, Write};
use std::net::{IpAddr, TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

/// 单次连接/读写的默认超时。与全局 ureq Agent 的 20s 对齐。
pub const IO_TIMEOUT: Duration = Duration::from_secs(20);
/// TCP 连接建立超时（逐地址尝试，多地址时依次回退）。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

pub struct MssHttpResponse {
    pub status: u16,
    pub set_cookies: Vec<String>,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// 发起一次小-MSS HTTPS 请求（fresh 连接，用完即关）。
/// `headers` 不得包含 Host/Content-Length/Connection（由本模块添加）；
/// body 为 None 时按无请求体发送（GET 等）。
pub fn https_send(
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: Option<&str>,
    mss: u32,
) -> Result<MssHttpResponse, String> {
    let (host, port, path) = parse_https_url(url)?;
    let addrs: Vec<std::net::SocketAddr> = match host.parse::<IpAddr>() {
        Ok(ip) => vec![std::net::SocketAddr::new(ip, port)],
        Err(_) => (host.as_str(), port)
            .to_socket_addrs()
            .map_err(|e| format!("dns resolve failed: {e}"))?
            .collect(),
    };
    if addrs.is_empty() {
        return Err("dns resolve failed: no address".to_string());
    }

    // 逐地址尝试：连接失败（拒绝/超时）退下一个地址；
    // 连接成功后的 TLS/读写失败不再重试（交由上层转 502）。
    let mut last_err = "no address attempted".to_string();
    for addr in &addrs {
        match try_send(*addr, &host, method, &path, headers, body, mss) {
            Ok(resp) => return Ok(resp),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

fn try_send(
    addr: std::net::SocketAddr,
    host: &str,
    method: &str,
    path: &str,
    headers: &[(String, String)],
    body: Option<&str>,
    mss: u32,
) -> Result<MssHttpResponse, String> {
    let tcp = TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT)
        .map_err(|e| format!("connect {addr} failed: {e}"))?;
    let _ = tcp.set_nodelay(true);
    let _ = tcp.set_read_timeout(Some(IO_TIMEOUT));
    let _ = tcp.set_write_timeout(Some(IO_TIMEOUT));
    clamp_mss(&tcp, mss);

    let config = tls_config()?;
    let sni = rustls_pki_types_server_name(host)?;
    let conn = rustls::ClientConnection::new(config, sni)
        .map_err(|e| format!("tls connection creation failed: {e}"))?;
    let mut stream = rustls::StreamOwned::new(conn, tcp);

    // 请求头与请求体分开 flush：rustls 每次 flush 产出一条独立 TLS record，
    // 配合 TCP_NODELAY，两段各自成一个小 TCP 段（≤ record 大小），避开
    // PMTU 黑洞阈值。头/体单独都 < 1250B（黑名单请求实测 ~0.7KB / ~1.1KB）。
    let head = build_head(method, host, path, headers, body);
    stream
        .write_all(head.as_bytes())
        .and_then(|_| stream.flush())
        .map_err(|e| format!("request head send failed: {e}"))?;
    if let Some(b) = body {
        stream
            .write_all(b.as_bytes())
            .and_then(|_| stream.flush())
            .map_err(|e| format!("request body send failed: {e}"))?;
    }

    let mut raw = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => raw.extend_from_slice(&chunk[..n]),
            // Connection: close 下服务器不发 close_notify 直接关连接是常态，
            // rustls 以 ConnectionAborted("...CloseNotify/peer closed...") 表达，
            // 视为正常 EOF；其余错误才算失败。
            Err(ref e) if is_peer_close(e) => break,
            Err(e) => return Err(format!("response read failed: {e}")),
        }
    }

    parse_response(&raw).inspect(|resp| {
        // 诊断日志：黑名单上游的真实响应（业务 error_code/message 只在这里可见）。
        // 只记路径不记 query——query 里带用户 token，日志不能落令牌；
        // 请求参数（hash/singerid/name 等）由 blacklist handler 的 [BLACKLIST] 行覆盖。
        let path_only = path.split('?').next().unwrap_or(path);
        let preview = String::from_utf8_lossy(&resp.body[..resp.body.len().min(300)]);
        log::info!(
            "[MSS_HTTP] {method} {path_only} -> status={} len={} body={preview}",
            resp.status,
            resp.body.len()
        );
    })
}

/// 组装 HTTP/1.1 请求头（Host/Accept/Connection/Content-Length 由本模块添加，
/// 调用方传入的头不含这四个）。
fn build_head(
    method: &str,
    host: &str,
    path: &str,
    headers: &[(String, String)],
    body: Option<&str>,
) -> String {
    let mut head = format!("{method} {path} HTTP/1.1\r\nHost: {host}\r\nAccept: */*\r\nConnection: close\r\n");
    for (k, v) in headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    if let Some(b) = body {
        head.push_str(&format!("Content-Length: {}\r\n", b.len()));
    }
    head.push_str("\r\n");
    head
}

fn is_peer_close(e: &std::io::Error) -> bool {
    if e.kind() != std::io::ErrorKind::ConnectionAborted
        && e.kind() != std::io::ErrorKind::UnexpectedEof
    {
        return false;
    }
    let msg = e.to_string();
    msg.contains("close_notify")
        || msg.contains("peer closed")
        || msg.contains("UnexpectedEof")
        || msg.contains("unexpected EOF")
}

fn tls_config() -> Result<Arc<rustls::ClientConfig>, String> {
    // 与 ureq 2.12 的 rtls.rs 同装配：ring provider 显式传入（避免进程级
    // default provider 未安装时 builder() panic），webpki-roots 信任源。
    static CONFIG: std::sync::OnceLock<Result<Arc<rustls::ClientConfig>, String>> =
        std::sync::OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = rustls::RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
            };
            let config = rustls::ClientConfig::builder_with_provider(
                rustls::crypto::ring::default_provider().into(),
            )
            .with_protocol_versions(&[&rustls::version::TLS12, &rustls::version::TLS13])
            .map_err(|e| format!("tls versions config failed: {e}"))?
            .with_root_certificates(roots)
            .with_no_client_auth();
            Ok(Arc::new(config))
        })
        .clone()
}

fn rustls_pki_types_server_name(host: &str) -> Result<rustls::pki_types::ServerName<'static>, String> {
    use rustls::pki_types::ServerName;
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(ServerName::IpAddress(ip.into()));
    }
    ServerName::try_from(host.to_string())
        .map_err(|e| format!("server name '{host}' invalid: {e}"))
}

fn parse_https_url(url: &str) -> Result<(String, u16, String), String> {
    let rest = url
        .strip_prefix("https://")
        .ok_or_else(|| "mss transport requires https url".to_string())?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    // 去掉可能的 userinfo（本仓上游不含，防御性处理）
    let authority = authority.rsplit_once('@').map(|(_, a)| a).unwrap_or(authority);
    let (host_part, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()) => {
            (h, p.parse::<u16>().map_err(|_| "bad port".to_string())?)
        }
        _ => (authority, 443),
    };
    let host = host_part
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_string();
    if host.is_empty() {
        return Err("empty host".to_string());
    }
    Ok((host, port, path.to_string()))
}

fn parse_response(raw: &[u8]) -> Result<MssHttpResponse, String> {
    let sep = find(raw, b"\r\n\r\n").ok_or("malformed http response: no header terminator")?;
    let head_str = String::from_utf8_lossy(&raw[..sep]);
    let mut lines = head_str.split("\r\n");
    let status_line = lines.next().ok_or("empty http response")?;
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| format!("bad status line: {status_line}"))?;

    let mut set_cookies = Vec::new();
    let mut headers = Vec::new();
    let mut chunked = false;
    let mut content_length: Option<usize> = None;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            let k = k.trim();
            let v = v.trim();
            if k.eq_ignore_ascii_case("set-cookie") {
                set_cookies.push(v.to_string());
            } else {
                headers.push((k.to_string(), v.to_string()));
            }
            if k.eq_ignore_ascii_case("transfer-encoding") && v.to_ascii_lowercase().contains("chunked") {
                chunked = true;
            }
            if k.eq_ignore_ascii_case("content-length") {
                content_length = v.parse().ok();
            }
        }
    }

    let mut body = raw[sep + 4..].to_vec();
    if chunked {
        body = decode_chunked(&body)?;
    } else if let Some(cl) = content_length {
        if body.len() > cl {
            body.truncate(cl);
        }
    }

    Ok(MssHttpResponse {
        status,
        set_cookies,
        headers,
        body,
    })
}

fn decode_chunked(mut input: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    loop {
        let line_end = find(input, b"\r\n").ok_or("bad chunked encoding: no size line")?;
        let size_str = std::str::from_utf8(&input[..line_end])
            .map_err(|_| "bad chunked encoding: non-ascii size line".to_string())?;
        let size = usize::from_str_radix(
            size_str.trim().split(';').next().unwrap_or("0").trim(),
            16,
        )
        .map_err(|_| format!("bad chunk size: {size_str}"))?;
        input = &input[line_end + 2..];
        if size == 0 {
            break;
        }
        if input.len() < size {
            return Err("bad chunked encoding: truncated chunk".to_string());
        }
        out.extend_from_slice(&input[..size]);
        input = &input[size.min(input.len())..];
        // 跳过 chunk 数据后的 CRLF（若缓冲里还有）
        if input.starts_with(b"\r\n") {
            input = &input[2..];
        }
    }
    Ok(out)
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.len() > haystack.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

/// Unix：TCP_MAXSEG 钳制出站段大小（连接建立后设置同样生效——内核
/// tcp_current_mss 尊重 user_mss）。Windows 宿主不支持，静默跳过。
#[cfg(unix)]
fn clamp_mss(stream: &TcpStream, mss: u32) {
    use std::os::fd::AsRawFd;
    let val: libc::c_int = mss as libc::c_int;
    let rc = unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::IPPROTO_TCP,
            libc::TCP_MAXSEG,
            &val as *const libc::c_int as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
    if rc != 0 {
        // 钳制失败不致命：还有「头/体分 record + NODELAY」这层保险
        log::warn!("[MSS_HTTP] TCP_MAXSEG({mss}) setsockopt failed: {}", std::io::Error::last_os_error());
    }
}

#[cfg(not(unix))]
fn clamp_mss(_stream: &TcpStream, _mss: u32) {}
