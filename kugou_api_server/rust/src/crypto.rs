use md5::{Digest, Md5};
use num_traits::Zero;
use rsa::pkcs8::DecodePublicKey;
use rsa::traits::{PublicKeyParts, RandomizedEncryptor};
use rsa::BigUint;
use rsa::Oaep;
use rsa::RsaPublicKey;
use sha1::Sha1;
use sha2::Sha256;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

pub fn md5_hex(data: &[u8]) -> String {
    let mut hasher = Md5::new();
    hasher.update(data);
    let out = hasher.finalize();
    out.iter().map(|b| format!("{:02x}", b)).collect()
}

pub fn md5_hex_str(s: &str) -> String {
    md5_hex(s.as_bytes())
}

pub fn sha1_hex_str(s: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(s.as_bytes());
    let out = hasher.finalize();
    out.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Incremental md5 equivalent of CryptoJS.algo.MD5.create() with three updates.
pub fn md5_hex_3(part1: &[u8], part2: &[u8], part3: &[u8]) -> String {
    let mut hasher = Md5::new();
    hasher.update(part1);
    hasher.update(part2);
    hasher.update(part3);
    let out = hasher.finalize();
    out.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Incremental md5 with four updates (signatureAndroids buffer branch).
pub fn md5_hex_4(part1: &[u8], part2: &[u8], part3: &[u8], part4: &[u8]) -> String {
    let mut hasher = Md5::new();
    hasher.update(part1);
    hasher.update(part2);
    hasher.update(part3);
    hasher.update(part4);
    let out = hasher.finalize();
    out.iter().map(|b| format!("{:02x}", b)).collect()
}

pub fn hex_encode(data: &[u8]) -> String {
    data.iter().map(|b| format!("{:02x}", b)).collect()
}

pub fn hex_to_bytes_lower(s: &str) -> Vec<u8> {
    hex_to_bytes(&s.to_lowercase())
}

/// AES-CBC encrypt with PKCS7 padding (CryptoJS default), select algorithm by key length.
///
/// Implemented manually on top of `BlockEncrypt`/`BlockDecrypt` because the
/// `cbc` crate's `Encryptor`/`Decryptor` produce WRONG ciphertext for AES-192
/// and AES-256 key sizes in the pinned `cipher`/`aes` versions (verified against
/// NIST SP 800-38A vectors and CryptoJS/Python; only AES-128 matched). The raw
/// block cipher is correct for all key sizes, so we chain CBC ourselves.
pub fn aes_cbc_encrypt(key: &[u8], iv: &[u8], plain: &[u8]) -> Vec<u8> {
    use aes::cipher::{generic_array::GenericArray, BlockEncrypt, BlockSizeUser, KeyInit};
    use aes::cipher::typenum::Unsigned;
    macro_rules! run {
        ($ty:ty) => {{
            let bs = <$ty as BlockSizeUser>::BlockSize::USIZE;
            let padded_len = ((plain.len() / bs) + 1) * bs;
            let mut data = vec![0u8; padded_len];
            data[..plain.len()].copy_from_slice(plain);
            let pad = (bs - (plain.len() % bs)) as u8;
            for b in data[plain.len()..].iter_mut() {
                *b = pad;
            }
            let cipher = <$ty>::new_from_slice(key).expect("aes key");
            let mut prev: Vec<u8> = iv.to_vec();
            let mut out = Vec::with_capacity(padded_len);
            for blk in data.chunks(bs) {
                let x: Vec<u8> = blk.iter().zip(prev.iter()).map(|(a, b)| a ^ b).collect();
                let in_ga = GenericArray::clone_from_slice(&x);
                let mut out_ga = GenericArray::clone_from_slice(&vec![0u8; bs]);
                cipher.encrypt_block_b2b(&in_ga, &mut out_ga);
                out.extend_from_slice(&out_ga);
                prev = out_ga.to_vec();
            }
            out
        }};
    }
    match key.len() {
        16 => run!(aes::Aes128),
        24 => run!(aes::Aes192),
        32 => run!(aes::Aes256),
        _ => panic!("invalid aes key length"),
    }
}

/// AES-CBC decrypt with PKCS7 unpadding (CryptoJS default).
pub fn aes_cbc_decrypt(key: &[u8], iv: &[u8], data: &[u8]) -> Vec<u8> {
    use aes::cipher::{generic_array::GenericArray, BlockDecrypt, BlockSizeUser, KeyInit};
    use aes::cipher::typenum::Unsigned;
    macro_rules! run {
        ($ty:ty) => {{
            let bs = <$ty as BlockSizeUser>::BlockSize::USIZE;
            let cipher = <$ty>::new_from_slice(key).expect("aes key");
            let mut prev: Vec<u8> = iv.to_vec();
            let mut out = Vec::with_capacity(data.len());
            for blk in data.chunks(bs) {
                let in_ga = GenericArray::clone_from_slice(blk);
                let mut dec_ga = GenericArray::clone_from_slice(&vec![0u8; bs]);
                cipher.decrypt_block_b2b(&in_ga, &mut dec_ga);
                let plain_block: Vec<u8> = dec_ga.iter().zip(prev.iter()).map(|(a, b)| a ^ b).collect();
                out.extend_from_slice(&plain_block);
                prev = blk.to_vec();
            }
            let last = *out.last().unwrap_or(&0) as usize;
            if (1..=bs).contains(&last) && out.len() >= last {
                let pad_start = out.len() - last;
                if out[pad_start..].iter().all(|b| *b as usize == last) {
                    out.truncate(pad_start);
                }
            }
            out
        }};
    }
    match key.len() {
        16 => run!(aes::Aes128),
        24 => run!(aes::Aes192),
        32 => run!(aes::Aes256),
        _ => panic!("invalid aes key length"),
    }
}

/// P0: RSA 公钥解析结果缓存（pem 字符串 → RsaPublicKey）。
/// 原实现每次加密都重新 normalize_pem（字符串分配）+ from_public_key_pem（PEM 解析），
/// 公钥是编译期常量，首次解析后即可复用，登录/注册 RSA 热路径大幅减负。
fn cached_rsa_key(pem: &str) -> Arc<RsaPublicKey> {
    static CACHE: OnceLock<Mutex<HashMap<String, Arc<RsaPublicKey>>>> = OnceLock::new();
    let mut map = CACHE
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap();
    map.entry(pem.to_string())
        .or_insert_with(|| {
            Arc::new(RsaPublicKey::from_public_key_pem(&normalize_pem(pem)).expect("pem"))
        })
        .clone()
}

/// Raw RSA (no padding), like CryptoJS's plain modPow.
/// Replicates JS `cryptoRSAEncrypt`: input shorter than the modulus is
/// zero-padded to the RIGHT (Uint8Array of keyLength, data copied at offset 0),
/// then treated as a big-endian integer. Output is left-padded to modulus length.
pub fn rsa_raw_encrypt(pem: &str, data: &[u8]) -> Vec<u8> {
    let key = cached_rsa_key(pem);
    let n = key.n();
    let e = key.e();
    let mod_len = n.to_bytes_be().len();
    let mut padded_input = Vec::with_capacity(mod_len.max(data.len()));
    padded_input.extend_from_slice(data);
    while padded_input.len() < mod_len {
        padded_input.push(0);
    }
    let m = BigUint::from_bytes_be(&padded_input);
    let c = m.modpow(e, n);
    let bytes = c.to_bytes_be();
    // pad to modulus length
    let mut padded = vec![0u8; mod_len - bytes.len()];
    padded.extend_from_slice(&bytes);
    padded
}

/// RSA PKCS#1 v1.5 encrypt.
pub fn rsa_pkcs1v15_encrypt(pem: &str, data: &[u8]) -> Vec<u8> {
    use rsa::pkcs1v15::EncryptingKey;
    let key = cached_rsa_key(pem);
    let ep = EncryptingKey::new((*key).clone());
    let mut rng = rand::thread_rng();
    ep.encrypt_with_rng(&mut rng, data).expect("pkcs1v15")
}

/// RSA OAEP SHA256 encrypt.
pub fn rsa_oaep_sha256_encrypt(pem: &str, data: &[u8]) -> Vec<u8> {
    let key = cached_rsa_key(pem);
    let mut rng = rand::thread_rng();
    key.encrypt(&mut rng, Oaep::new::<Sha256>(), data)
        .expect("oaep sha256")
}

/// pem-rfc7468 要求 base64 每行不超过 64 字符；本项目常量是单行长串。
/// 重新按 64 字符折行，保证 `from_public_key_pem` 可解析。
fn normalize_pem(pem: &str) -> String {
    let mut label: Option<String> = None;
    let mut body = String::new();
    for line in pem.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if let Some(inner) = t.strip_prefix("-----BEGIN ") {
            label = Some(inner.trim_end_matches('-').trim().to_string());
            continue;
        }
        if t.starts_with("-----END ") {
            break;
        }
        body.push_str(&t.chars().filter(|c| !c.is_whitespace()).collect::<String>());
    }
    let label = label.unwrap_or_else(|| "PUBLIC KEY".to_string());
    let mut out = format!("-----BEGIN {}-----\n", label);
    let b64: Vec<char> = body.chars().collect();
    for (i, c) in b64.iter().enumerate() {
        out.push(*c);
        if (i + 1) % 64 == 0 && i + 1 < b64.len() {
            out.push('\n');
        }
    }
    if !b64.is_empty() {
        out.push('\n');
    }
    out.push_str(&format!("-----END {}-----", label));
    out
}

pub fn base64_encode(data: &[u8]) -> String {
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;
    STANDARD.encode(data)
}

pub fn base64_decode(s: &str) -> Vec<u8> {
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;
    STANDARD.decode(s.trim()).unwrap_or_default()
}

pub fn url_safe_base64_encode(data: &[u8]) -> String {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine;
    URL_SAFE_NO_PAD.encode(data)
}

pub fn hex_to_bytes(s: &str) -> Vec<u8> {
    let s = s.trim();
    let mut out = Vec::with_capacity(s.len() / 2);
    let bytes = s.as_bytes();
    let mut i = 0;
    while i + 1 < bytes.len() {
        let hi = (bytes[i] as char).to_digit(16).unwrap_or(0) as u8;
        let lo = (bytes[i + 1] as char).to_digit(16).unwrap_or(0) as u8;
        out.push((hi << 4) | lo);
        i += 2;
    }
    out
}

/// md5 hex interpreted as a big decimal number (calculateMid).
pub fn md5_hex_to_decimal_str(data: &[u8]) -> String {
    let hex = md5_hex(data);
    let n = BigUint::parse_bytes(hex.as_bytes(), 16).unwrap_or_else(Zero::zero);
    n.to_str_radix(10)
}

/// base64 url-safe decode with padding fixes, used for accesskey params.
pub fn base64_url_decode(s: &str) -> Vec<u8> {
    let mut t = s.replace('-', "+").replace('_', "/");
    while t.len() % 4 != 0 {
        t.push('=');
    }
    base64_decode(&t)
}

pub fn base64_url_encode(data: &[u8]) -> String {
    url_safe_base64_encode(data)
}

pub const PUBLIC_RAS_KEY: &str = "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/gbjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+UR4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE5E221wf/4WLFxwAtRQIDAQAB\n-----END PUBLIC KEY-----";

pub const PUBLIC_LITE_RAS_KEY: &str = "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB\n-----END PUBLIC KEY-----";

/// cryptoMd5(data): md5 hex of utf8 string (object input pre-stringified by caller).
pub fn crypto_md5_str(s: &str) -> String {
    md5_hex(s.as_bytes())
}

/// cryptoAesEncrypt(data, opt). Returns (hex, Option<tempKey>).
/// tempKey is Some when no opt.key was provided (JS returns {str, key}).
pub fn crypto_aes_encrypt(data: &str, opt_key: Option<&str>, opt_iv: Option<&str>) -> (String, Option<String>) {
    let buffer = data.as_bytes();
    let (key, iv, temp_key) = match (opt_key, opt_iv) {
        (Some(k), Some(i)) => (k.to_string(), i.to_string(), None),
        _ => {
            let tk = opt_key.map(|s| s.to_string()).unwrap_or_else(crate::util::random_string_lower_16);
            let md = md5_hex(tk.as_bytes());
            let key = md[..32].to_string();
            let iv = key[key.len() - 16..].to_string();
            (key, iv, Some(tk))
        }
    };
    let ct = aes_cbc_encrypt(key.as_bytes(), iv.as_bytes(), buffer);
    let hex = hex_encode(&ct);
    if opt_key.is_some() {
        (hex, None)
    } else {
        (hex, temp_key)
    }
}

/// cryptoAesDecrypt(data_hex, key, iv). key/iv are used as utf8 bytes.
/// Returns parsed JSON if possible, else the plaintext string.
pub fn crypto_aes_decrypt(data_hex: &str, key: &str, iv: Option<&str>) -> serde_json::Value {
    let real_key = if iv.is_none() {
        md5_hex(key.as_bytes())[..32].to_string()
    } else {
        key.to_string()
    };
    let real_iv = match iv {
        Some(i) => i.to_string(),
        None => real_key[real_key.len() - 16..].to_string(),
    };
    let ct = hex_to_bytes(data_hex);
    let pt = aes_cbc_decrypt(real_key.as_bytes(), real_iv.as_bytes(), &ct);
    let text = String::from_utf8_lossy(&pt).into_owned();
    serde_json::from_str(&text).unwrap_or(serde_json::Value::String(text))
}

/// rsaRawEncrypt(padded, publicKey) => hex string padded to modulus byte length * 2.
fn rsa_raw_encrypt_hex(pem: &str, data: &[u8]) -> String {
    hex_encode(&rsa_raw_encrypt(pem, data))
}

/// cryptoRSAEncrypt(data, publicKey) => hex. zero-pads to key length (JS semantics).
pub fn crypto_rsa_encrypt(data: &str, public_key: Option<&str>) -> String {
    let pem = public_key.unwrap_or(PUBLIC_LITE_RAS_KEY);
    rsa_raw_encrypt_hex(pem, data.as_bytes())
}

/// rsaEncrypt2(data) => PKCS#1 v1.5 encrypt with lite key, hex.
pub fn rsa_encrypt2(data: &str) -> String {
    hex_encode(&rsa_pkcs1v15_encrypt(PUBLIC_LITE_RAS_KEY, data.as_bytes()))
}

/// playlistAesEncrypt(data) => { key, str(base64) }. AES-128-CBC with md5-derived key/iv.
pub fn playlist_aes_encrypt(data: &str) -> (String, String) {
    let key = crate::util::random_string_lower(6);
    let md = md5_hex(key.as_bytes());
    let enc_key = md[..16].to_string();
    let iv = md[16..32].to_string();
    let ct = aes_cbc_encrypt(enc_key.as_bytes(), iv.as_bytes(), data.as_bytes());
    (key, base64_encode(&ct))
}

/// playlistAesDecrypt({key, str}) => parsed JSON or plaintext string.
pub fn playlist_aes_decrypt(key: &str, str_: &str) -> serde_json::Value {
    let md = md5_hex(key.as_bytes());
    let enc_key = md[..16].to_string();
    let iv = md[16..32].to_string();
    let ct = base64_decode(str_);
    let pt = aes_cbc_decrypt(enc_key.as_bytes(), iv.as_bytes(), &ct);
    let text = String::from_utf8_lossy(&pt).into_owned();
    serde_json::from_str(&text).unwrap_or(serde_json::Value::String(text))
}
