//! pcm.rs — /extras/pcm-process（本地 PCM 前处理）。
//!
//! 用途：把听歌识曲的 PCM 前处理（WAV 解析 → 降采样 → 静音检测 → 增益归一化）
//! 从 Dart 主 isolate 下放到 Rust，避免逐采样点循环占用 UI isolate
//! （原实现：lib/modules/recognition/recognition_utils.dart）。
//!
//! 输入（body，Content-Type: application/octet-stream）：
//!   - 完整 WAV（RIFF/WAVE 头，16bit PCM）→ 自动解析出采样率并提取 PCM
//!   - 纯 PCM（16bit 小端）→ 采样率取 query `fromHz`
//! query：`fromHz` / `toHz`（目标采样率，默认 8000）
//! 输出：二进制 = 处理后的 16bit 小端 PCM（8000Hz）；响应头 `X-Max-Amplitude`
//!       携带静音检测用最大振幅（与 Dart computeMaxAmplitude 语义一致）。
//! 不支持/解析失败返回 400，Dart 侧降级回原 Dart 实现。

use crate::modules::{q_num, Ctx};
use crate::request::{BodyValue, ModuleResponse};
use serde_json::Value;
use std::collections::HashMap;

/// 增益归一化目标振幅（与 Dart normalizeGain 默认 targetAmplitude=25000 一致）。
const TARGET_AMPLITUDE: i64 = 25000;

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let body = ctx.body_bytes.clone().unwrap_or_default();
    if body.is_empty() {
        return Err(error_400());
    }

    // 1. 解析输入：WAV → 16bit PCM + 采样率；否则视为纯 PCM16（无采样率）
    let (pcm, wav_rate) = parse_input(&body);

    // 2. 采样率：优先 WAV 头解析值，否则取 query fromHz（默认 8000）
    let from_hz = wav_rate.unwrap_or(q_num(q, "fromHz", 8000));
    let to_hz = q_num(q, "toHz", 8000);
    if pcm.is_empty() || from_hz <= 0 || to_hz <= 0 || to_hz > from_hz {
        return Err(error_400());
    }

    // 3. 降采样（均值抗混叠，与 Dart downsamplePcm 逐字节一致；同采样率跳过）
    let downsampled = downsample(&pcm, from_hz, to_hz);

    // 4. 静音检测：最大振幅（未去 DC，与 Dart computeMaxAmplitude 一致）
    let max_amplitude = compute_max_amplitude(&downsampled);

    // 5. 增益归一化（DC 去除 + 放大；gain<=1 原样返回，与 Dart normalizeGain 一致）
    let normalized = normalize_gain(&downsampled, TARGET_AMPLITUDE);

    // 6. 编码为 16bit 小端字节
    let mut out = Vec::with_capacity(normalized.len() * 2);
    for s in normalized {
        out.extend_from_slice(&s.to_le_bytes());
    }

    let mut headers = HashMap::new();
    headers.insert("X-Max-Amplitude".to_string(), max_amplitude.to_string());
    headers.insert(
        "Content-Type".to_string(),
        "application/octet-stream".to_string(),
    );
    Ok(ModuleResponse {
        status: 200,
        body: BodyValue::Bytes(out),
        cookie: vec![],
        headers,
    })
}

fn error_400() -> ModuleResponse {
    ModuleResponse {
        status: 400,
        body: BodyValue::Bytes(Vec::new()),
        cookie: vec![],
        headers: HashMap::new(),
    }
}

/// 解析输入为 16bit 小端采样序列。
/// 若为 RIFF/WAVE 头则按 WAV 解析（仅支持 PCM16，异常返回空）；否则视为纯 PCM16。
/// 返回 (采样序列, WAV 头解析出的采样率)。纯 PCM 返回 None 采样率（用 query 兜底）。
fn parse_input(data: &[u8]) -> (Vec<i16>, Option<i64>) {
    if data.len() >= 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WAVE" {
        match parse_wav(data) {
            Some((pcm, rate)) => (pcm, Some(rate)),
            // WAV 头存在但非 PCM16：不按纯 PCM 解析，返回空由上层 400（Dart 降级）
            None => (Vec::new(), None),
        }
    } else {
        // 纯 PCM16 小端（悬浮窗场景原生已 8000Hz 输出）
        let mut pcm = Vec::with_capacity(data.len() / 2);
        let mut i = 0;
        while i + 1 < data.len() {
            pcm.push(i16::from_le_bytes([data[i], data[i + 1]]));
            i += 2;
        }
        (pcm, None)
    }
}

