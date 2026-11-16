use crate::crypto::{aes_cbc_encrypt, base64_encode, md5_hex_str, rsa_oaep_sha256_encrypt};
use crate::util::random_string;

/// RSA-OAEP SHA-256 public key extracted from the Kugou WASM binary
/// (util/generate_simulate.js `publicKey`).
const PUBLIC_KEY: &str = "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoW2+Ylo8ALePSQTP0xBF\nlFmEOHvBD9tS+s7DBlfKEu3RzzvZTaX1JtYbX4+AVUqj6ARz8IM+CKByqGFvbHN/\nW64XxNI+q7z36ajCL3VTJ2W5G9MCJitc6oGbire4NQfhaEq0nC+hxBWQvCbIFflA\n2ItrLUbSU7z1bHA/a+jlQm4OWvY+IKnTryOJTPuT1yNOVjbJ8wBLKy2DgQr9pPqW\nPmEQtGpR5IM9V8Kao6PaSdKYOWGbX3i2+RzIKhvZUxxtJwdVbqPlDPlW9h4/xIBc\n56Lgvr4aIl8nFtwbj4UJVUTFuGrs0tY9H/tXvZ22dUCKuGxW/gW7ZF+gXz6vHtYa\nrQIDAQAB\n-----END PUBLIC KEY-----";

const IV: &str = "kugousecurity123";

#[derive(Debug, Clone)]
pub struct Simulate {
    pub edt: String,
    pub sid: String,
}

fn ri(min: i64, max: i64) -> i64 {
    let r: f64 = rand::random();
    (r * (max - min + 1) as f64).floor() as i64 + min
}

fn f3(t: i64, i: i64, x: i64, y: i64) -> String {
    format!("3,{},{},{},{}", t, i, x, y)
}
fn f5(t: i64, i: i64) -> String {
    format!("5,{},{}", t, i)
}
fn f6(t: i64, i: i64, x: i64, y: i64) -> String {
    format!("6,{},{},{},{}", t, i, x, y)
}
fn fs3(sentinel: u64, i: i64, x: i64, y: i64) -> String {
    format!("3,{},{},{},{}", sentinel, i, x, y)
}
fn fs5(sentinel: u64, i: i64) -> String {
    format!("5,{},{}", sentinel, i)
}
fn fs6(sentinel: u64, i: i64, x: i64, y: i64) -> String {
    format!("6,{},{},{},{}", sentinel, i, x, y)
}

/// Cubic bezier mouse path (generate_simulate.js bezierPath).
fn bezier_path(sx: f64, sy: f64, ex: f64, ey: f64, n: i64) -> Vec<(f64, f64)> {
    let c1x = sx + (ex - sx) * 0.3 + ri(-80, 80) as f64;
    let c1y = sy + (ey - sy) * 0.2 + ri(-60, 60) as f64;
    let c2x = sx + (ex - sx) * 0.7 + ri(-60, 60) as f64;
    let c2y = sy + (ey - sy) * 0.8 + ri(-40, 40) as f64;
    let mut pts = Vec::new();
    for i in 0..=n {
        let t = i as f64 / n as f64;
        let u = 1.0 - t;
        let x = u * u * u * sx + 3.0 * u * u * t * c1x + 3.0 * u * t * t * c2x + t * t * t * ex;
        let y = u * u * u * sy + 3.0 * u * u * t * c1y + 3.0 * u * t * t * c2y + t * t * t * ey;
        let jitter = (3.0 - t * 2.5).max(0.5);
        let jr: f64 = rand::random();
        pts.push((x + (jr - 0.5) * jitter, y + (jr - 0.5) * jitter));
    }
    pts
}

