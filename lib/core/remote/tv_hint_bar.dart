import 'package:flutter/material.dart';

/// tv: 遥控键位提示条——当前焦点控件支持哪些按键，显示在画面底部一行。
///
/// ## 为什么需要
///
/// TV 没有鼠标悬停、没有光标，用户只能靠「试」。播放页里「落在进度条上时
/// 左右键调 5/15/30 秒、OK 落定」这类语义无法从图标看出来（用户反馈口径：
/// 操控不直观）。本组件由各控件在**获得焦点时**上报提示文案、失焦时清除，
/// 全局只画一条，避免每个控件各自叠一层。
///
/// 实现为全局 [ValueNotifier]（非 Provider）：提示由 `DpadFocusable`
/// `onFocusChange` 在 rebuild 之外写入，值为纯字符串、变化频率与焦点同步，
/// 单一订阅点即可（同 `kDesktopModeEnabled` 的「值型订阅」模式）。
///
/// 本组件不带 `kTvBuild` 门控（可测，AGENTS §12 惯例）；是否挂载由调用方决定
/// （本仓为 `kTvBuild` 分支下的播放页/列表页）。
class TvHintBarScope {
  TvHintBarScope._();

  /// 当前提示文案；空串 = 不显示。
  static final ValueNotifier<String> current = ValueNotifier<String>('');

  /// 上报提示（获得焦点时调用）。
  static void show(String text) {
    if (current.value != text) current.value = text;
  }

  /// 清除提示（失焦 / 焦点移出该控件时调用）。
  static void clear() {
    if (current.value.isNotEmpty) current.value = '';
  }
}

/// 提示条的绘制壳：订阅 [TvHintBarScope.current]，按需在下沿画一条胶囊。
class TvHintBar extends StatelessWidget {
  const TvHintBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: TvHintBarScope.current,
      builder: (context, text, _) {
        if (text.isEmpty) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            minimum: const EdgeInsets.only(bottom: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(text, style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          ),
        );
      },
    );
  }
}