/// 解析 WAV：遍历 chunk 找 fmt（校验 PCM16）与 data（提取首通道采样）。
fn parse_wav(data: &[u8]) -> Option<(Vec<i16>, i64)> {
    let mut off = 12usize;
    let mut sample_rate: i64 = 0;
    let mut channels: usize = 0;
    let mut pcm: Vec<i16> = Vec::new();
    while off + 8 <= data.len() {
        let size =
            u32::from_le_bytes([data[off + 4], data[off + 5], data[off + 6], data[off + 7]])
                as usize;
        let body_start = off + 8;
        let body_end = body_start.saturating_add(size).min(data.len());
        match &data[off..off + 4] {
            b"fmt " => {
                if body_end - body_start >= 16 {
                    let audio_format =
                        u16::from_le_bytes([data[body_start], data[body_start + 1]]);
                    channels =
                        u16::from_le_bytes([data[body_start + 2], data[body_start + 3]]) as usize;
                    sample_rate = u32::from_le_bytes([
                        data[body_start + 4],
                        data[body_start + 5],
                        data[body_start + 6],
                        data[body_start + 7],
                    ]) as i64;
                    let bits =
                        u16::from_le_bytes([data[body_start + 14], data[body_start + 15]]) as u32;
                    // 仅支持 16bit 线性 PCM
                    if audio_format != 1 || bits != 16 || channels == 0 {
                        return None;
                    }
                }
            }
            b"data" => {
                // 交错多声道：逐帧取第一通道（当前录音均为 mono）
                let bytes = &data[body_start..body_end];
                let frame = channels * 2;
                let mut i = 0;
                while i + frame <= bytes.len() {
                    pcm.push(i16::from_le_bytes([bytes[i], bytes[i + 1]]));
                    i += frame;
                }
                break;
            }
            _ => {}
        }
        // chunk 按 2 字节对齐（WAV 规范）
        off = body_end + (size & 1);
    }
    if pcm.is_empty() || sample_rate == 0 {
        None
    } else {
        Some((pcm, sample_rate))
    }
}

/// 均值抗混叠降采样（与 Dart downsamplePcm 逐字节一致）。
/// 每个输出采样 = 以其在源中的中心位置 ± half_window 窗口内采样的均值（截断除法）。
fn downsample(pcm: &[i16], from_hz: i64, to_hz: i64) -> Vec<i16> {
    if from_hz <= to_hz || pcm.is_empty() {
        return pcm.to_vec();
    }
    let input_samples = pcm.len();
    let ratio = from_hz as f64 / to_hz as f64;
    let output_samples = ((input_samples as f64 * to_hz as f64 / from_hz as f64).round()) as usize;
    let window_size = ratio.ceil() as i64;
    let half_window = window_size / 2;
    let mut out = Vec::with_capacity(output_samples);
    for i in 0..output_samples {
        let center = (i as f64 * ratio).floor() as i64;
        let mut sum: i64 = 0;
        let mut count: i64 = 0;
        for j in -half_window..=half_window {
            let idx = center + j;
            if idx >= 0 && (idx as usize) < input_samples {
                sum += pcm[idx as usize] as i64;
                count += 1;
            }
        }
        out.push(if count > 0 { (sum / count) as i16 } else { 0 });
    }
    out
}

/// 最大振幅（静音检测用），与 Dart computeMaxAmplitude 一致。
fn compute_max_amplitude(pcm: &[i16]) -> i64 {
    pcm.iter().fold(0i64, |m, s| m.max(s.abs() as i64))
}

/// 增益归一化：去除 DC 偏移并放大到目标振幅。
/// gain<=1 时原样返回（不做 DC 去除），与 Dart normalizeGain 行为一致。
fn normalize_gain(input: &[i16], target: i64) -> Vec<i16> {
    if input.is_empty() {
        return input.to_vec();
    }
    // 1. 计算 DC 偏移（直流分量，四舍五入）
    let sample_count = input.len() as i64;
    let sum: i64 = input.iter().map(|s| *s as i64).sum();
    let dc_offset = (sum as f64 / sample_count as f64).round() as i64;
    // 2. 去除 DC 后重新计算最大振幅
    let mut adjusted_max: i64 = 0;
    for s in input {
        let v = (*s as i64 - dc_offset).abs();
        if v > adjusted_max {
            adjusted_max = v;
        }
    }
    if adjusted_max < 1 {
        return input.to_vec();
    }
    // 3. 计算增益因子
    let gain = target as f64 / adjusted_max as f64;
    if gain <= 1.0 {
        return input.to_vec();
    }
    // 4. 应用增益（去 DC + 放大 + 限幅到 i16 范围）
    let mut out = Vec::with_capacity(input.len());
    for s in input {
        let sample = (*s as i64 - dc_offset) as f64;
        let amplified = (sample * gain).round();
        let clamped = amplified.clamp(-32768.0, 32767.0) as i16;
        out.push(clamped);
    }
    out
}
