/// CDN播放速率异常时，根据剩余缓冲决定是否立即重建音源。
enum CdnStallWindowDecision {
  sufficientProgress,
  waitForBufferedAudio,
  refreshSource,
}

/// 慢速窗口仍有足够缓冲时继续播放，避免无谓重建解码器造成听感中断。
CdnStallWindowDecision classifyCdnStallWindow({
  required Duration advanced,
  required Duration elapsed,
  required Duration bufferedHeadroom,
  required Duration minimumBufferedHeadroom,
  required double minimumPlaybackRate,
}) {
  if (elapsed <= Duration.zero || advanced < Duration.zero) {
    return CdnStallWindowDecision.sufficientProgress;
  }
  if (advanced.inMicroseconds >= elapsed.inMicroseconds * minimumPlaybackRate) {
    return CdnStallWindowDecision.sufficientProgress;
  }
  if (bufferedHeadroom > minimumBufferedHeadroom) {
    return CdnStallWindowDecision.waitForBufferedAudio;
  }
  return CdnStallWindowDecision.refreshSource;
}
