//! user 系列：cloud / cloud_url / detail / follow / follow_message /
//! grade_info / history / listen / playlist / video_collect / video_love / vip_detail
//! 对应 JS module/user*.js

use crate::cache::now_epoch_secs;
use crate::config::{APP_ID, CLIENT_VER, CLIENT_VER_NUM};
use crate::crypto::{
    base64_decode, crypto_md5_str, crypto_rsa_encrypt, md5_hex, playlist_aes_decrypt,
    playlist_aes_encrypt, rsa_encrypt2,
};
use crate::helper::{sign_cloud_key, sign_params_key};
use crate::modules::{
    c_str, cookie_or_param_num, cookie_or_param_str, forward, param_or_cookie_str, q_cookie,
    q_num, q_raw_or, q_str, Ctx,
};
use crate::request::{create_request, raw_request, BodyData, BodyValue, ModuleResponse, RequestOptions};
use crate::util::json_stringify;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::mpsc::{self, Sender};
use std::sync::Arc;

fn now_secs() -> i64 {
    now_epoch_secs() as i64
}

/// JS `cryptoRSAEncrypt({...}).toUpperCase()`。
fn rsa_pk_upper(obj: &Value) -> String {
    crypto_rsa_encrypt(&json_stringify(obj), None).to_uppercase()
}

/// user_cloud.js → /user/cloud（云盘歌曲列表，playlistAES + arraybuffer）。
pub fn handle_cloud(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // JS `params?.userid || params?.cookie?.userid || 0`：保留字符串原值，
    // 全部缺失时才用数字 0。强转 i64 会让 RSA/AES 明文与 JS 版不一致，鉴权失败。
    let userid_raw = param_or_cookie_str(q, "userid", "");
    let userid: Value = if userid_raw.is_empty() { json!(0) } else { json!(userid_raw) };
    let token = param_or_cookie_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");
    let clienttime = now_secs();

    // dataMap：JS `params.page ?? 1` / `params.pagesize ?? 30` 保留原始字符串，
    // 缺失时才用数字默认值（与 JSON.stringify 明文逐字节一致）。
    let dm = json!({
        "page": q_raw_or(q, "page", json!(1)),
        "pagesize": q_raw_or(q, "pagesize", json!(30)),
        "getkmr": 1,
    });
    let (key, aes_str) = playlist_aes_encrypt(&json_stringify(&dm));
    let p = rsa_encrypt2(&json_stringify(&json!({ "aes": key, "uid": userid, "token": token })))
        .to_uppercase();

    let mut pm: Map<String, Value> = Map::new();
    pm.insert("clienttime".to_string(), json!(clienttime));
    if !mid.is_empty() {
        pm.insert("mid".to_string(), json!(mid));
    }
    pm.insert(
        "key".to_string(),
        json!(sign_params_key(&clienttime.to_string(), APP_ID, "")),
    );
    pm.insert("clientver".to_string(), json!(CLIENT_VER));
    pm.insert("appid".to_string(), json!(APP_ID));
    pm.insert("p".to_string(), json!(p));

    let opts = RequestOptions::new("/v1/get_list")
        .base_url("https://mcloudservice.kugou.com")
        .post("/v1/get_list")
        .params(Value::Object(pm.clone()))
        .bytes_body(base64_decode(&aes_str))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .response_type("arraybuffer")
        .clear_default_params(true)
        .not_signature(true);
    let res = ctx.send(&opts)?;
    let dec = playlist_aes_decrypt(&key, &res.body.to_base64());
    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(dec),
        cookie: res.cookie,
        headers: res.headers,
    })
}

