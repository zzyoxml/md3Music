import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/build_flags.dart';
import '../../core/platform_capabilities.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/md3e_loading_indicator.dart';

/// 曲谱类型：1 吉他 / 2 尤克里里 / 3 钢琴 / 4 简谱。
const _kInstruments = <int, String>{1: '吉他', 2: '尤克里里', 3: '钢琴', 4: '简谱'};

/// 难度徽章文案：随乐器语义不同（接口文档 level 说明）。
String _levelLabel(int instruments, int level) {
  switch (instruments) {
    case 1: // 吉他：1 进阶 / 2 基础 / 0 中级
      return switch (level) { 1 => '进阶', 2 => '基础', _ => '中级' };
    case 2: // 尤克里里/钢琴：0 基础 / 1 进阶
    case 3:
      return level == 1 ? '进阶' : '基础';
    default: // 简谱：0 基础
      return '基础';
  }
}

/// 歌曲曲谱面板入口。
///
/// 与「看成绩单」同模式（歌曲信息页 / 歌曲行菜单共用）：数据来自
/// /sheet/song（匿名可用），列表项携带酷狗官方 H5 渲染页 jump_url，
/// 点击用应用内 WebView 打开——谱面是 musicxml/pulu 加密文件，不在客户端解析。
void showSongSheetSheet(BuildContext context, Song song) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) => DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (innerCtx, scrollController) => Column(
        children: [
          Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(innerCtx).colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '曲谱: ${song.displayName}',
                    style: Theme.of(innerCtx).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(innerCtx).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SongSheetView(
              song: song,
              scrollController: scrollController,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 曲谱内容视图：乐器筛选 + 曲谱列表，点击项进入酷狗官方谱面渲染页。
class SongSheetView extends StatefulWidget {
  final Song song;

  /// 绑定 DraggableScrollableSheet 的滚动控制器（列表滚到顶后继续拖可缩放面板）。
  final ScrollController? scrollController;

  const SongSheetView({super.key, required this.song, this.scrollController});

  @override
  State<SongSheetView> createState() => _SongSheetViewState();
}

class _SongSheetViewState extends State<SongSheetView> {
  int _instruments = 1;
  List<KugouSheetInfo> _items = [];
  bool _loading = true;
  String? _error;

  String? get _albumAudioId {
    final id = widget.song.albumAudioId;
    if (id == null || id.isEmpty) return null;
    return id;
  }

  @override
  void initState() {
    super.initState();
    if (_albumAudioId != null) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await KugouApiClient().getSheetSong(
      _albumAudioId!,
      instruments: _instruments,
    );
    if (!mounted) return;
    final list = <KugouSheetInfo>[];
    if (r != null) {
      final data = r['data'] as Map<String, dynamic>? ?? r;
      final raw = data['list'];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map<String, dynamic>) {
            final item = KugouSheetInfo.fromJson(e);
            // 有 opern_id 才是有效谱目（外层歌曲壳无 opern_id）
            if (item.opernId.isNotEmpty) list.add(item);
          }
        }
      }
    }
    setState(() {
      _loading = false;
      _items = list;
      if (r == null) {
        _error = '曲谱加载失败';
      } else if (list.isEmpty) {
        _error = null;
      }
    });
  }

  void _switchInstruments(int v) {
    if (v == _instruments) return;
    setState(() => _instruments = v);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 曲谱依赖 album_audio_id（即 MixSongID），缺失时无可查询
    if (_albumAudioId == null) {
      return _buildEmpty(context, '该歌曲暂无曲谱数据', colorScheme, textTheme);
    }

    return Column(
      children: [
        // 乐器筛选行
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              children: [
                for (final e in _kInstruments.entries)
                  _InstrumentsChip(
                    label: e.value,
                    selected: _instruments == e.key,
                    onTap: () => _switchInstruments(e.key),
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(context, colorScheme, textTheme)),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MD3ELoadingIndicator(),
            const SizedBox(height: 12),
            Text('曲谱加载中…',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return _buildEmpty(context, '暂无该类型的曲谱', colorScheme, textTheme);
    }
    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: _items.length,
      itemBuilder: (ctx, i) => _SheetTile(
        item: _items[i],
        fallbackOpernId:
            '${_albumAudioId}_${_instruments}_${_items[i].opernLevel}',
      ),
    );
  }

  Widget _buildEmpty(
    BuildContext context,
    String message,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_music_outlined,
              size: 40, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(message,
              style: textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 曲谱列表项：谱名 + 类型/记法 + 调性 + 难度徽章。
class _SheetTile extends StatelessWidget {
  final KugouSheetInfo item;

  /// 上游未回 opern_id 时的兜底拼法（文档示例 `{album_audio_id}_{instruments}_{level}`）。
  final String fallbackOpernId;

  const _SheetTile({required this.item, required this.fallbackOpernId});

  void _open(BuildContext context) {
    final opernId =
        item.opernId.isNotEmpty ? item.opernId : fallbackOpernId;
    openSheetRender(
      context,
      SheetRenderTarget(
        title: item.opernTypeName ?? item.name,
        opernId: opernId,
        jumpUrl: item.jumpUrl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final meta = <String>[
      if (item.opernDrawTypeName?.isNotEmpty ?? false) item.opernDrawTypeName!,
      if (item.originalTune?.isNotEmpty ?? false) '原调 ${item.originalTune!}',
      if (item.opernAuthor?.isNotEmpty ?? false) '谱：${item.opernAuthor!}',
    ].join(' · ');

    final head = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          const Icon(Icons.library_music_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.opernTypeName ?? item.name,
                  style: textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _levelLabel(item.instruments, item.opernLevel),
              style: textTheme.labelMedium
                  ?.copyWith(color: colorScheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
        ],
      ),
    );

    final tile = kTvBuild
        ? DpadFocusable(
            debugLabel: 'tv/song-sheet-${item.opernId}',
            onSelect: () => _open(context),
            // 宽度钉回外层列宽，避免 TV 焦点矩形收缩到内容宽
            child: SizedBox(width: double.infinity, child: head),
          )
        : InkWell(onTap: () => _open(context), child: head);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: tile,
    );
  }
}

/// 乐器筛选芯片（触摸用 InkWell，TV 下单停点 DpadFocusable）。
class _InstrumentsChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _InstrumentsChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bg = selected ? colorScheme.primaryContainer : null;
    final fg =
        selected ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant;
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(label,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: fg)),
    );
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'tv/song-sheet-chip-$label',
        onSelect: onTap,
        child: Container(
          width: null,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
          ),
          child: child,
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
        ),
        child: child,
      ),
    );
  }
}

