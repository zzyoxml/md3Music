//! 频谱分析核心：PCM 环形缓冲 → Hann 加窗 FFT → 视觉带 + 节拍特征向量。
//!
//! 与 Kotlin `SpectrumFft` + `SpectrumFeatures` 行为对齐。
//! 帧结果通过单槽 SPSC 邮箱传递：生产者（feed_pcm 线程）写最新帧，
//! 消费者（poll_frame，Dart Timer 轮询）读取最新帧并丢弃旧帧。
//!
//! **线程模型**：`feed_pcm` 由 Android ExoPlayer 渲染线程调用；
//! `poll_frame` 由 Dart Timer 在主 isolate 事件循环调用。两者并发安全，
//! 非原子可变状态全部由 `Mutex<Inner>` 保护。

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use realfft::num_complex::Complex32;
use realfft::{RealToComplex, RealFftPlanner};

/// FFT 窗长（与 Android `FFT_SIZE` 一致）。
const FFT_SIZE: usize = 1024;

/// 视觉段数（与 Android `BAND_COUNT` 一致）。
pub const BAND_COUNT: usize = 40;

/// 最小发射间隔（毫秒）：≈43fps，等于 44.1kHz 的窗长。
const MIN_EMIT_INTERVAL_MS: i64 = 23;

/// 特征向量总长度（与 `SpectrumFeatures.COUNT` 一致）。
pub const FEATURE_COUNT: usize = 20;

/// 对数频带数量（与 `SpectrumFeatures.LOG_BAND_COUNT` 一致）。
const LOG_BAND_COUNT: usize = 16;

// ── PCM 编码常量（对齐 PcmEncoding.kt）─────────────────────────────
const ENC_PCM_8BIT: i32 = 3;
const ENC_PCM_16BIT: i32 = 2;
const ENC_PCM_FLOAT: i32 = 4;
const ENC_PCM_24BIT: i32 = 21;
const ENC_PCM_32BIT: i32 = 22;

// ── 频率范围常量（对齐 SpectrumFeatures.kt）───────────────────────
const F_MIN_HZ: f64 = 30.0;
const F_MAX_HZ: f64 = 16000.0;
const LOW_LO_HZ: f64 = 30.0;
const LOW_HI_HZ: f64 = 300.0;
const MID_LO_HZ: f64 = 300.0;
const MID_HI_HZ: f64 = 3000.0;
const HIGH_LO_HZ: f64 = 3000.0;
const HIGH_HI_HZ: f64 = 8000.0;

fn bytes_per_sample(encoding: i32) -> Option<usize> {
    match encoding {
        ENC_PCM_8BIT => Some(1),
        ENC_PCM_16BIT => Some(2),
        ENC_PCM_24BIT => Some(3),
        ENC_PCM_FLOAT | ENC_PCM_32BIT => Some(4),
        _ => None,
    }
}