/// user_cloud_url.js → /user/cloud/url（获取云盘音乐 URL）。
pub fn handle_cloud_url(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let hash = q_str(q, "hash", "").to_ascii_lowercase();
    let pm = json!({
        "hash": hash,
        "ssa_flag": "is_fromtrack",
        "version": "20102",
        "ssl": 0,
        // JS `params.album_audio_id ?? 0` / `params.audio_id ?? 0`：
        // 保留原始字符串（云盘上传歌曲依赖该字段），缺失才用数字 0。
        "album_audio_id": q_raw_or(q, "album_audio_id", json!(0)),
        "pid": 20026,
        "audio_id": q_raw_or(q, "audio_id", json!(0)),
        // 云盘文件各自有 kv_id（列表接口返回），请求音质需与文件匹配，
        // 支持前端透传 kv_id，默认 2（JS 版历史默认值）。
        "kv_id": q_raw_or(q, "kv_id", json!(2)),
        "key": sign_cloud_key(&hash, "20026"),
        "bucket": "musicclound",
        "name": q_str(q, "name", ""),
        "with_res_tag": 0,
    });
    forward(
        q, ctx, "GET", "/bsstrackercdngz/v2/query_musicclound_url", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// user_cloud_upload.js → /user/cloud/upload（上传音乐文件到云盘）。
///
/// 5 步流程（对齐 JS 版）：
///   1. GET bssulbig.kugou.com/v2/authorization         → authorization
///   2. POST bssulbig.kugou.com/multipart/initiate/music → external_host + upload_id
///      （upload_id 为空表示文件已在服务器 → 秒传，跳过 3/4）
///   3. POST {external_host}/multipart/upload            → 4MB/片 上传分片
///   4. POST {external_host}/multipart/complete          → 完成上传
///   5. POST mcloudservice.kugou.com/v1/add_files        → playlistAES+RSA 添加到云盘
///
/// 请求体为前端透传的文件二进制（application/octet-stream）。
/// 步骤 1-4 用 raw_request（无签名，对齐 JS 版原生 axios）；步骤 5 走签名工厂。
///
/// 响应为 **NDJSON 进度流**（application/x-ndjson，chunked）：步骤 1/2 失败仍走
/// 非 200 JSON 错误响应；initiate 成功后立即返回 200 流式响应，步骤 3/4/5 在
/// worker 线程执行并逐行推送：
///   {"type":"stage","name":"matching|finalizing"}
///   {"type":"progress","uploaded":N,"total":M}   （秒传时附 "stage":"instant"）
///   {"type":"result","data":{...}}                （恒为最后一行，data 含
///                                                  add_files 响应 + uploadInfo + matchInfo）
/// 可选 query 参数 `match=1|true`：上传前按文件 MD5 调 KMR 曲库匹配
/// （见 [kmr_match_hash]），命中后把 album_audio_id/audio_id 写入 add_files，
/// 云盘列表即显示官方歌名/歌手并具备官方歌词、封面等能力；未命中静默降级。
pub fn handle_cloud_upload(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // userid 必须为字符串（步骤 5 RSA 加密时服务端校验 uid 类型）
    let userid = param_or_cookie_str(q, "userid", "");
    let token = param_or_cookie_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");
    let version = CLIENT_VER.to_string();
    let bucket = "musicclound".to_string();

    // 文件二进制数据（octet-stream body）。Arc 引用计数零拷贝地 move 进 worker。
    let file_data: Arc<[u8]> = ctx.body_bytes.clone().unwrap_or_default();
    if file_data.is_empty() {
        return Err(ModuleResponse {
            status: 400,
            body: BodyValue::Json(json!({ "status": 0, "msg": "请通过请求体传入文件二进制数据" })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }

    // filename 即文件 MD5（小写），可传覆盖，默认自动计算
    let filename = {
        let f = q_str(q, "filename", "").to_ascii_lowercase();
        if f.is_empty() { md5_hex(&file_data) } else { f }
    };
    // 扩展名（自动去掉点号），默认 mp3
    let extendname = q_str(q, "extendname", "mp3").trim_start_matches('.').to_string();
    let author_name = q_str(q, "author_name", "");
    let name = {
        let n = q_str(q, "name", "");
        if n.is_empty() {
            let prefix = if author_name.is_empty() {
                String::new()
            } else {
                format!("{} - ", author_name)
            };
            format!("{}{}.{}", prefix, filename, extendname)
        } else {
            n
        }
    };

    // 模拟客户端随机 KG-THash（固定 7 位 hex）
    let thash = format!("{:07x}", (now_epoch_secs() as u64) & 0x0FFF_FFFF);
    let mut base_headers: HashMap<String, String> = HashMap::new();
    base_headers.insert("User-Agent".to_string(), "Android15-1070-10672-201-0-wifi".to_string());
    base_headers.insert("KG-RC".to_string(), "1".to_string());
    base_headers.insert("KG-Rec".to_string(), "1".to_string());
    base_headers.insert("KG-THash".to_string(), thash);

    // ========== 步骤1 获取上传授权 ==========
    let auth_res = raw_request(
        "GET",
        "http://bssulbig.kugou.com/v2/authorization",
        &json!({ "version": version, "userid": userid, "filename": filename, "token": token, "appid": APP_ID, "method": "POST", "bucket": bucket }),
        BodyData::None,
        &base_headers,
    ).map_err(|e| e)?;
    let authorization = auth_res
        .body
        .to_json()
        .get("data")
        .and_then(|d| d.get("authorization"))
        .and_then(|a| a.as_str())
        .unwrap_or_default()
        .to_string();
    if authorization.is_empty() {
        return Err(ModuleResponse {
            status: 502,
            body: BodyValue::Json(json!({ "status": 0, "msg": "获取上传授权失败" })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }

    // ========== 步骤2 初始化分片上传 ==========
    let mut init_headers = base_headers.clone();
    init_headers.insert("Authorization".to_string(), authorization.clone());
    let init_res = raw_request(
        "POST",
        "http://bssulbig.kugou.com/multipart/initiate/music",
        &json!({ "version": version, "extendname": extendname, "userid": userid, "filename": filename, "appid": APP_ID, "bucket": bucket }),
        BodyData::None,
        &init_headers,
    ).map_err(|e| e)?;
    let init_json = init_res.body.to_json();
    let external_host = init_json
        .get("data")
        .and_then(|d| d.get("external_host"))
        .and_then(|h| h.as_str())
        .unwrap_or_default()
        .to_string();
    let upload_id = init_json
        .get("data")
        .and_then(|d| d.get("upload_id"))
        .and_then(|u| u.as_str())
        .unwrap_or_default()
        .to_string();

    // ========== 进入流式阶段：initiate 已成功，立即返回 200 NDJSON 流 ==========
    // 步骤 3/4/5（分片/完成/add_files，含可选 KMR 匹配）全部移交 worker 线程，
    // 逐行推送进度；客户端断开（接收端被丢弃）时 send 报错，worker 随即中止。
    let want_match = {
        let m = q_str(q, "match", "").to_ascii_lowercase();
        m == "1" || m == "true"
    };
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let job = CloudUploadJob {
        tx,
        file_data,
        authorization,
        external_host,
        upload_id,
        version,
        userid,
        token,
        mid,
        bucket,
        extendname,
        name,
        author_name,
        filename,
        base_headers,
        cookie: q_cookie(q),
        want_match,
        bitrate: q_num(q, "bitrate", 4),
        audio_id: q_num(q, "audio_id", 0),
        album_audio_id: q_num(q, "album_audio_id", 0),
        timelen: q_num(q, "timelen", 0),
        list_ver: q_num(q, "list_ver", 0),
    };
    if std::thread::Builder::new()
        .name("cloud-upload".into())
        .stack_size(256 * 1024)
        .spawn(move || run_cloud_upload_worker(job))
        .is_err()
    {
        return Err(ModuleResponse {
            status: 500,
            body: BodyValue::Json(json!({ "status": 0, "msg": "上传线程创建失败" })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }

    Ok(ModuleResponse {
        status: 200,
        body: BodyValue::Stream(Box::new(ChannelReader::new(rx))),
        cookie: Vec::new(),
        headers: HashMap::from([(
            "content-type".to_string(),
            "application/x-ndjson".to_string(),
        )]),
    })
}

/// 云盘上传 worker 的全部入参（handle_cloud_upload 步骤 1/2 成功后构建）。
struct CloudUploadJob {
    tx: Sender<Vec<u8>>,
    file_data: Arc<[u8]>,
    authorization: String,
    external_host: String,
    upload_id: String,
    version: String,
    userid: String,
    token: String,
    mid: String,
    bucket: String,
    extendname: String,
    name: String,
    author_name: String,
    filename: String,
    base_headers: HashMap<String, String>,
    cookie: Value,
    want_match: bool,
    bitrate: i64,
    audio_id: i64,
    album_audio_id: i64,
    timelen: i64,
    list_ver: i64,
}

/// 向进度流写一行 NDJSON（JSON + '\n'）。返回 false = 客户端已断开。
fn send_ndjson(tx: &Sender<Vec<u8>>, v: &Value) -> bool {
    let mut line = json_stringify(v).into_bytes();
    line.push(b'\n');
    tx.send(line).is_ok()
}

/// 从上游错误响应提取人读的 msg（无则回退 HTTP 状态码）。
fn extract_err_msg(e: &ModuleResponse) -> String {
    let j = e.body.to_json();
    match j.get("msg") {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        Some(v @ Value::Object(_)) => json_stringify(v),
        _ => format!("HTTP {}", e.status),
    }
}

/// worker 主体：分片上传 → 完成 → add_files（含可选 KMR 匹配），
/// 每完成一个阶段向进度流推送一行 NDJSON。任一步失败都保证写出
/// result 行（data.status = 0 + msg）再退出，客户端不会读到半截响应。
fn run_cloud_upload_worker(job: CloudUploadJob) {
    let CloudUploadJob {
        tx,
        file_data,
        authorization,
        external_host,
        upload_id,
        version,
        userid,
        token,
        mid,
        bucket,
        extendname,
        name,
        author_name,
        filename,
        base_headers,
        cookie,
        want_match,
        bitrate,
        audio_id,
        album_audio_id,
        timelen,
        list_ver,
    } = job;
    // 发送失败 = 客户端已断开（HTTP 连接关闭），立即中止上传。
    macro_rules! emit {
        ($v:expr) => {
            if !send_ndjson(&tx, &$v) {
                eprintln!(
                    "[CloudUpload] 客户端已断开，中止上传 hash={}",
                    &filename[..filename.len().min(8)]
                );
                return;
            }
        };
    }

    let total = file_data.len() as i64;
    eprintln!(
        "[CloudUpload] 开始 hash={}… size={} match={} instant={}",
        &filename[..filename.len().min(8)],
        total,
        want_match,
        upload_id.is_empty()
    );

    // ---------- 可选：KMR 曲库匹配（best-effort，失败静默降级为普通上传） ----------
    let mut match_audio_id = 0i64;
    let mut match_album_audio_id = 0i64;
    let mut match_info = json!({ "matched": false });
    if want_match {
        emit!(json!({ "type": "stage", "name": "matching" }));
        match kmr_match_hash(&cookie, &filename) {
            Some(m) => {
                let ai = m.get("audio_id").and_then(Value::as_i64).unwrap_or(0);
                let aa = m.get("album_audio_id").and_then(Value::as_i64).unwrap_or(0);
                if ai > 0 || aa > 0 {
                    eprintln!(
                        "[CloudUpload] 曲库匹配命中 audio_id={} album_audio_id={}",
                        ai, aa
                    );
                    match_audio_id = ai;
                    match_album_audio_id = aa;
                    match_info = json!({
                        "matched": true,
                        "audio_id": ai,
                        "album_audio_id": aa,
                        "audio_name": m.get("audio_name").cloned().unwrap_or(json!("")),
                        "author_name": m.get("author_name").cloned().unwrap_or(json!("")),
                    });
                }
            }
            None => {
                eprintln!("[CloudUpload] 曲库匹配未命中/失败，按普通上传继续");
            }
        }
    }

    // ---------- 步骤3/4：分片上传与完成（秒传时跳过） ----------
    if upload_id.is_empty() {
        // 秒传：文件已在服务器（服务端按 MD5 判定）
        emit!(json!({ "type": "progress", "stage": "instant", "uploaded": total, "total": total }));
    } else {
        let part_size: usize = 1024 * 1024 * 4;
        let part_count = (file_data.len() + part_size - 1) / part_size;
        let mut upload_headers = base_headers.clone();
        upload_headers.insert("Authorization".to_string(), authorization.clone());
        upload_headers.insert(
            "Content-Type".to_string(),
            "application/octet-stream".to_string(),
        );
        for i in 0..part_count {
            let start = i * part_size;
            let end = ((i + 1) * part_size).min(file_data.len());
            let part = file_data[start..end].to_vec();
            let upload_res = match raw_request(
                "POST",
                &format!("http://{}/multipart/upload", external_host),
                &json!({ "version": version, "userid": userid, "filename": filename, "appid": APP_ID, "upload_id": upload_id, "partnumber": i + 1, "bucket": bucket }),
                BodyData::Bytes(part),
                &upload_headers,
            ) {
                Ok(r) => r,
                Err(e) => {
                    let msg = format!("分片上传失败: part {} ({})", i + 1, extract_err_msg(&e));
                    eprintln!("[CloudUpload] {}", msg);
                    emit!(json!({ "type": "result", "data": { "status": 0, "msg": msg } }));
                    return;
                }
            };
            let ok = upload_res.body.to_json().get("status").and_then(|s| s.as_i64()) == Some(1);
            if !ok {
                let msg = format!("分片上传失败: part {}", i + 1);
                eprintln!("[CloudUpload] {}", msg);
                emit!(json!({ "type": "result", "data": { "status": 0, "msg": msg } }));
                return;
            }
            let uploaded = ((i + 1) * part_size).min(file_data.len()) as i64;
            emit!(json!({ "type": "progress", "uploaded": uploaded, "total": total }));
        }

        // 步骤4 完成上传
        emit!(json!({ "type": "stage", "name": "finalizing" }));
        let mut complete_headers = base_headers.clone();
        complete_headers.insert("Authorization".to_string(), authorization.clone());
        let complete_res = match raw_request(
            "POST",
            &format!("http://{}/multipart/complete", external_host),
            &json!({ "filename": filename, "bucket": bucket, "if_id3": 1, "upload_id": upload_id, "userid": userid, "md5": filename, "version": version, "appid": APP_ID, "partnumber": part_count }),
            BodyData::None,
            &complete_headers,
        ) {
            Ok(r) => r,
            Err(e) => {
                let msg = format!("完成上传失败 ({})", extract_err_msg(&e));
                eprintln!("[CloudUpload] {}", msg);
                emit!(json!({ "type": "result", "data": { "status": 0, "msg": msg } }));
                return;
            }
        };
        let ok = complete_res.body.to_json().get("status").and_then(|s| s.as_i64()) == Some(1);
        if !ok {
            let msg = "完成上传失败".to_string();
            eprintln!("[CloudUpload] {}", msg);
            emit!(json!({ "type": "result", "data": { "status": 0, "msg": msg } }));
            return;
        }
    }

    // ---------- 步骤5 添加文件到云盘（AES 加密 body + RSA 加密密钥） ----------
    // 数字字段必须为 number 类型（字符串会导致上游 500）；
    // 匹配命中且调用方未显式传 ID 时，用 KMR 返回的官方 ID 关联云盘文件。
    let final_audio_id = if audio_id > 0 { audio_id } else { match_audio_id };
    let final_album_audio_id = if album_audio_id > 0 {
        album_audio_id
    } else {
        match_album_audio_id
    };

    let clienttime = now_secs();
    let aes_encrypt = playlist_aes_encrypt(&json_stringify(&json!({
        "data": [
            {
                "name": name,
                "ext": extendname,
                "author_name": author_name,
                "hash": filename,
                "hash_std": filename,
                "audio_id": final_audio_id,
                "bitrate": bitrate,
                "album_audio_id": final_album_audio_id,
                "size": file_data.len() as i64,
                "timelen": timelen,
            }
        ],
        "list_ver": list_ver,
    })));
    let p = rsa_encrypt2(&json_stringify(&json!({
        "aes": aes_encrypt.0,
        "uid": if userid.is_empty() { json!(0) } else { json!(userid) },
        "token": token,
    }))).to_uppercase();

    let mut pm: Map<String, Value> = Map::new();
    pm.insert("clienttime".to_string(), json!(clienttime));
    if !mid.is_empty() {
        pm.insert("mid".to_string(), json!(mid));
    }
    pm.insert(
        "key".to_string(),
        json!(sign_params_key(&clienttime.to_string(), APP_ID, "")),
    );
    pm.insert("clientver".to_string(), json!(CLIENT_VER));
    pm.insert("appid".to_string(), json!(APP_ID));
    pm.insert("p".to_string(), json!(p));

    let opts = RequestOptions::new("/v1/add_files")
        .base_url("https://mcloudservice.kugou.com")
        .post("/v1/add_files")
        .params(Value::Object(pm))
        .bytes_body(base64_decode(&aes_encrypt.1))
        .encrypt_type("android")
        .cookie(cookie)
        .response_type("arraybuffer")
        .clear_default_params(true)
        .not_signature(true);
    // worker 线程内直调签名工厂（Ctx::send 仅是 ip 透传 + create_request 薄包装）。
    let res = match create_request(&opts) {
        Ok(r) => r,
        Err(e) => {
            let msg = format!("添加到云盘失败: {}", extract_err_msg(&e));
            eprintln!("[CloudUpload] {}", msg);
            emit!(json!({ "type": "result", "data": { "status": 0, "msg": msg } }));
            return;
        }
    };

    // 尝试解密响应；解密结果为非 JSON（乱码字符串）时回退明文 JSON，
    // 与 JS 版 try/decrypt → catch → JSON.parse 的兜底行为一致。
    let mut body = if res.status == 200 {
        let dec = playlist_aes_decrypt(&aes_encrypt.0, &res.body.to_base64());
        match dec {
            Value::String(_) => res.body.to_json(),
            other => other,
        }
    } else {
        res.body.to_json()
    };

    // 附带整个上传流程的关键信息（hash/大小/匹配结果），便于排查与前端展示
    if let Some(obj) = body.as_object_mut() {
        obj.insert(
            "uploadInfo".to_string(),
            json!({
                "hash": filename,
                "filesize": file_data.len(),
            }),
        );
        obj.insert("matchInfo".to_string(), match_info);
    }
    eprintln!(
        "[CloudUpload] 完成 status={}",
        body.get("status").and_then(Value::as_i64).unwrap_or(0)
    );
    emit!(json!({ "type": "result", "data": body }));
}

/// mpsc 接收端 → `Read` 适配器：worker 每写一行 NDJSON，tiny_http 的 respond
/// 就能立刻读到并发给客户端（真正的边上传边回传进度）。
/// channel 关闭（worker 结束/中止）→ EOF。
struct ChannelReader {
    rx: mpsc::Receiver<Vec<u8>>,
    buf: Vec<u8>,
    pos: usize,
}

impl ChannelReader {
    fn new(rx: mpsc::Receiver<Vec<u8>>) -> Self {
        ChannelReader {
            rx,
            buf: Vec::new(),
            pos: 0,
        }
    }
}

impl std::io::Read for ChannelReader {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.buf.len() {
            match self.rx.recv() {
                Ok(chunk) => {
                    self.buf = chunk;
                    self.pos = 0;
                }
                Err(_) => return Ok(0), // sender 已 drop → EOF
            }
        }
        let n = (self.buf.len() - self.pos).min(out.len());
        out[..n].copy_from_slice(&self.buf[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

/// 上游 user_cloud_match.js（云盘上传前曲库匹配）的 Rust 端口。
///
/// 三方对照（2026-10-11，MakcRe/KuGouMusicApi@main）：
/// - 文档契约：`/user/cloud/match`（hash 参数或请求体计算 MD5）；
/// - 上游 JS：POST `http://kmr.service.kugou.com/v2/album_audio/audio`，头
///   `x-router: kmr.service.kugou.com`；dataMap = {appid: 3116, clienttime(秒),
///   clientver: 11440, data: [{hash}], dfid, key: signParamsKey(clienttime,
///   appid, clientver), mid, show_privilege: 0, show_author_alias: 0,
///   show_rel_album_audio_info: 0, show_remarks: 0}；encryptType android +
///   clearDefaultParams + notSignature；
/// - 本仓差异：不注册独立路由（Dart 契约为 /user/cloud/upload 的 `match`
///   参数），仅单 hash（上传场景逐文件调用）；appid/clientver 走
///   sign_params_key 的默认值（3116/11440，与上游一致，同 audio.rs）。
///
/// 返回归一化后的首个匹配项（见 [normalize_match_candidate]），未命中/失败为 None。
fn kmr_match_hash(cookie: &Value, hash: &str) -> Option<Value> {
    let clienttime = now_secs();
    let mid = cookie
        .get("KUGOU_API_MID")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let dfid = cookie
        .get("dfid")
        .and_then(Value::as_str)
        .unwrap_or("-")
        .to_string();

    let mut dm = Map::new();
    dm.insert("appid".to_string(), json!(3116));
    dm.insert("clienttime".to_string(), json!(clienttime));
    dm.insert("clientver".to_string(), json!(11440));
    dm.insert("data".to_string(), json!([{ "hash": hash }]));
    dm.insert("dfid".to_string(), json!(dfid));
    dm.insert(
        "key".to_string(),
        json!(sign_params_key(&clienttime.to_string(), "", "")),
    );
    if !mid.is_empty() {
        dm.insert("mid".to_string(), json!(mid));
    }
    dm.insert("show_privilege".to_string(), json!(0));
    dm.insert("show_author_alias".to_string(), json!(0));
    dm.insert("show_rel_album_audio_info".to_string(), json!(0));
    dm.insert("show_remarks".to_string(), json!(0));

    let opts = RequestOptions::new("/v2/album_audio/audio")
        .base_url("http://kmr.service.kugou.com")
        .post("/v2/album_audio/audio")
        .json_body(Value::Object(dm))
        .encrypt_type("android")
        .cookie(cookie.clone())
        .header("x-router", "kmr.service.kugou.com")
        .header("Content-Type", "application/json");
    let res = create_request(&opts).ok()?;
    let body = res.body.to_json();
    if body.get("status").and_then(Value::as_i64) != Some(1) {
        return None;
    }
    let data = body.get("data")?.as_array()?;
    data.iter().find_map(normalize_match_candidate)
}

/// 取 obj[key] 的非空字符串字段（缺失/空返回 None）。
fn non_empty_str_field<'a>(obj: &'a Value, key: &str) -> Option<&'a str> {
    obj.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// 上游 normalizeMatch：candidate 可能是数组（取首个）；
/// audio_id/album_audio_id 转 Number；audio_name 取
/// ori_audio_name || audio_name || songname；三项标识全空视为未匹配。
fn normalize_match_candidate(item: &Value) -> Option<Value> {
    let candidate = if item.is_array() { item.get(0)? } else { item };
    let audio_info = candidate
        .get("audio_info")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let as_i64 = |v: Option<&Value>| -> i64 {
        // 对齐上游 JS `Number(x) || 0`：KMR 偶发把 ID 回成字符串
        match v {
            Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
            Some(Value::String(s)) => s.trim().parse::<i64>().unwrap_or(0),
            _ => 0,
        }
    };
    let as_str = |v: Option<&Value>| -> String {
        v.and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    let album_audio_id = as_i64(candidate.get("album_audio_id"));
    let audio_id = as_i64(
        audio_info
            .get("audio_id")
            .or_else(|| candidate.get("audio_id")),
    );
    let hash_std = as_str(audio_info.get("hash").or_else(|| candidate.get("hash")));
    if album_audio_id == 0 && audio_id == 0 && hash_std.is_empty() {
        return None;
    }
    let audio_name = non_empty_str_field(&audio_info, "ori_audio_name")
        .or_else(|| non_empty_str_field(&audio_info, "audio_name"))
        .or_else(|| non_empty_str_field(&audio_info, "songname"))
        .unwrap_or_default()
        .to_string();
    Some(json!({
        "album_audio_id": album_audio_id,
        "audio_id": audio_id,
        "hash_std": hash_std,
        "hash": hash_std,
        "author_name": as_str(
            audio_info.get("author_name").or_else(|| candidate.get("author_name")),
        ),
        "audio_name": audio_name,
        "suffix_audio_name": as_str(audio_info.get("suffix_audio_name")),
        "album_info": audio_info.get("album_info").cloned().unwrap_or(Value::Null),
        "raw": candidate.clone(),
    }))
}

/// JS `Number(s) || s`：能解析为 i64 则转数字（上游要求 number 类型），
/// 否则保留原字符串（对应 JS 中 NaN || 字符串 的兜底）。
fn num_or_keep(s: &str) -> Value {
    s.trim()
        .parse::<i64>()
        .map(|n| json!(n))
        .unwrap_or_else(|_| json!(s))
}

/// user_cloud_del.js → /user/cloud/del（删除云盘音乐，支持单首与批量）。
///
/// 加密流程与 handle_cloud / handle_cloud_upload 一致：
/// dataMap（有 fileids 时按 kv_id+album_audio_id 构造，否则按 hash 数组）
/// → playlistAES 加密为 body；rsa_encrypt2({aes, uid, token}) 为 p；
/// POST mcloudservice.kugou.com/v1/del_files。
pub fn handle_cloud_del(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // userid 保留字符串原值，缺失时用数字 0（与 handle_cloud 一致，RSA 明文逐字节对齐 JS）
    let userid_raw = param_or_cookie_str(q, "userid", "");
    let userid: Value = if userid_raw.is_empty() {
        json!(0)
    } else {
        json!(userid_raw)
    };
    let token = param_or_cookie_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");
    let clienttime = now_secs();

    // 逗号分隔多值 → 去空字符串数组（兼容 JS 的 fileids/fileid/kv_ids/kv_id 等参数名）
    let split_csv = |key: &[&str]| -> Vec<String> {
        for k in key {
            if let Some(v) = q.get(*k) {
                if let Some(s) = v.as_str() {
                    let items: Vec<String> = s
                        .split(',')
                        .map(|x| x.trim().to_string())
                        .filter(|x| !x.is_empty())
                        .collect();
                    if !items.is_empty() {
                        return items;
                    }
                }
            }
        }
        Vec::new()
    };
    let fileids = split_csv(&["fileids", "fileid", "kv_ids", "kv_id"]);
    let album_audio_ids = split_csv(&["album_audio_ids", "album_audio_id"]);
    let hashes = split_csv(&["hashes", "hash", "filename"]);

    if fileids.is_empty() && hashes.is_empty() {
        return Err(ModuleResponse {
            status: 400,
            body: BodyValue::Json(json!({ "status": 0, "msg": "请传入 fileid、kv_id、hash 或 hashes" })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }

    // JS `params?.mixid || params?.mix_id` 兜底 album_audio_id
    let mix = q_str(q, "mixid", "");
    let mix_val = if mix.is_empty() { q_str(q, "mix_id", "") } else { mix };
    let fallback_aa = |i: usize| -> Value {
        let v = album_audio_ids
            .get(i)
            .or_else(|| album_audio_ids.first())
            .map(|s| s.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(mix_val.as_str());
        if v.is_empty() {
            json!(0)
        } else {
            num_or_keep(v)
        }
    };

    // 有 fileids 时按 {kv_id, album_audio_id} 构造；否则按 hash 字符串数组
    let dm = if !fileids.is_empty() {
        let data: Vec<Value> = fileids
            .iter()
            .enumerate()
            .map(|(i, id)| {
                json!({
                    "kv_id": num_or_keep(id),
                    "album_audio_id": fallback_aa(i),
                })
            })
            .collect();
        json!({ "data": data })
    } else {
        json!({ "data": hashes })
    };

    let (key, aes_str) = playlist_aes_encrypt(&json_stringify(&dm));
    let p = rsa_encrypt2(&json_stringify(&json!({ "aes": key, "uid": userid, "token": token })))
        .to_uppercase();

    let mut pm: Map<String, Value> = Map::new();
    pm.insert("clienttime".to_string(), json!(clienttime));
    if !mid.is_empty() {
        pm.insert("mid".to_string(), json!(mid));
    }
    pm.insert(
        "key".to_string(),
        json!(sign_params_key(&clienttime.to_string(), APP_ID, "")),
    );
    pm.insert("clientver".to_string(), json!(CLIENT_VER));
    pm.insert("appid".to_string(), json!(APP_ID));
    pm.insert("p".to_string(), json!(p));

    let opts = RequestOptions::new("/v1/del_files")
        .base_url("https://mcloudservice.kugou.com")
        .post("/v1/del_files")
        .params(Value::Object(pm.clone()))
        .bytes_body(base64_decode(&aes_str))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .response_type("arraybuffer")
        .clear_default_params(true)
        .not_signature(true);
    let res = ctx.send(&opts)?;

    // 尝试解密响应；解密结果为非 JSON（乱码字符串）时回退明文 JSON，与 JS 版一致
    let body = if res.status == 200 {
        let dec = playlist_aes_decrypt(&key, &res.body.to_base64());
        match dec {
            Value::String(_) => res.body.to_json(),
            other => other,
        }
    } else {
        res.body.to_json()
    };

    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(body),
        cookie: res.cookie,
        headers: res.headers,
    })
}

/// user_detail.js → /user/detail（获取用户信息）。
pub fn handle_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse::<i64>()
        .unwrap_or(0);
    let clienttime = now_secs();
    let pk = rsa_pk_upper(&json!({ "token": token, "clienttime": clienttime }));
    let dm = json!({
        "visit_time": clienttime,
        "usertype": 1,
        "p": pk,
        "userid": userid,
    });
    forward(
        q, ctx, "POST", "/v3/get_my_info", None,
        Some(json!({ "plat": 1 })), Some(dm), "android", &[("x-router", "usercenter.kugou.com")], false, false,
    )
}

// ==================== user_update.js / user_update_avatar.js ====================
//
// 修改个人资料不走 gateway 网关，用 user 服务的独立鉴权：
//   - 不需要 signature 签名，改用 body 里的 key + p 两个字段
//   - key = signParamsKey(clienttime)（概念版 appid/clientver）
//   - p   = RSA/ECB/NOPADDING(JSON.stringify({clienttime, token})) 的大写 hex
//           （注意字段序 clienttime 在前，与 JS JSON.stringify 一致）
// 所有参数都在 POST body 中，query 为空；中文直接 UTF-8。

/// JS `params?.body?.x || params?.x`：JSON body 落在 q["body"]，query 次之。
fn update_body_or_param(q: &Value, key: &str) -> Option<Value> {
    if let Some(b) = q.get("body") {
        if let Some(v) = b.get(key) {
            if !v.is_null() {
                return Some(v.clone());
            }
        }
    }
    match q.get(key) {
        Some(v) if !v.is_null() => Some(v.clone()),
        _ => None,
    }
}

/// /v1/update_userinfo 的公共实现。`photo` 非空时覆盖 body 里的 photo 字段
/// （头像上传第二步写入图床文件名用）。
fn user_update_core(
    q: &Value,
    ctx: &Ctx,
    photo: Option<&str>,
) -> Result<ModuleResponse, ModuleResponse> {
    use super::comment_send::bad_request;

    // signature / tags / birthday 允许传空串来清空；其余字段的空值会被忽略
    const NULLABLE_FIELDS: [&str; 3] = ["signature", "tags", "birthday"];
    const FIELDS: [&str; 9] = [
        "nickname",
        "sex",
        "birthday",
        "photo",
        "province",
        "city",
        "memo",
        "signature",
        "tags",
    ];

    let mut data = Map::new();
    for key in FIELDS {
        let val = if key == "photo" {
            photo.map(|p| json!(p)).or_else(|| update_body_or_param(q, key))
        } else {
            update_body_or_param(q, key)
        };
        let Some(val) = val else { continue };
        // JS `${val}`：数字 1 → "1"，布尔 true → "true"；字符串原样
        let s = match &val {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        if s.is_empty() && !NULLABLE_FIELDS.contains(&key) {
            continue;
        }
        data.insert(key.to_string(), json!(s));
    }

    if data.is_empty() {
        return Err(bad_request("至少需要提供一个待修改字段"));
    }

    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse::<i64>()
        .unwrap_or(0);
    let mid = c_str(q, "KUGOU_API_MID");
    let clienttime = now_secs();
    let key = sign_params_key(&clienttime.to_string(), APP_ID, "");
    let p = rsa_pk_upper(&json!({ "clienttime": clienttime, "token": token }));

    // JS config.json 的 appid/clientver 是数字，JSON.stringify 后不带引号
    let appid_num: i64 = APP_ID.parse().unwrap_or(3116);
    let dm = json!({
        "clienttime": clienttime,
        "appid": appid_num,
        "clientver": CLIENT_VER_NUM,
        "mid": mid,
        "uuid": "-",
        "userid": userid,
        "key": key,
        "p": p,
        "data": Value::Object(data),
    });

    forward(
        q, ctx, "POST", "/v1/update_userinfo",
        Some("http://update.user.kugou.com"),
        None, Some(dm), "android", &[], true, true,
    )
}

/// user_update.js → /user/update（修改个人资料：昵称/性别/生日/签名/地区等）。
pub fn handle_update(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    user_update_core(q, ctx, None)
}

/// 图床防盗链 token：md5(北京时间 yyyyMMdd + 固定盐)，小写 hex。
/// JS 版取设备本地日期；上游为中国服务器，这里固定按北京时间（UTC+8）计算。
const UPLOAD_SALT: &str = "hewry678WEK23D";

/// Howard Hinnant 的 civil_from_days：天数 → (年, 月, 日)。
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn beijing_ymd() -> String {
    let secs = now_secs() + 8 * 3600;
    let (y, m, d) = civil_from_days(secs.div_euclid(86400));
    format!("{y:04}{m:02}{d:02}")
}

/// 严格 base64 校验（JS Buffer.from 对非法字符静默忽略，必须先验再解码）：
/// 仅 [A-Za-z0-9+/]，末尾至多 2 个 '='，长度为 4 的倍数。
fn is_strict_base64(s: &str) -> bool {
    let bytes = s.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
        return false;
    }
    let mut padding = 0usize;
    for (i, &b) in bytes.iter().enumerate() {
        let ok = b.is_ascii_alphanumeric() || b == b'+' || b == b'/';
        if b == b'=' {
            // '=' 只允许出现在末尾，至多 2 个
            let from_end = bytes.len() - i;
            if from_end > 2 {
                return false;
            }
            padding += 1;
        } else if !ok {
            return false;
        }
    }
    // "XX==" 合法（2 数据字符），"X===" 不可能走到这里（长度限制已挡）
    padding <= 2 && bytes.len() >= 4
}

/// magic bytes 判定图片类型：返回对应 MIME（JPEG/PNG/GIF/BMP/WEBP）。
fn image_mime(buf: &[u8]) -> Option<&'static str> {
    if buf.len() < 4 {
        return None;
    }
    if buf[0] == 0xff && buf[1] == 0xd8 {
        return Some("image/jpeg");
    }
    if buf[0] == 0x89 && buf[1] == 0x50 && buf[2] == 0x4e && buf[3] == 0x47 {
        return Some("image/png");
    }
    if buf[0] == 0x47 && buf[1] == 0x49 && buf[2] == 0x46 {
        return Some("image/gif");
    }
    if buf[0] == 0x42 && buf[1] == 0x4d {
        return Some("image/bmp");
    }
    if buf.starts_with(b"RIFF") && buf.len() >= 12 && &buf[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    None
}

/// user_update_avatar.js → /user/update/avatar（修改头像，两步流程）。
///
/// 第 1 步 multipart 上传图床 imgphp.kugou.com 拿 FileName；
/// 第 2 步复用 user_update_core 把文件名写进 photo 字段落库，
/// 响应追加 photo / pic（http://c1.kgimg.com/v2/kugouicon/<FileName>）。
pub fn handle_update_avatar(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    use super::comment_send::bad_request;

    const IMG_ERR: &str =
        "图片数据无效（imgFile 需为 base64 / dataURL，且为 JPEG/PNG/GIF/BMP/WEBP 格式）";

    let img = update_body_or_param(q, "imgFile")
        .or_else(|| update_body_or_param(q, "img"))
        .or_else(|| update_body_or_param(q, "file"));
    let Some(Value::String(raw)) = img else {
        return Err(bad_request(IMG_ERR));
    };
    if raw.is_empty() {
        return Err(bad_request(IMG_ERR));
    }

    // 剥 dataURL 前缀与空白后严格校验
    let base64_str = match raw.find(',') {
        Some(idx) if raw.starts_with("data:") => raw[idx + 1..].to_string(),
        _ => raw.clone(),
    };
    let base64_str: String = base64_str.chars().filter(|c| !c.is_whitespace()).collect();
    if !is_strict_base64(&base64_str) {
        return Err(bad_request(IMG_ERR));
    }
    // base64_decode 对非法输入返回空 Vec（严格校验已挡住，双保险）
    let image = base64_decode(&base64_str);
    if image.is_empty() {
        return Err(bad_request(IMG_ERR));
    }
    let Some(mime) = image_mime(&image) else {
        return Err(bad_request(IMG_ERR));
    };

    let filename = match update_body_or_param(q, "filename") {
        Some(Value::String(s)) if !s.is_empty() => s.replace('"', "_"),
        Some(v) => v.to_string().replace('"', "_"),
        _ => "avatar.jpg".to_string(),
    };

    // 第 1 步：multipart 上传图床
    let boundary = "----MD3MusicAvatarBoundary9f2c8a7e5b3d";
    let upload_token = crypto_md5_str(&format!("{}{}", beijing_ymd(), UPLOAD_SALT));
    let mut body: Vec<u8> = Vec::with_capacity(image.len() + 512);
    body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
    body.extend_from_slice(b"Content-Disposition: form-data; name=\"type\"\r\n\r\nkugouicon\r\n");
    body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
    body.extend_from_slice(b"Content-Disposition: form-data; name=\"md5\"\r\n\r\n");
    body.extend_from_slice(upload_token.as_bytes());
    body.extend_from_slice(b"\r\n");
    body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
    body.extend_from_slice(
        format!("Content-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n")
            .as_bytes(),
    );
    body.extend_from_slice(format!("Content-Type: {mime}\r\n\r\n").as_bytes());
    body.extend_from_slice(&image);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

    let mut headers = HashMap::new();
    headers.insert(
        "Content-Type".to_string(),
        format!("multipart/form-data; boundary={boundary}"),
    );
    let up = raw_request(
        "POST",
        "http://imgphp.kugou.com/imageupload/post.php",
        &json!({}),
        BodyData::Bytes(body),
        &headers,
    )?;
    let up_body = up.body.to_json();
    let file_name = up_body
        .get("FileName")
        .and_then(|v| v.as_array())
        .and_then(|a| a.first())
        .map(|v| match v {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        })
        .unwrap_or_default();
    let is_success = match up_body.get("IsSuccess") {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) != 0,
        Some(Value::String(s)) => s == "true" || s == "1",
        _ => false,
    };
    if !is_success || file_name.is_empty() {
        let msg = up_body
            .get("Message")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .map(|v| match v {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            })
            .unwrap_or_else(|| "图床上传失败".to_string());
        return Err(ModuleResponse {
            status: 502,
            body: BodyValue::Json(json!({ "status": 0, "msg": msg })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }

    // 第 2 步：把图床文件名写进 photo 字段落库
    let mut result = user_update_core(q, ctx, Some(&file_name))?;
    if let BodyValue::Json(ref mut v) = result.body {
        if let Some(obj) = v.as_object_mut() {
            obj.insert("photo".to_string(), json!(file_name));
            obj.insert(
                "pic".to_string(),
                json!(format!("http://c1.kgimg.com/v2/kugouicon/{file_name}")),
            );
        }
    }
    Ok(result)
}

/// user_follow.js → /user/follow（获取用户关注的歌手）。
pub fn handle_follow(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_str(q, "userid", "0");
    let clienttime = now_secs();
    let dm = json!({
        "merge": 2,
        "need_iden_type": 1,
        "ext_params": "k_pic,jumptype,singerid,score",
        "userid": userid,
        "type": 0,
        "id_type": 0,
        "p": rsa_pk_upper(&json!({ "clienttime": clienttime, "token": token })),
    });
    forward(
        q, ctx, "POST", "/v4/follow_list", None,
        Some(json!({ "plat": 1 })), Some(dm), "android", &[("x-router", "relationuser.kugou.com")], false, false,
    )
}

/// user_follow_message.js → /user/follow/message（关注歌手的消息）。
pub fn handle_follow_message(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0");
    let id = q_str(q, "id", "");
    let pm = json!({
        "filter": 1,
        "maxid": 0,
        "pagesize": q_num(q, "pagesize", 30),
        "tag": format!("chat:{}_{}", userid, id),
    });
    forward(
        q, ctx, "GET", "/msg.mobile/v3/msgtag/history", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// user_history.js → /user/history（用户听歌排行）。
pub fn handle_history(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // ⚠️ 必须显式标注 `i64`（与 playlist.rs 各处一致）。
    //
    // 原写法 `.parse().unwrap_or(0)` 把类型交给 `json!` 反推，实际编译成
    // `parse::<i32>()`；而酷狗 userid 是**十位数**（如 2489811067），
    // 超过 i32::MAX(2147483647) ⇒ 解析失败 ⇒ `unwrap_or(0)` 静默置 0。
    // 上游收到 userid=0 自然回 20017（登录已过期），表现为
    // 「登录态正常、其他接口能用，唯独播放历史加载失败」。
    //
    // 凭据本身没问题：同 token 的 /user/grade/info 走`let userid: i64` 正常返回，
    // 官方 App 也能读到该账号的历史。playlist.rs 早已修过同类问题
    // （userid 常量 OVERFLOW_LIMIT_T32），此处是遗漏的同一类。
    let userid_str = param_or_cookie_str(q, "userid", "0");
    let userid: i64 = userid_str.trim().parse().unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    let mut dm: Map<String, Value> = Map::new();
    dm.insert("token".to_string(), json!(token));
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("source_classify".to_string(), json!("app"));
    dm.insert("to_subdivide_sr".to_string(), json!(1));
    if let Some(v) = q.get("bp") {
        if !v.is_null() {
            dm.insert("bp".to_string(), v.clone());
        }
    }
    forward(
        q, ctx, "POST", "/playhistory/v1/get_songs", None, None,
        Some(Value::Object(dm)), "android", &[], false, false,
    )
}

/// user_listen.js → /user/listen（用户听歌列表）。
pub fn handle_listen(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_str(q, "userid", "0");
    let clienttime = now_secs();
    let p = rsa_pk_upper(&json!({ "clienttime": clienttime, "token": token }));
    let dm = json!({
        "t_userid": userid,
        "userid": userid,
        "list_type": q_num(q, "type", 0),
        "area_code": 1,
        "cover": 2,
        "p": p,
    });
    forward(
        q, ctx, "POST", "/v2/get_list", Some("https://listenservice.kugou.com"),
        Some(json!({ "clienttime": clienttime, "plat": 0 })), Some(dm), "android", &[], false, false,
    )
}

/// user_playlist.js → /user/playlist（获取用户歌单）。
pub fn handle_playlist(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = cookie_or_param_str(q, "userid", "0");
    let token = cookie_or_param_str(q, "token", "");
    let dm = json!({
        "userid": userid,
        "token": token,
        "total_ver": 979,
        "type": q_num(q, "type", 2),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "post", "/v7/get_all_list", None,
        Some(json!({ "plat": 1, "userid": userid.trim().parse::<i64>().unwrap_or(0), "token": token })),
        Some(dm), "android", &[("x-router", "cloudlist.service.kugou.com")], false, false,
    )
}

/// user_video_collect.js → /user/video/collect（收藏的视频）。
pub fn handle_video_collect(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0");
    let token = param_or_cookie_str(q, "token", "");
    let dm = json!({
        "userid": userid,
        "token": token,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "POST", "/collectservice/v2/collect_list_mixvideo", None,
        Some(json!({ "plat": 1 })), Some(dm), "android", &[], false, false,
    )
}

/// user_video_love.js → /user/video/love（点赞的视频）。
pub fn handle_video_love(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0");
    let pm = json!({
        "kugouid": userid,
        "pagesize": q_num(q, "pagesize", 30),
        "load_video_info": 1,
        "p": 1,
        "plat": 1,
    });
    forward(
        q, ctx, "get", "/m.comment.service/v1/get_user_like_video", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// user_vip_detail.js → /user/vip/detail（联合 VIP 信息）。
pub fn handle_vip_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/v1/get_union_vip", Some("https://kugouvip.kugou.com"),
        Some(json!({ "busi_type": "concept" })), None, "android", &[], false, false,
    )
}

/// user_grade_info.js → /user/grade/info（听歌等级信息查询与听歌时长上报，v2/lite 协议）。
///
/// 本工程为概念版（lite）平台（appid=3116, clientver=11440, lite key），
/// 只走 v2 协议（userinfo.user.kugou.com/v2/get_grade_info），上报按 diff_sec 累加记账。
/// - 查询模式（默认）：返回服务器当前累计听歌时长/等级/积分
/// - 上报模式（同时传 d_sec + diff_sec）：同步本地累计时长
///
/// 对齐 JS buildV2：dataMap 经 JSON.stringify 作为 text/plain body，p 为
/// RSA raw 加密（查询 {clienttime,userid} / 上报 {token,md5}），key 为
/// MD5(appid + liteKey + clientver + clienttime)。
pub fn handle_grade_info(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = param_or_cookie_str(q, "token", "");
    // JS `Number(params?.userid || params?.cookie?.userid || 0)`：body 中为数字
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse::<i64>()
        .unwrap_or(0);
    let mid = c_str(q, "KUGOU_API_MID");
    let dfid = param_or_cookie_str(q, "dfid", "-");
    let uuid = param_or_cookie_str(q, "uuid", "-");
    let type_ = q_num(q, "type", 1);
    let clienttime = now_secs();

    // 上报模式：d_sec 与 diff_sec 同时存在（JS `params?.d_sec != null && params?.diff_sec != null`）
    let is_report = q.get("d_sec").is_some() && q.get("diff_sec").is_some();

    // p：查询 RSA({clienttime,userid})；上报 RSA({token,md5})
    let p = if is_report {
        let d_sec = q_num(q, "d_sec", 0);
        let diff_sec = q_num(q, "diff_sec", 0);
        let y_type = q_num(q, "y_type", 0);
        let m_type = q_num(q, "m_type", 0);
        // md5 = MD5(d_sec + diff_sec + y_type + m_type)
        let md5 = crypto_md5_str(&format!("{}{}{}{}", d_sec, diff_sec, y_type, m_type));
        crypto_rsa_encrypt(&json_stringify(&json!({ "token": token, "md5": md5 })), None)
            .to_uppercase()
    } else {
        crypto_rsa_encrypt(
            &json_stringify(&json!({ "clienttime": clienttime, "userid": userid })),
            None,
        )
        .to_uppercase()
    };

    // 请求校验 key：MD5(appid + appkey + clientver + clienttime)
    let key = sign_params_key(&clienttime.to_string(), APP_ID, CLIENT_VER);

    // dataMap：按 JS 插入顺序（serde_json preserve_order），appid/clientver 为字符串，
    // clienttime/userid/type 与上报数值为数字。
    let mut dm: Map<String, Value> = Map::new();
    dm.insert("mid".to_string(), json!(mid));
    dm.insert("type".to_string(), json!(type_));
    dm.insert("uuid".to_string(), json!(uuid));
    dm.insert("userid".to_string(), json!(userid));
    if is_report {
        dm.insert("d_sec".to_string(), json!(q_num(q, "d_sec", 0)));
        dm.insert("diff_sec".to_string(), json!(q_num(q, "diff_sec", 0)));
        dm.insert("y_type".to_string(), json!(q_num(q, "y_type", 0)));
        dm.insert("m_type".to_string(), json!(q_num(q, "m_type", 0)));
    }
    dm.insert("p".to_string(), json!(p));
    dm.insert("appid".to_string(), json!(APP_ID));
    dm.insert("clientver".to_string(), json!(CLIENT_VER));
    dm.insert("clienttime".to_string(), json!(clienttime));
    dm.insert("key".to_string(), json!(key));

    // 模拟客户端随机 KG-THash（固定 7 位 hex，与 handle_cloud_upload 一致）
    let thash = format!("{:07x}", (now_epoch_secs() as u64) & 0x0FFF_FFFF);

    // 先序列化 body（dm 随后被 move 进 body，日志复用该字符串）
    let body_str = json_stringify(&Value::Object(dm));

    let opts = RequestOptions::new("/v2/get_grade_info")
        .base_url("http://userinfo.user.kugou.com")
        .post("/v2/get_grade_info")
        .params(json!({ "dfid": dfid }))
        .string_body(body_str.clone())
        .cookie(q_cookie(q))
        .header("Content-Type", "text/plain; charset=ISO-8859-1")
        .header("User-Agent", "Android15-1070-11440-201-0-get_user_grade_info-wifi")
        .header("KG-THash", &thash)
        .header("KG-Rec", "1")
        .header("KG-RC", "1")
        .clear_default_params(true)
        .not_signature(true)
        // 上游 get_grade_info 偶发无响应/极慢：单独收紧为 8s，先于客户端 dio 15s 超时
        // 放弃，避免「客户端已超时、本地服务器继续空转到 20s」的空耗，以及连续失败
        // 每次再触发最长 20s 查询重同步的叠加卡顿。
        .timeout_secs(8);

    // 调试日志：确认上报/查询请求与上游返回（听歌时长不生效排查用）
    eprintln!(
        "[GRADE-DEBUG] is_report={} userid={} mid={} dfid={} body={}",
        is_report, userid, mid, dfid, body_str,
    );
    let res = ctx.send(&opts)?;
    eprintln!(
        "[GRADE-DEBUG] status={} body={}",
        res.status,
        json_stringify(&res.body.to_json()),
    );
    Ok(res)
}

/// user_purchased_songs.js → /user/purchased/songs（已购单曲列表）。
pub fn handle_purchased_songs(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = cookie_or_param_num(q, "userid", 0);
    let token = cookie_or_param_str(q, "token", "");
    // 上游 Go 结构体 GetGoodsParam.appid 是 int，而 config::APP_ID 是字符串；
    // 直接发 "3116" 上游即 502 `json: cannot unmarshal string into Go struct field
    // GetGoodsParam.appid of type int`（真机实测）。身份必须留在概念版：
    // 换成标准版 1005 上游回 error_code=20018（登录已过期），概念版 token 不认标准版 appid。
    let dm = json!({
        "appid": appid_num(),
        "userid": userid,
        "token": token,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 50),
        "clientver": CLIENT_VER.to_string(),
        "deleted": 0,
        "need_audio_info": 1,
        "area_code": "1",
    });
    forward(
        q, ctx, "POST", "/openapi/copyright/v1/audio/get_goods", None,
        None, Some(dm), "android", &[], false, false,
    )
}

/// user_purchased_albums.js → /user/purchased/albums（已购专辑列表）。
pub fn handle_purchased_albums(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = cookie_or_param_num(q, "userid", 0);
    let token = cookie_or_param_str(q, "token", "");
    // 同 handle_purchased_songs：appid 必须是数字，身份保持概念版。
    let dm = json!({
        "appid": appid_num(),
        "userid": userid,
        "token": token,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 15),
        "clientver": CLIENT_VER.to_string(),
        "deleted": 0,
    });
    forward(
        q, ctx, "POST", "/openapi/v1/copyright/get_album_goods", None,
        None, Some(dm), "android", &[], false, false,
    )
}

/// `config::APP_ID` 是字符串，但部分上游 Go 接口的 appid 字段是 int。
fn appid_num() -> i64 {
    APP_ID.parse::<i64>().unwrap_or(3116)
}

#[cfg(test)]
mod cloud_upload_tests {
    use super::{normalize_match_candidate, ChannelReader};
    use serde_json::json;
    use std::io::Read;
    use std::sync::mpsc;

    #[test]
    fn channel_reader_joins_chunks_until_sender_drop() {
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        tx.send(b"line1\n".to_vec()).unwrap();
        let mut line = br#"{"type":"result"}"#.to_vec();
        line.extend_from_slice(b"\n");
        tx.send(line).unwrap();
        drop(tx);

        let mut reader = ChannelReader::new(rx);
        let mut all = Vec::new();
        reader.read_to_end(&mut all).unwrap();
        assert_eq!(all, b"line1\n{\"type\":\"result\"}\n");
    }

    #[test]
    fn channel_reader_reads_partial_then_rest_then_eof() {
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        tx.send(b"abcdef\n".to_vec()).unwrap();
        drop(tx);

        let mut reader = ChannelReader::new(rx);
        let mut head = [0u8; 3];
        assert_eq!(reader.read(&mut head).unwrap(), 3);
        assert_eq!(&head, b"abc");

        let mut rest = Vec::new();
        reader.read_to_end(&mut rest).unwrap();
        assert_eq!(rest, b"def\n");

        let mut eof = Vec::new();
        assert_eq!(reader.read_to_end(&mut eof).unwrap(), 0);
    }

    #[test]
    fn normalize_match_candidate_takes_first_of_array_and_picks_names() {
        let item = json!([{
            "album_audio_id": "12345",
            "hash": "aaa",
            "audio_info": {
                "audio_id": 678,
                "hash": "std_hash",
                "ori_audio_name": "官方歌名",
                "author_name": "官方歌手",
                "album_info": {"name": "官方专辑"},
            },
        }]);
        let m = normalize_match_candidate(&item).expect("should match");
        assert_eq!(m.get("album_audio_id").and_then(|v| v.as_i64()), Some(12345));
        assert_eq!(m.get("audio_id").and_then(|v| v.as_i64()), Some(678));
        assert_eq!(m.get("hash").and_then(|v| v.as_str()), Some("std_hash"));
        assert_eq!(m.get("audio_name").and_then(|v| v.as_str()), Some("官方歌名"));
        assert_eq!(m.get("author_name").and_then(|v| v.as_str()), Some("官方歌手"));
    }

    #[test]
    fn normalize_match_candidate_falls_back_to_audio_name_then_misses() {
        let fallback = json!({
            "audio_id": 0,
            "album_audio_id": 0,
            "hash": "x",
            "audio_info": {"audio_name": "次选名", "songname": "再次选"},
        });
        let m = normalize_match_candidate(&fallback).expect("hash present so matched");
        assert_eq!(m.get("audio_name").and_then(|v| v.as_str()), Some("次选名"));

        let miss = json!({"album_audio_id": 0, "audio_id": 0, "hash": ""});
        assert!(normalize_match_candidate(&miss).is_none());
    }
}