/// 谱面渲染入口：按平台能力分流。
///
/// Android（非 TV）用应用内 WebView（[SheetRenderPage]）；桌面/TV 构建没有
/// `webview_flutter` 平台实现（WebViewController 抛 MissingPluginException，
/// 整页被全局 ErrorWidget 替换），降级为系统浏览器打开 jump_url。
void openSheetRender(BuildContext context, SheetRenderTarget target) {
  if (supportsInAppWebView) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SheetRenderPage(
          title: target.title,
          opernId: target.opernId,
          jumpUrl: target.jumpUrl,
        ),
      ),
    );
    return;
  }
  _launchExternal(context, target.url);
}

/// 渲染目标：谱名 + opern_id + 可选 jump_url。
class SheetRenderTarget {
  final String title;
  final String opernId;
  final String? jumpUrl;

  const SheetRenderTarget({
    required this.title,
    required this.opernId,
    this.jumpUrl,
  });

  /// 最终打开的地址：jump_url 优先，缺失时拼官方 xml 渲染页兜底。
  String get url {
    final jump = jumpUrl;
    if (jump != null && jump.startsWith('http')) return jump;
    return 'https://h5.kugou.com/voo/v-73bc3efd/xml.html?isHideTitleBar=1'
        '&opernid=${Uri.encodeComponent(opernId)}'
        '&opern_source=7&sheetDataType=0&sheetType=1&status=1';
  }
}

/// 系统浏览器打开（桌面/TV 降级路径），失败用原生 Toast 提示。
Future<void> _launchExternal(BuildContext context, String url) async {
  try {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (context.mounted) showToast('无法打开谱面链接');
  } catch (_) {
    if (context.mounted) showToast('无法打开谱面链接');
  }
}