/// 从交织 PCM 字节流解码一个左声道样本。
fn decode_sample(pcm: &[u8], offset: usize, encoding: i32) -> f32 {
    match encoding {
        ENC_PCM_8BIT => (pcm[offset] as i32 - 128) as f32 / 128.0,
        ENC_PCM_16BIT => {
            let raw = (pcm[offset] as u16) | ((pcm[offset + 1] as u16) << 8);
            (raw as i16) as f32 / 32768.0
        }
        ENC_PCM_FLOAT => {
            let bits = (pcm[offset] as u32)
                | ((pcm[offset + 1] as u32) << 8)
                | ((pcm[offset + 2] as u32) << 16)
                | ((pcm[offset + 3] as u32) << 24);
            let v = f32::from_bits(bits);
            if v.is_nan() || v.is_infinite() { 0.0 } else { v }
        }
        ENC_PCM_24BIT => {
            let b0 = pcm[offset] as u8 as i32;
            let b1 = pcm[offset + 1] as u8 as i32;
            let b2 = pcm[offset + 2] as i8 as i32;
            ((b2 << 16) | (b1 << 8) | b0) as f32 / 8388608.0
        }
        ENC_PCM_32BIT => {
            let bits = (pcm[offset] as u32)
                    | ((pcm[offset + 1] as u32) << 8)
                    | ((pcm[offset + 2] as u32) << 16)
                    | ((pcm[offset + 3] as u32) << 24);
            bits as f32 / 2147483648.0
        }
        _ => 0.0,
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 把频率映射到幅度数组下标（mags[i] 对应 bin i+1，跳过 DC）。
fn mag_index(hz: f64, hz_per_bin: f64, bin_count: usize) -> usize {
    let idx = (hz / hz_per_bin).floor() as isize - 1;
    idx.clamp(0, bin_count as isize - 1) as usize
}

// ── Mutex 内部：全部非原子可变状态 ──────────────────────────────

struct Inner {
    ring: [f32; FFT_SIZE],
    write_pos: usize,
    filled: usize,

    hann: [f32; FFT_SIZE],
    fft: Arc<dyn RealToComplex<f32>>,

    mags: [f64; FFT_SIZE / 2],
    bands: [f64; BAND_COUNT],

    features: [f32; FEATURE_COUNT],
    sample_rate_hz: i32,
    log_lo: [usize; LOG_BAND_COUNT],
    log_hi: [usize; LOG_BAND_COUNT],
    low_lo: usize,
    low_hi: usize,
    mid_lo: usize,
    mid_hi: usize,
    high_lo: usize,
    high_hi: usize,

    frame_data: ([f64; BAND_COUNT], [f32; FEATURE_COUNT]),
}

impl Inner {
    fn new() -> Self {
        let mut hann = [0.0f32; FFT_SIZE];
        for i in 0..FFT_SIZE {
            hann[i] = (0.5 * (1.0 - (2.0 * std::f64::consts::PI * i as f64 / (FFT_SIZE - 1) as f64).cos())) as f32;
        }

        let mut planner = RealFftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);

        let mut inner = Self {
            ring: [0.0f32; FFT_SIZE],
            write_pos: 0,
            filled: 0,

            hann,
            fft,

            mags: [0.0f64; FFT_SIZE / 2],
            bands: [0.0f64; BAND_COUNT],

            features: [0.0f32; FEATURE_COUNT],
            sample_rate_hz: 44100,

            log_lo: [0; LOG_BAND_COUNT],
            log_hi: [0; LOG_BAND_COUNT],
            low_lo: 0,
            low_hi: 1,
            mid_lo: 0,
            mid_hi: 1,
            high_lo: 0,
            high_hi: 1,

            frame_data: ([0.0f64; BAND_COUNT], [0.0f32; FEATURE_COUNT]),
        };

        inner.rebuild_feature_tables(44100);
        inner
    }

    fn reset(&mut self) {
        self.write_pos = 0;
        self.filled = 0;
        self.frame_data = ([0.0f64; BAND_COUNT], [0.0f32; FEATURE_COUNT]);
    }

    /// 追加一块 PCM 数据到环形缓冲。节流满足时触发 FFT 并发布到邮箱。
    /// **调用方必须持有 Inner 的 Mutex 锁。**
    fn feed_pcm_locked(&mut self, pcm: &[u8], encoding: i32, sample_rate: i32, channels: i32) {
        let bps = match bytes_per_sample(encoding) {
            Some(n) => n,
            None => return,
        };
        if channels <= 0 {
            return;
        }
        let frame_bytes = bps * channels as usize;
        let frames = pcm.len() / frame_bytes;
        if frames == 0 {
            return;
        }
        if sample_rate > 0 && sample_rate != self.sample_rate_hz {
            self.rebuild_feature_tables(sample_rate);
            self.sample_rate_hz = sample_rate;
        }

        let size = FFT_SIZE;
        let mut w = self.write_pos;
        for f in 0..frames {
            let base = f * frame_bytes;
            let v = decode_sample(pcm, base, encoding);
            self.ring[w] = v;
            w += 1;
            if w == size {
                w = 0;
            }
        }
        self.write_pos = w;
        self.filled = (self.filled + frames).min(size);
    }

    /// 执行加窗 + FFT + 视觉带提取 + 特征提取，写入 frame_data。
    /// **调用方必须持有 Inner 的 Mutex 锁。**
    fn compute_and_publish_locked(&mut self) {
        let w = self.write_pos;
        let mut snapshot = [0.0f32; FFT_SIZE];
        for i in 0..FFT_SIZE {
            let src = w + i;
            snapshot[i] = self.ring[if src >= FFT_SIZE { src - FFT_SIZE } else { src }];
        }

        // Hann 加窗 → realfft
        let mut real_input = [0.0f32; FFT_SIZE];
        for i in 0..FFT_SIZE {
            real_input[i] = snapshot[i] * self.hann[i];
        }
        let mut output = vec![Complex32::new(0.0, 0.0); FFT_SIZE / 2 + 1];
        self.fft.process(&mut real_input, &mut output).ok();

        // 计算幅度（跳过 DC，mags[i] 对应 bin i+1）
        let bin_count = FFT_SIZE / 2;
        for i in 0..bin_count {
            let c = output[i + 1];
            self.mags[i] = ((c.re * c.re + c.im * c.im) as f64).sqrt();
        }

        // 视觉带：取前 BAND_COUNT 个 bin，按帧内最大值自归一化
        let mut max_mag = 1.0f64;
        for i in 0..bin_count.min(BAND_COUNT) {
            if self.mags[i] > max_mag {
                max_mag = self.mags[i];
            }
        }
        for i in 0..BAND_COUNT {
            let raw = if i < bin_count {
                self.mags[i]
            } else {
                0.0
            };
            self.bands[i] = (raw / max_mag).clamp(0.0, 1.0);
        }

        // 特征提取
        self.extract_features(&snapshot);

        // 发布到 frame_data
        self.frame_data.0.copy_from_slice(&self.bands[..]);
        self.frame_data.1.copy_from_slice(&self.features[..]);
    }

    /// 从同一帧的原始幅度 + 时域样本提取紧凑特征向量。
    /// **调用方必须持有 Inner 的 Mutex 锁。**
    fn extract_features(&mut self, samples: &[f32; FFT_SIZE]) {
        let bin_count = FFT_SIZE / 2;

        for i in 0..LOG_BAND_COUNT {
            let lo = self.log_lo[i];
            let hi = self.log_hi[i].max(lo + 1).min(bin_count);
            let count = hi - lo;
            let sum: f64 = (lo..hi).map(|b| self.mags[b]).sum();
            self.features[i] = (sum / count as f64) as f32;
        }

        let sq: f64 = samples.iter().map(|s| (*s as f64) * (*s as f64)).sum();
        self.features[16] = ((sq / FFT_SIZE as f64).sqrt()) as f32;

        self.features[17] = band_mean(&self.mags, self.low_lo, self.low_hi.min(bin_count));
        self.features[18] = band_mean(&self.mags, self.mid_lo, self.mid_hi.min(bin_count));
        self.features[19] = band_mean(&self.mags, self.high_lo, self.high_hi.min(bin_count));
    }

    /// 当采样率变化时重建对数频带索引表。
    /// **调用方必须持有 Inner 的 Mutex 锁。**
    fn rebuild_feature_tables(&mut self, sample_rate: i32) {
        let effective = if sample_rate > 0 { sample_rate } else { 44100 };
        let hz_per_bin = effective as f64 / FFT_SIZE as f64;
        let bin_count = FFT_SIZE / 2;
        let log_ratio = F_MAX_HZ / F_MIN_HZ;

        for i in 0..LOG_BAND_COUNT {
            let lo_hz = F_MIN_HZ * log_ratio.powf(i as f64 / LOG_BAND_COUNT as f64);
            let hi_hz = F_MIN_HZ * log_ratio.powf((i + 1) as f64 / LOG_BAND_COUNT as f64);
            self.log_lo[i] = mag_index(lo_hz, hz_per_bin, bin_count);
            self.log_hi[i] = mag_index(hi_hz, hz_per_bin, bin_count).max(self.log_lo[i] + 1);
        }
        let top = LOG_BAND_COUNT - 1;
        self.log_hi[top] = self.log_hi[top]
            .max(mag_index(F_MAX_HZ, hz_per_bin, bin_count) + 1);

        self.low_lo = mag_index(LOW_LO_HZ, hz_per_bin, bin_count);
        self.low_hi = self.low_lo.max(mag_index(LOW_HI_HZ, hz_per_bin, bin_count));
        self.mid_lo = mag_index(MID_LO_HZ, hz_per_bin, bin_count);
        self.mid_hi = self.mid_lo.max(mag_index(MID_HI_HZ, hz_per_bin, bin_count));
        self.high_lo = mag_index(HIGH_LO_HZ, hz_per_bin, bin_count);
        self.high_hi = self.high_lo.max(mag_index(HIGH_HI_HZ, hz_per_bin, bin_count));
    }
}

// ── 外部可见的 SpectrumState ─────────────────────────────────────

/// 频谱分析状态。通过 FFI 句柄持有，`spectrum_drop_state` 负责释放。
///
/// 非原子可变字段封装在 `Mutex<Inner>` 中；调度元数据用原子变量。
/// `feed_pcm` 和 `poll_frame` 均以 `&self` 调用，可在多线程间共享。
pub struct SpectrumState {
    inner: Mutex<Inner>,
    last_emit_ms: AtomicI64,
    has_new_frame: AtomicBool,
    total_frames: AtomicU64,
    emit_count: AtomicU64,
    sample_rate_hz: AtomicI32,
}

impl SpectrumState {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner::new()),
            last_emit_ms: AtomicI64::new(-1),
            has_new_frame: AtomicBool::new(false),
            total_frames: AtomicU64::new(0),
            emit_count: AtomicU64::new(0),
            sample_rate_hz: AtomicI32::new(44100),
        }
    }

    /// 重置全部内部状态（切歌/重绑时调用）。
    pub fn reset(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.reset();
        }
        self.last_emit_ms.store(-1, Ordering::Relaxed);
        self.has_new_frame.store(false, Ordering::Release);
        self.total_frames.store(0, Ordering::Relaxed);
        self.emit_count.store(0, Ordering::Relaxed);
        self.sample_rate_hz.store(0, Ordering::Relaxed);
    }

    /// 追加一块 PCM 数据到环形缓冲。节流满足时触发 FFT 并发布到邮箱。
    ///
    /// **一次锁获取**：validation + feed + compute 全在同一个临界区内。
    /// 渲染线程唯一调用者；Dart 侧 poll 仅短暂持锁拷贝帧数据。
    pub fn feed_pcm(&self, pcm: &[u8], encoding: i32, sample_rate: i32, channels: i32) {
        // ── 前置校验（无需锁）──
        let bps = match bytes_per_sample(encoding) {
            Some(n) => n,
            None => return,
        };
        if channels <= 0 {
            return;
        }
        let frame_bytes = bps * channels as usize;
        let frames = pcm.len() / frame_bytes;
        if frames == 0 {
            return;
        }

        // ── 节流判定（仅读原子变量，不进锁）──
        let now = now_ms();
        let last = self.last_emit_ms.load(Ordering::Relaxed);
        let should_emit = last < 0 || now - last >= MIN_EMIT_INTERVAL_MS;
        if should_emit {
            self.last_emit_ms.store(now, Ordering::Relaxed);
        }
        if sample_rate > 0 && sample_rate != self.sample_rate_hz.load(Ordering::Relaxed) {
            self.sample_rate_hz.store(sample_rate, Ordering::Relaxed);
        }

        // ── 一次临界区：feed + （可选）compute ──
        let mut emitted = false;
        {
            let mut inner = match self.inner.lock() {
                Ok(g) => g,
                Err(_) => return,
            };
            inner.feed_pcm_locked(pcm, encoding, sample_rate, channels);
            if should_emit && inner.filled >= FFT_SIZE {
                inner.compute_and_publish_locked();
                emitted = true;
            }
        }

        self.total_frames.fetch_add(frames as u64, Ordering::Relaxed);
        if emitted {
            self.has_new_frame.store(true, Ordering::Release);
            self.emit_count.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Dart 侧轮询：有新帧返回 true 并拷出，否则 false。
    pub fn poll_frame(&self, bands_out: &mut [f64], features_out: &mut [f32]) -> bool {
        if !self.has_new_frame.load(Ordering::Acquire) {
            return false;
        }
        let data = match self.inner.lock() {
            Ok(g) => g,
            Err(_) => return false,
        };
        bands_out[..BAND_COUNT].copy_from_slice(&data.frame_data.0[..]);
        features_out[..FEATURE_COUNT].copy_from_slice(&data.frame_data.1[..]);
        drop(data);
        self.has_new_frame.store(false, Ordering::Release);
        true
    }
}

fn band_mean(mags: &[f64; FFT_SIZE / 2], lo: usize, hi: usize) -> f32 {
    let start = lo.min(mags.len() - 1);
    let end = hi.max(start + 1).min(mags.len());
    let count = end - start;
    let sum: f64 = (start..end).map(|b| mags[b]).sum();
    (sum / count as f64) as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine_pcm_16bit(freq_hz: f32, sample_rate: i32, frames: usize) -> Vec<u8> {
        let mut buf = Vec::with_capacity(frames * 4);
        for i in 0..frames {
            let t = i as f32 / sample_rate as f32;
            let v = (2.0 * std::f32::consts::PI * freq_hz * t).sin() * 0.8;
            let s = (v * 32767.0).clamp(-32768.0, 32767.0) as i16;
            buf.extend_from_slice(&s.to_le_bytes());
            buf.extend_from_slice(&s.to_le_bytes());
        }
        buf
    }

    #[test]
    fn lifecycle_feed_poll() {
        let state = SpectrumState::new();
        assert!(!state.poll_frame(&mut [0.0; BAND_COUNT], &mut [0.0; FEATURE_COUNT]));

        let pcm = sine_pcm_16bit(440.0, 44100, FFT_SIZE * 2 + 256);
        state.feed_pcm(&pcm, ENC_PCM_16BIT, 44100, 2);

        let mut bands = [0.0f64; BAND_COUNT];
        let mut features = [0.0f32; FEATURE_COUNT];
        let got = state.poll_frame(&mut bands, &mut features);
        assert!(got, "首帧应可轮询");

        let max_band = bands.iter().enumerate()
            .max_by(|a, b| a.1.abs().partial_cmp(&b.1.abs()).unwrap())
            .unwrap();
        assert!(
            (7..=13).contains(&max_band.0),
            "440Hz 应在 bin 10 附近，实际峰值在 band {max_band:?}"
        );

        assert!(features[16] > 0.3 && features[16] < 0.7,
            "RMS 应在合理范围，实际 {}", features[16]);
    }

    #[test]
    fn reset_clears_state() {
        let state = SpectrumState::new();
        let pcm = sine_pcm_16bit(440.0, 44100, FFT_SIZE * 2);
        state.feed_pcm(&pcm, ENC_PCM_16BIT, 44100, 2);

        state.reset();

        assert!(!state.poll_frame(&mut [0.0; BAND_COUNT], &mut [0.0; FEATURE_COUNT]));
    }

    #[test]
    fn unsupported_encoding_drops_silently() {
        let state = SpectrumState::new();
        state.feed_pcm(&[0u8; 4096], 99, 44100, 2);
        assert!(!state.poll_frame(&mut [0.0; BAND_COUNT], &mut [0.0; FEATURE_COUNT]));
    }
}