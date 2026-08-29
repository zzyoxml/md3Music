//! user 系列：cloud / cloud_url / detail / follow / follow_message /
//! grade_info / history / listen / playlist / video_collect / video_love / vip_detail
//! 对应 JS module/user*.js

use crate::cache::now_epoch_secs;
use crate::config::{APP_ID, CLIENT_VER};
use crate::crypto::{
    base64_decode, crypto_md5_str, crypto_rsa_encrypt, md5_hex, playlist_aes_decrypt,
    playlist_aes_encrypt, rsa_encrypt2,
};
use crate::helper::{sign_cloud_key, sign_params_key};
use crate::modules::{
    c_str, cookie_or_param_num, cookie_or_param_str, forward, param_or_cookie_str, q_cookie,
    q_num, q_raw_or, q_str, Ctx,
};
use crate::request::{raw_request, BodyData, BodyValue, ModuleResponse, RequestOptions};
use crate::util::json_stringify;
use serde_json::{json, Map, Value};
use std::collections::HashMap;

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
    eprintln!(
        "[CLOUD-DEBUG] status={} params={} p_len={} dec={}",
        res.status,
        json_stringify(&Value::Object(pm)),
        p.len(),
        json_stringify(&dec)
    );
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
pub fn handle_cloud_upload(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // userid 必须为字符串（步骤 5 RSA 加密时服务端校验 uid 类型）
    let userid = param_or_cookie_str(q, "userid", "");
    let token = param_or_cookie_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");
    let version = CLIENT_VER.to_string();
    let bucket = "musicclound".to_string();

    // 文件二进制数据（octet-stream body）
    let file_data = ctx.body_bytes.clone().unwrap_or_default();
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

    // 秒传分支：upload_id 为空且返回 x-bss-hash 说明文件已在服务器，跳过步骤3/4
    if !upload_id.is_empty() {
        // ========== 步骤3 上传分片（默认 4MB 一片） ==========
        let part_size: usize = 1024 * 1024 * 4;
        let part_count = (file_data.len() + part_size - 1) / part_size;
        let mut upload_headers = base_headers.clone();
        upload_headers.insert("Authorization".to_string(), authorization.clone());
        upload_headers.insert("Content-Type".to_string(), "application/octet-stream".to_string());
        for i in 0..part_count {
            let start = i * part_size;
            let end = ((i + 1) * part_size).min(file_data.len());
            let part = file_data[start..end].to_vec();
            let upload_res = raw_request(
                "POST",
                &format!("http://{}/multipart/upload", external_host),
                &json!({ "version": version, "userid": userid, "filename": filename, "appid": APP_ID, "upload_id": upload_id, "partnumber": i + 1, "bucket": bucket }),
                BodyData::Bytes(part),
                &upload_headers,
            ).map_err(|e| e)?;
            let ok = upload_res.body.to_json().get("status").and_then(|s| s.as_i64()) == Some(1);
            if !ok {
                return Err(ModuleResponse {
                    status: 502,
                    body: BodyValue::Json(json!({ "status": 0, "msg": format!("分片上传失败: part {}", i + 1) })),
                    cookie: Vec::new(),
                    headers: HashMap::new(),
                });
            }
        }

        // ========== 步骤4 完成上传 ==========
        let mut complete_headers = base_headers.clone();
        complete_headers.insert("Authorization".to_string(), authorization.clone());
        let complete_res = raw_request(
            "POST",
            &format!("http://{}/multipart/complete", external_host),
            &json!({ "filename": filename, "bucket": bucket, "if_id3": 1, "upload_id": upload_id, "userid": userid, "md5": filename, "version": version, "appid": APP_ID, "partnumber": part_count }),
            BodyData::None,
            &complete_headers,
        ).map_err(|e| e)?;
        let ok = complete_res.body.to_json().get("status").and_then(|s| s.as_i64()) == Some(1);
        if !ok {
            return Err(ModuleResponse {
                status: 502,
                body: BodyValue::Json(json!({ "status": 0, "msg": "完成上传失败" })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            });
        }
    }

    // ========== 步骤5 添加文件到云盘（AES 加密 body + RSA 加密密钥） ==========
    // 数字字段必须为 number 类型（字符串会导致上游 500）
    let clienttime = now_secs();
    let aes_encrypt = playlist_aes_encrypt(&json_stringify(&json!({
        "data": [
            {
                "name": name,
                "ext": extendname,
                "author_name": author_name,
                "hash": filename,
                "hash_std": filename,
                "audio_id": q_num(q, "audio_id", 0),
                "bitrate": q_num(q, "bitrate", 4),
                "album_audio_id": q_num(q, "album_audio_id", 0),
                "size": file_data.len() as i64,
                "timelen": q_num(q, "timelen", 0),
            }
        ],
        "list_ver": q_num(q, "list_ver", 0),
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
    pm.insert("key".to_string(), json!(sign_params_key(&clienttime.to_string(), APP_ID, "")));
    pm.insert("clientver".to_string(), json!(CLIENT_VER));
    pm.insert("appid".to_string(), json!(APP_ID));
    pm.insert("p".to_string(), json!(p));

    let opts = RequestOptions::new("/v1/add_files")
        .base_url("https://mcloudservice.kugou.com")
        .post("/v1/add_files")
        .params(Value::Object(pm.clone()))
        .bytes_body(base64_decode(&aes_encrypt.1))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .response_type("arraybuffer")
        .clear_default_params(true)
        .not_signature(true);
    let res = ctx.send(&opts)?;

    // 尝试解密响应；解密结果为非 JSON（乱码字符串）时回退明文 JSON，
    // 与 JS 版 try/decrypt → catch → JSON.parse 的兜底行为一致。
    let body = if res.status == 200 {
        let dec = playlist_aes_decrypt(&aes_encrypt.0, &res.body.to_base64());
        match dec {
            Value::String(_) => res.body.to_json(),
            other => other,
        }
    } else {
        res.body.to_json()
    };

    // 附带整个上传流程的关键信息，便于排查
    let mut body = body;
    if let Some(obj) = body.as_object_mut() {
        obj.insert(
            "uploadInfo".to_string(),
            json!({
                "hash": filename,
                "filesize": file_data.len(),
            }),
        );
    }

    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(body),
        cookie: res.cookie,
        headers: res.headers,
    })
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
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
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
        .not_signature(true);

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
    let dm = json!({
        "appid": APP_ID,
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
    let dm = json!({
        "appid": APP_ID,
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