/// 酷狗官方谱面渲染页（jump_url 的应用内 WebView）。
///
/// 谱面是 musicxml / 加密 pulu 文件，酷狗 H5（xml.html / opern.html）负责渲染，
/// 客户端不解析。**仅在 supportsInAppWebView 平台可达**（Android 非 TV），
/// 桌面/TV 走 [openSheetRender] 的系统浏览器降级，不要直接 push 本页。
class SheetRenderPage extends StatefulWidget {
  final String title;
  final String opernId;
  final String? jumpUrl;

  const SheetRenderPage({
    super.key,
    required this.title,
    required this.opernId,
    this.jumpUrl,
  });

  @override
  State<SheetRenderPage> createState() => _SheetRenderPageState();
}

class _SheetRenderPageState extends State<SheetRenderPage> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final target = SheetRenderTarget(
      title: widget.title,
      opernId: widget.opernId,
      jumpUrl: widget.jumpUrl,
    );
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          // 页面是 React SPA，首屏 DOM 完成后再注入净化 CSS；SPA 内部
          // 路由切换由 MutationObserver 兜底（CSS 规则本身常驻，双保险）。
          _controller.runJavaScript(_kPurifyScript);
          if (mounted) setState(() => _loading = false);
        },
      ))
      ..loadRequest(Uri.parse(target.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(child: MD3ELoadingIndicator()),
        ],
      ),
    );
  }
}

/// 酷狗 H5 谱面页净化脚本（2026-10-24 逆向 chunk-2559 得到的类名清单）。
///
/// 只隐藏推广/无效元素，保留谱面与看谱相关 UI：
/// - 隐藏：顶部 Pulu 品牌 banner（"海量吉他钢琴尤克里里简谱/立即体验"，类
///   `mod_navigation_title_bar mod_navigation_share`）、底部"打开普鲁App"
///   引导条（含"送3个月会员"角标）、"查看曲谱"全屏悬浮拦截层
///   （`mod_navigation_share_bottom`，z-index 200 还会吞掉谱面点击！）、
///   顶部活动横幅、评分弹窗、优惠券 Toast、底部下载/VIP 工具条、
///   右上"保存/更多"死按钮、TME 占位、打开App确认弹窗遮罩；
/// - 保留：谱面本体、原调/调号元信息条（doc-top-msg-bar）、歌名/难度头部
///   （song_info）、底部翻页/原曲工具条（page_handle/bottom_select）。
///
/// 全部用 `[class*="..."]` 通配：React CSS Modules 的类名带编译期 hash
/// （如 `RateModal_overlay__1aGWM`），通配才稳定。
/// **不隐藏 song_info 本体**：页面 JS 用 `offsetHeight` 动态计算谱面可视高
/// （effectiveH），隐藏本体读到 0 会导致滚动定位错位。隐藏 banner 后
/// topInset 自然变小，谱面区域自动上移变大（布局函数已核实读的是
/// offsetHeight，React 重渲染时自适应）。
const String _kPurifyScript = '''
(function() {
  if (window.__MD3_SHEET_PURIFY__) return;
  window.__MD3_SHEET_PURIFY__ = true;
  var css = [
    '[class*="mod_navigation_share"]',
    '[class*="open_pulu_tips"]',
    '[class*="top_bar"]',
    '[class*="RateModal_"]',
    '[class*="CouponSuccessToast"]',
    '[class*="one-page-toolbar"]',
    '.song_info_tme_placeholder',
    '[class*="navigation_bar__ft"]',
    '[class*="qui_dialog"]',
    '[class*="mui_dialog"]'
  ].join(',') + '{display:none !important;}';
  var style = document.createElement('style');
  style.id = 'md3-sheet-purify';
  style.textContent = css;
  document.head.appendChild(style);
})();
''';

/// 曲谱卡片封面图（占位，供广场页共用；列表项不显示封面）。
class SheetCoverImage extends StatelessWidget {
  final String? url;
  final double size;

  const SheetCoverImage({super.key, required this.url, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final resolved = (url != null && url!.isNotEmpty) ? url! : null;
    Widget fallback() => Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Icon(Icons.library_music_outlined,
              size: size * 0.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: resolved != null
            ? CachedNetworkImage(
                imageUrl: resolved,
                fit: BoxFit.cover,
                placeholder: (_, _) => fallback(),
                errorWidget: (_, _, _) => fallback(),
              )
            : fallback(),
      ),
    );
  }
}
