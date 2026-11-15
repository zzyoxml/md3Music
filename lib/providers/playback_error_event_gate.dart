/// just_audio 用此代码表示一次加载被后续 setUrl 中断，属于快速切歌的正常信号。
const int interruptedPlayerLoadErrorCode = 10000000;

/// 只有当前请求已经装载成功后的错误才转成可见播放失败。
///
/// 装载阶段错误由对应 setUrl Future 返回给调用方处理；过期请求的错误事件
/// 不能覆盖新曲目状态。
bool shouldHandlePlaybackErrorEvent({
  required int errorCode,
  required bool isCurrentRequest,
  required bool loadCompleted,
}) {
  if (errorCode == interruptedPlayerLoadErrorCode) return false;
  return isCurrentRequest && loadCompleted;
}