fn generate_edt_data(start_x: i64, start_y: i64, end_x: i64, end_y: i64, mouse_points: i64, sentinel: u64) -> String {
    let mut entries: Vec<String> = Vec::new();
    let mut ts: i64 = 0;
    let mut ei: i64 = 0;

    entries.push(f5(0, 0));
    entries.push(fs5(sentinel, 0));
    entries.push(f5(0, 0));
    entries.push(fs5(sentinel, 0));

    ts += ri(5, 20);
    entries.push(f6(ts, ei, 750, 500));
    entries.push(fs6(sentinel, ei, 750, 500));
    ei += 1;

    for _ in 0..3 {
        ts += ri(80, 600);
        entries.push(f5(ts, ei));
        entries.push(fs5(sentinel, ei));
        ei += 1;
    }

    let path = bezier_path(start_x as f64, start_y as f64, end_x as f64, end_y as f64, mouse_points);
    let mut si: i64 = 0;
    for (i, (x, y)) in path.iter().enumerate() {
        ts += ri(8, 50);
        entries.push(f3(ts, si, x.round() as i64, y.round() as i64));
        entries.push(fs3(sentinel, si, x.round() as i64, y.round() as i64));
        if i > 0 && i % 12 == 0 {
            ts += ri(20, 60);
            entries.push(f5(ts, ei));
            entries.push(fs5(sentinel, ei));
            ei += 1;
        }
        si = (si + 1) % 2;
    }

    ts += ri(5, 30);
    entries.push(f3(ts, 1, end_x + ri(-5, 5), end_y + ri(-5, 5)));
    entries.push(fs3(sentinel, 1, end_x, end_y));

    entries.join(":")
}

fn generate_webgl_hash() -> String {
    const RENDERERS: [&str; 5] = [
        "ANGLE (Intel, Intel(R) UHD Graphics 620 Direct3D11 vs_5_0 ps_5_0, D3D11)",
        "ANGLE (NVIDIA, NVIDIA GeForce GTX 1060 Direct3D11 vs_5_0 ps_5_0, D3D11)",
        "ANGLE (AMD, AMD Radeon RX 580 Direct3D11 vs_5_0 ps_5_0, D3D11)",
        "Mali-G52",
        "Adreno (TM) 650",
    ];
    let idx = (rand::random::<f64>() * RENDERERS.len() as f64).floor() as usize;
    let renderer = RENDERERS[idx.min(RENDERERS.len() - 1)];
    md5_hex_str(renderer)
}

/// generateSimulate(mid, userid, dfid, webglHash) -> { edt, sid }
pub fn generate_simulate(mid: &str, userid: &str, dfid: &str, webgl_hash: Option<&str>) -> Simulate {
    let sentinel = 0xffffffffu64 - (rand::random::<f64>() * 20.0).floor() as u64;

    let key = md5_hex_str(&random_string(16));
    let key = &key[..16];

    let points = ri(30, 60);
    let start_x = ri(200, 600);
    let start_y = ri(200, 500);
    let end_x = ri(500, 700);
    let end_y = ri(80, 150);

    let mid = if mid.is_empty() { "0" } else { mid };
    let userid = if userid.is_empty() { "0" } else { userid };
    let dfid = if dfid.is_empty() { "0" } else { dfid };
    let webgl = match webgl_hash {
        Some(w) if !w.is_empty() => w.to_string(),
        _ => generate_webgl_hash(),
    };

    let ts = crate::cache::now_epoch_secs() as i64 * 1000;
    let data = generate_edt_data(start_x, start_y, end_x, end_y, points, sentinel);

    let sid_plaintext = format!(
        "mid={};userid={};dfid={};webgl={};webdriver=0;ts={};data={}",
        mid, userid, dfid, webgl, ts, data
    );

    let ct = aes_cbc_encrypt(key.as_bytes(), IV.as_bytes(), sid_plaintext.as_bytes());
    let edt = base64_encode(&ct);

    let enc = rsa_oaep_sha256_encrypt(PUBLIC_KEY, key.as_bytes());
    let sid = base64_encode(&enc);

    Simulate { edt, sid }
}
