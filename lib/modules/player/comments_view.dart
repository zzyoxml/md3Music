import '../../widgets/comment_verification.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../services/kugou_api/comment_delete.dart';
import '../../services/kugou_api/comment_reply_target.dart';
import '../../services/kugou_api/comment_send_result.dart';
import '../../services/kugou_api/comment_sort.dart';
import '../../widgets/comment_composer.dart';
import '../../widgets/comment_image_grid.dart';
import '../../widgets/comment_image_viewer.dart';
import '../../widgets/keyboard_expand_sheet.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import '../login/login_page.dart';
import '../../providers/comment_display_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/song_match_provider.dart';
import '../../services/kugou_api/comment_thread.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import 'comment_sort_filter_bar.dart';

/// 统一的评论面板入口。
///
/// 将歌曲菜单「看评论」与「无法播放」弹窗中的评论入口合并为同一实现：
/// 使用 [DraggableScrollableSheet] 可拖拽调整高度，顶部为标题栏（歌名 + 关闭按钮），
/// 内容区为 [CommentsView]。
void showSongCommentsSheet(BuildContext context, Song song) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) => KeyboardExpandScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.4,
      // 允许拖到最顶部（全屏高度），配合 useSafeArea 顶部避开状态栏；
      // 键盘弹出时也展开到这个高度，避免打字时列表被托盘比例限制成一条缝
      maxChildSize: 1.0,
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
                    '评论: ${song.displayName}',
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
            child: CommentsView(
              songHash: song.id,
              albumAudioId: song.albumAudioId,
              artworkUri: song.artworkUri,
              // 绑定 DraggableScrollableSheet 的滚动控制器：
              // 列表滚到顶部后继续上/下拖即可缩放面板高度（0.4~1.0）
              scrollController: scrollController,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 楼层评论状态
class _FloorState {
  bool expanded = false;
  bool loading = false;
  bool initialized = false;
  List<KugouComment> replies = [];
  int total = 0;
  int page = 1;
  bool hasMore = true;
  String message = '';
}

/// 评论列表视图。
///
/// 在 FullPlayer 中作为 TabBarView 第三个 Tab 展示。
///
/// - AM 风格（[isAmStyle] = true）：背景为模糊封面 + 黑蒙版，统一白色文字。
/// - MD3 风格（[isAmStyle] = false，默认）：跟随莫奈色主题，用户名用主色调，
///   评论正文和时间戳根据深浅色模式自动适配。
///
/// **功能**：
/// - 歌手评论/歌手评论置顶展示，带徽章标识
/// - 歌曲评论按热度（点赞数）降序排列
/// - 楼层评论（楼中楼），点击"查看N条回复"展开；回复按时间倒序（新的在前），
///   对回复的回复按层级嵌套缩进
/// - 长评论展开/收起（超过 120 字或 3 行）
/// - 点赞数格式化（10000+ → "1w"）
/// - 滚动到底部自动加载下一页
class CommentsView extends StatefulWidget {
  final String songHash;
  final String? albumAudioId;

  /// 封面 URL（保留参数兼容性，不再用于智能反色）。
  final String? artworkUri;

  /// 是否为 AM 风格播放器。true 时使用白色文字方案，false 时跟随主题色。
  final bool isAmStyle;

  /// 外部传入的滚动控制器（评论托盘 DraggableScrollableSheet 提供），
  /// 用于让面板高度可随列表滚动交互式缩放。为空时内部自建。
  final ScrollController? scrollController;

  /// 是否显示底部评论输入框（默认 true，评论弹层用）。
  ///
  /// 全屏播放器的评论 tab 传 false：输入不在播放器里进行——长按底部评论段弹出
  /// 评论托盘，托盘里的 [CommentsView] 输入框是常驻的（也是主题色设计）。
  final bool showComposer;

  /// [showComposer] 为 false 时，点评论项「回复」的回调（播放器弹出仅含输入框
  /// 的托盘，[target] 为被回复的那条评论；传 null 表示发顶层评论）。
  /// 与 [showComposer] 都缺省时「回复」入口不显示。
  final void Function(CommentReplyTarget? target)? onReplyComment;

  const CommentsView({
    super.key,
    required this.songHash,
    this.albumAudioId,
    this.artworkUri,
    this.isAmStyle = false,
    this.scrollController,
    this.showComposer = true,
    this.onReplyComment,
  });

  @override
  State<CommentsView> createState() => _CommentsViewState();
}

class _CommentsViewState extends State<CommentsView> {
  /// 楼层评论每页条数。上游硬上限 50，取满可减少翻页次数，
  /// 让楼中楼的父子关系更早在同一批数据里凑齐。
  static const int _floorPageSize = 50;

  late final ScrollController _scrollController;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;

  /// 评论区 id，「最热」接口必需，只能从 /comment/music 的响应里取。
  String _childrenId = '';

  /// 当前回复目标（非空即输入框处于回复模式）。
  /// 同时表达「楼层根评论」（tid）与「被回复的那条回复」（pid，楼中楼）。
  CommentReplyTarget? _replyTarget;

  /// 评论发送在途：禁用输入框，防止连点造成重复公开评论。
  bool _sendingComment = false;

  /// 删除在途的评论 id（含楼中楼回复）：在途时忽略再次长按，防止重复删除。
  final Set<String> _deletingCommentIds = {};

  /// 范围筛选：全部 / 歌手 / 我的（客户端过滤已加载数据，
  /// 上游无按用户筛选的评论接口；「加载更多」照常可用）。
  CommentScope _scope = CommentScope.all;

  /// 下拉菜单条目。
  ///
  /// **必须在 [CommentScope] 变化时换成新实例，且其余时刻保持稳定**：
  /// - M3EDropdownMenu.didUpdateWidget 以 `widget.items != oldWidget.items`
  ///   （列表同一性）判断是否 setItems。若每次 build 都新建列表，该判断恒真
  ///   → setItems 在 build 期间回调 _onSelectionChange → setState during build
  ///   → 语义树更新无限互递归（真机 ANR，2026-09-29）。
  /// - 反过来，若**永不**换实例，setItems 就再也不会触发，内部 controller 的
  ///   选中态与外部 [_scope] 会脱节：切到「歌手评论」后再也切不回「全部评论」，
  ///   因为下拉框展示的 selected 标记仍冻结在构造那一刻。
  ///
  /// 折中做法：稳定实例 + 仅在 [_scope] 真正变化时整体重建（见 [CommentScope] 的
  /// setter）。setItems 触发的回调会命中「同值直接忽略」的保护，不会 setState。
  List<M3EDropdownItem<CommentScope>> _scopeItems = _buildScopeItems(
    CommentScope.all,
  );

  static List<M3EDropdownItem<CommentScope>> _buildScopeItems(
    CommentScope selected,
  ) => [
    for (final scope in CommentScope.values)
      M3EDropdownItem(
        label: switch (scope) {
          CommentScope.all => '全部',
          CommentScope.singer => '歌手',
          CommentScope.mine => '我的',
        },
        value: scope,
        selected: scope == selected,
      ),
  ];

  /// 评论排序方式（默认最热）。切换后重新拉取第一页。
  CommentSortMode _sortMode = CommentSortMode.hottest;

  /// 「最热」模式的主列表：原生 topliked 各页（全局点赞降序）。
  ///
  /// 每种排序各自缓存主列表与分页进度，切换排序只是换个现成的列表，
  /// **不重新请求**——之前的生硬感来自切换时的整页重拉。
  final List<KugouComment> _toplikedList = [];
  int _toplikedPage = 1;
  bool _toplikedHasMore = true;

  /// 「最新/最早」模式的主列表：cmtlist 各页。两种时间排序共用同一份数据，
  /// 展示顺序由排序方式决定；「歌手评论」栏也来自它的 star_cmts。
  final List<KugouComment> _recentList = [];
  int _recentPage = 1;
  bool _recentHasMore = true;

  /// 当前排序模式的主列表。
  List<KugouComment> get _activeList =>
      _sortMode == CommentSortMode.hottest ? _toplikedList : _recentList;

  /// 当前排序模式是否还有下一页。
  bool get _activeHasMore =>
      _sortMode == CommentSortMode.hottest ? _toplikedHasMore : _recentHasMore;

  /// 「歌手评论」栏（/comment/music 的 star_cmts/歌手评论），所有排序模式共用。
  List<KugouComment> _hotComments = [];

  /// 长评论展开状态
  final Set<String> _expandedContents = {};

  /// 楼层评论状态（按评论 ID 索引）
  final Map<String, _FloorState> _floorStates = {};

  /// 评论项 GlobalKey（按评论 ID 索引），用于收起楼中楼后定位滚动
  final Map<String, GlobalKey> _commentItemKeys = {};

  GlobalKey _keyForComment(String id) =>
      _commentItemKeys.putIfAbsent(id, () => GlobalKey());

  /// 收起滚动操作序号：每次收起自增，异步滚动前校验，只允许最新一次生效，
  /// 避免多个收起操作并发时滚动互相干扰。
  int _collapseScrollSeq = 0;

  // ---- 本地歌曲匹配解析 ----
  // 本地歌曲的 songHash 是 `local_<路径>`，不是在线 hash，直接拉评论必然
  // 查不到。命中匹配记忆后改用在线 hash/albumAudioId/artworkUri 拉取。
  String? _resolvedHash;
  String? _resolvedAlbumAudioId;

  /// 实际用于拉取/发送评论的 hash（本地未匹配时仍是原始 local_ 值）。
  String get _effectiveHash => _resolvedHash ?? widget.songHash;

  String? get _effectiveAlbumAudioId =>
      _resolvedAlbumAudioId ?? widget.albumAudioId;

  /// 本地歌曲是否未匹配在线歌曲（空态提示文案用）。
  bool get _isUnmatchedLocal =>
      widget.songHash.startsWith('local_') && _resolvedHash == null;

  /// 在 initState / songHash 变化时解析：本地歌曲查匹配记忆，改写生效身份。
  void _resolveLocalMatch() {
    _resolvedHash = null;
    _resolvedAlbumAudioId = null;
    if (!widget.songHash.startsWith('local_')) return;
    // 用可空读取：测试等无 Provider 环境下静默跳过，保持原行为
    final matchProvider = context.read<SongMatchProvider?>();
    if (matchProvider == null) return;
    final localId = widget.songHash;
    if (!matchProvider.isMatched(localId)) return;
    final info = matchProvider.matchedSongForId(localId);
    if (info == null) return;
    _resolvedHash = info.id;
    _resolvedAlbumAudioId = info.albumAudioId;
  }

  @override
  void initState() {
    super.initState();
    // 优先使用外部（评论托盘 DraggableScrollableSheet）传入的控制器，
    // 使面板高度可随列表滚动缩放；未传入时自建。
    _scrollController = widget.scrollController ?? ScrollController();
    _scrollController.addListener(_onScroll);
    _resolveLocalMatch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchComments();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    // 仅自建的控制器由本 State 释放；外部传入的归 DraggableScrollableSheet 管理
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songHash != widget.songHash) {
      _resolveLocalMatch();
      _childrenId = '';
      _toplikedList.clear();
      _toplikedPage = 1;
      _toplikedHasMore = true;
      _recentList.clear();
      _recentPage = 1;
      _recentHasMore = true;
      _hotComments.clear();
      _expandedContents.clear();
      _floorStates.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fetchComments();
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _fetchComments({bool silent = false}) async {
    if (_effectiveHash.isEmpty) return;

    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    final kugouProvider = context.read<KugouProvider>();
    final result = await kugouProvider.getComments(
      _effectiveHash,
      albumAudioId: _effectiveAlbumAudioId,
      page: 1,
    );

    // 静默刷新失败（拿不到数据）时保留现有列表，不切错误页
    if (silent && result == null) return;

    // 这一次 /comment/music 请求同时提供两样只有它才有的东西：歌手评论/精彩评论，
    // 以及「最热」接口必需的评论区 id。
    _childrenId = result?.childrenId ?? '';

    if (mounted) {
      setState(() {
        _isLoading = false;
        // 时间排序（最新/最早）的主列表：cmtlist 第一页
        if (result != null) {
          _recentList
            ..clear()
            ..addAll(result.comments);
          _recentPage = 1;
          _recentHasMore = result.comments.length >= 20;
          _hotComments = result.hotComments;
        }
        _error = result == null ? kugouProvider.error : kugouProvider.error;
      });
    }
    if (result == null || _childrenId.isEmpty) return;

    // 「最热」主列表独立拉取：两个数据源各自缓存，切换排序零请求零等待
    final hot = await KugouApiClient().getToplikedComments(_childrenId, page: 1);
    if (mounted && hot != null) {
      setState(() {
        _toplikedList
          ..clear()
          ..addAll(sortCommentsByHotness(hot.comments));
        _toplikedPage = 1;
        _toplikedHasMore = hot.comments.length >= 20;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || _isLoading) return;
    if (!_activeHasMore) return;

    setState(() => _isLoadingMore = true);

    if (_sortMode == CommentSortMode.hottest) {
      final result = await KugouApiClient()
          .getToplikedComments(_childrenId, page: _toplikedPage + 1);
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          if (result != null && result.comments.isNotEmpty) {
            // 「最热」接口跨页整体降序，逐页稳定重排只修正页内的个别倒挂
            // （高热度歌曲的排名快照会滞后于实时点赞数），不会打乱已读的顺序。
            _toplikedList.addAll(sortCommentsByHotness(result.comments));
            _toplikedPage++;
            _toplikedHasMore = result.comments.length >= 20;
          } else {
            _toplikedHasMore = false;
          }
        });
      }
      return;
    }

    final kugouProvider = context.read<KugouProvider>();
    final result = await kugouProvider.getComments(
      _effectiveHash,
      albumAudioId: _effectiveAlbumAudioId,
      page: _recentPage + 1,
    );
    if (mounted) {
      setState(() {
        _isLoadingMore = false;
        if (result != null && result.comments.isNotEmpty) {
          _recentList.addAll(result.comments);
          _recentPage++;
          _recentHasMore = result.comments.length >= 20;
        } else {
          _recentHasMore = false;
        }
      });
    }
  }

  // ---- 长评论展开/收起 ----

  bool _needsTruncate(String content) {
    return content.length > 120;
  }

  void _toggleContent(String id) {
    setState(() {
      if (_expandedContents.contains(id)) {
        _expandedContents.remove(id);
      } else {
        _expandedContents.add(id);
      }
    });
  }

  // ---- 楼层评论 ----

  _FloorState _getFloorState(String commentId) {
    return _floorStates.putIfAbsent(commentId, () => _FloorState());
  }

  Future<void> _fetchFloorReplies(
    KugouComment comment, {
    bool reset = false,
    bool silent = false,
  }) async {
    final state = _getFloorState(comment.id);
    if (state.loading) return;
    if (!state.hasMore && !reset) return;

    if (reset) {
      state.page = 1;
      state.replies = [];
      state.hasMore = true;
      state.message = '';
    }

    if (!silent) setState(() => state.loading = true);

    final specialId = comment.specialId ?? '';
    final tid = comment.tid ?? comment.id;
    final mixSongId = comment.mixSongId ?? _effectiveAlbumAudioId;

    if (specialId.isEmpty || tid.isEmpty) {
      state.message = '楼层评论暂不可用';
      state.hasMore = false;
      if (mounted) setState(() => state.loading = false);
      return;
    }

    try {
      final api = KugouApiClient();
      final result = await api.getFloorComments(
        specialId: specialId,
        tid: tid,
        mixSongId: mixSongId?.isNotEmpty == true ? mixSongId : null,
        code: comment.code,
        page: state.page,
        pagesize: _floorPageSize,
      );

      if (result != null) {
        final replies = result.comments;
        state.replies = reset ? replies : [...state.replies, ...replies];
        if (result.total > 0) state.total = result.total;
        // 不足一页即到底（翻过末页时上游连 list 字段都不返回）。
        // 只按 total 判断是不够的：被删除或风控过滤的回复取不到，
        // 那样「加载更多回复」会永远停不下来。
        state.hasMore = replies.length >= _floorPageSize &&
            (state.total <= 0 || state.replies.length < state.total);
        if (state.hasMore) state.page++;
        if (state.replies.isEmpty) {
          state.message = '暂无回复';
        }
      } else {
        state.message = '楼层评论暂不可用';
        state.hasMore = false;
      }
    } catch (_) {
      state.message = '加载失败，点击重试';
    } finally {
      state.initialized = true;
      if (mounted) {
        if (!silent) setState(() => state.loading = false);
      }
    }
  }

  /// 展开 / 收起楼中楼。
  ///
  /// tv: 展开后焦点**保持**在头部停点。回复是 [_fetchFloorReplies] 异步拉回的，
  /// 任何 requestFocus 都属于「异步内容抢焦点」（AGENTS §12.4 规则 7），且换焦点会
  /// 触发 dpad 的 ensureVisible，与收起路径的 [_scrollToCommentAfterCollapse] 抢同一套
  /// 滚动。按「下」即进入第一条回复，各回复尺寸正常、自然滚进视野。
  /// 同一份逻辑在 lib/widgets/playlist_comments_view.dart，改动需同步。
  void _toggleFloor(KugouComment comment) {
    final state = _getFloorState(comment.id);
    final wasExpanded = state.expanded;
    // 收起前记录评论项顶部相对视口的位置与滚动偏移，供收起后精确定位。
    // 此时楼中楼仍在展开、评论项通常未被懒加载回收，位置可可靠读取。
    // 用局部变量随本次收起一起传递，避免多个评论项收起时相互覆盖。
    final double? recorded = wasExpanded
        ? _commentTopInViewport(comment.id)
        : null;
    final double? beforeOffset =
        wasExpanded && _scrollController.hasClients
        ? _scrollController.offset
        : null;
    final int seq = wasExpanded ? ++_collapseScrollSeq : _collapseScrollSeq;
    setState(() {
      if (!state.expanded) {
        state.expanded = true;
        if (!state.initialized) {
          _fetchFloorReplies(comment, reset: true);
        }
      } else {
        state.expanded = false;
      }
    });
    // 收起楼中楼后，若楼主评论已超出视口则自然滚动回其位置
    if (wasExpanded && !state.expanded) {
      _scrollToCommentAfterCollapse(comment.id, seq, recorded, beforeOffset);
    }
  }

  /// 提交评论：无回复目标 → 歌曲顶层评论；有 → 该评论下的楼层回复。
  ///
  /// 成功不重试、不自动重发；失败保留输入内容由用户手动决定是否再发。
  Future<bool> _submitComment(String text) async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      if (mounted) await _promptLogin();
      return false;
    }

    final target = _replyTarget;
    setState(() => _sendingComment = true);
    try {
      final CommentSendResult result;
      if (target == null) {
        result = await api.sendSongComment(
          content: text,
          mixsongid: _effectiveAlbumAudioId,
          specialId: _childrenId.isEmpty ? null : _childrenId,
        );
      } else {
        final args = buildFloorReplyArgs(
          target,
          fallbackSpecialId: _childrenId.isEmpty ? null : _childrenId,
        );
        result = await api.sendFloorReply(
          specialId: args.specialId,
          tid: args.tid,
          content: text,
          resourceType: 'song',
          code: target.top.code,
          pid: args.pid,
          mixsongid: target.top.mixSongId ?? _effectiveAlbumAudioId,
          replyUserName: args.replyUserName,
          replyContent: args.replyContent,
        );
      }

      if (!mounted) return result.ok;
      if (result.ok) {
        setState(() => _replyTarget = null);
        if (target == null) {
          await _fetchComments(silent: true);
        } else {
          // 回复成功后把该楼层展开并重新拉取，便于立刻看到自己的回复
          _getFloorState(target.top.id).expanded = true;
          await _fetchFloorReplies(target.top, reset: true, silent: true);
        }
        if (mounted) showToast('评论已提交，审核通过后展示');
      } else {
        await handleCommentFailure(context, result);
      }
      return result.ok;
    } finally {
      if (mounted) setState(() => _sendingComment = false);
    }
  }

  /// 未登录时引导登录（与 channel_page 的既有交互保持一致）。
  Future<void> _promptLogin() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请先登录'),
        content: const Text('发表评论需要登录账号，是否前往登录？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('去登录')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await Navigator.of(context,
      rootNavigator: true,
    ).push(
      MaterialPageRoute(builder: (_) => const LoginPage()));
    if (mounted) setState(() {});
  }

  /// 长按删除自己的评论（顶层或楼中楼回复）。
  ///
  /// 流程：归属校验 → 确认弹窗 → 调用 /comment/music/del → 刷新。
  /// 不自动重试（删除成功不可撤销）；在途时忽略再次长按。
  Future<void> _deleteOwnComment(
    KugouComment comment, {
    KugouComment? floorRoot,
  }) async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;
    if (_deletingCommentIds.contains(comment.id)) return;

    final args = buildCommentDeleteArgs(
      comment: comment,
      floorRoot: floorRoot,
      resourceType: 'song',
      fallbackSpecialId: _childrenId.isEmpty ? null : _childrenId,
      mixsongid: _effectiveAlbumAudioId,
    );
    if (args == null) return;

    final errorColor = Theme.of(context).colorScheme.error;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除评论'),
        content: const Text('删除后无法恢复，确定要删除这条评论吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: errorColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingCommentIds.add(comment.id));
    try {
      final result = await api.deleteComment(
        cid: args.cid,
        specialId: args.specialId,
        mixsongid: args.mixsongid,
        tid: args.tid,
        resourceType: args.resourceType,
        code: args.code,
      );
      if (!mounted) return;
      if (result.ok) {
        showToast('评论已删除');
        if (floorRoot == null) {
          await _fetchComments(silent: true);
        } else {
          // 保持该楼层展开并重新拉取，列表里立刻看不到已删的回复
          _getFloorState(floorRoot.id).expanded = true;
          await _fetchFloorReplies(floorRoot, reset: true, silent: true);
        }
      } else {
        showToast(result.message, long: true);
      }
    } finally {
      if (mounted) setState(() => _deletingCommentIds.remove(comment.id));
    }
  }

  /// 计算评论项顶部相对视口顶部的偏移（负数表示在视口上方）。
  double? _commentTopInViewport(String commentId) {
    final rb = _keyForComment(commentId).currentContext?.findRenderObject();
    if (rb is! RenderBox || !rb.attached) return null;
    final viewport = RenderAbstractViewport.of(rb) as RenderBox;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    return rb.localToGlobal(Offset.zero).dy - viewportTop;
  }

  /// 切换排序：各排序的主列表与分页进度都已缓存，切换是即时操作
  /// （零请求、无淡出淡入）。首次进入某排序的数据在初始加载时就已就绪。
  void _onSortModeChanged(CommentSortMode mode) {
    if (mode == _sortMode) return;
    AppHaptics.selectionClick(HapticCategory.navigation);
    setState(() => _sortMode = mode);
  }

  /// 收起楼中楼后把视口自然滚动回楼主评论位置。
  ///
  /// 用收起前记录的评论项顶部位置计算目标滚动偏移（不依赖评论项是否仍
  /// 在 widget 树中），等待 [AnimatedSize] 收缩动画结束、布局稳定后滚动，
  /// 滚动后再校准，确保评论项顶部对齐视口顶部。
  /// [seq] 为本次收起操作的序号，异步期间若又有新的收起操作则放弃本次，
  /// 避免多个收起并发滚动互相干扰。
  Future<void> _scrollToCommentAfterCollapse(
    String commentId,
    int seq,
    double? recorded,
    double? beforeOffset,
  ) async {
    // 等待 AnimatedSize 收缩动画结束、布局稳定
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || seq != _collapseScrollSeq) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || seq != _collapseScrollSeq) return;
    final controller = _scrollController;
    if (!controller.hasClients) return;
    if (recorded == null || beforeOffset == null) return;
    // 评论项顶部已在视口内则不滚动
    if (recorded >= 0) return;
    // 评论项顶部在滚动内容中的位置（收起前后不变）
    final target = (beforeOffset + recorded)
        .clamp(0.0, controller.position.maxScrollExtent);
    // 滚动 + 校准：一次滚动可能因列表高度收缩没完全到位，滚动后再测量校准
    for (int attempt = 0; attempt < 3; attempt++) {
      if (seq != _collapseScrollSeq) return;
      if ((target - controller.offset).abs() < 1.0) break;
      await controller.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
  }

  // ---- 工具方法 ----

  String _formatLike(int value) {
    if (value < 10000) return value.toString();
    final fixed = (value / 10000).toStringAsFixed(value >= 100000 ? 0 : 1);
    return '${fixed.replaceAll(RegExp(r'\.0$'), '')}w';
  }

  String? _fixAvatarUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  /// 范围筛选变更。
  ///
  /// **同值守卫必须放在这里（读实时 [_scope]），不能放在
  /// [CommentSortFilterBar] 的闭包里**：换 [_scopeItems] 会让
  /// M3EDropdownMenu.didUpdateWidget 同步调 setItems → 立即回调
  /// onSelectionChange，而 controller 里注册的回调不会随 build 更新，
  /// 它捕获的仍是上一次 build 的 `scope` 旧值 —— 于是守卫失效，
  /// 在 build 期间走到 setState，命中
  /// 「setState() or markNeedsBuild() called during build」
  /// （2026-10-01 真机复现，整页被 ErrorWidget 顶掉）。
  /// 读实时字段则天然挡住这条回环。
  void _onScopeSelected(CommentScope scope) {
    if (scope == _scope) return;
    setState(() {
      _scope = scope;
      // 换新实例 → didUpdateWidget 触发 setItems，下拉框内部 controller
      // 的选中态随之同步，切回「全部评论」才不会被旧 selected 标记挡掉。
      _scopeItems = _buildScopeItems(scope);
    });
  }

  String _formatTime(int timestamp) {
    if (timestamp == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}.$month.$day';
  }

  /// 播放器评论 tab 没有内联输入框：右侧提供显式的「写评论」入口。
  bool get _showComposeButton =>
      !widget.showComposer && widget.onReplyComment != null;

  @override
  Widget build(BuildContext context) {
    // 排序选择器/写评论按钮常驻在外层：切换排序时列表淡出淡入，
    // 但入口控件不能跟着消失。
    return Column(
      children: [
        CommentSortFilterBar(
          sortMode: _sortMode,
          onSortModeChanged: _onSortModeChanged,
          scope: _scope,
          scopeItems: _scopeItems,
          onScopeChanged: _onScopeSelected,
          isAmStyle: widget.isAmStyle,
          showComposeButton: _showComposeButton,
          onCompose: () => widget.onReplyComment?.call(null),
        ),
        Expanded(
          child: _buildBody(),
        ),
      ],
    );
  }

  /// 评论区主体（加载/错误/空态与列表）。
  Widget _buildBody() {
    final display = context.watch<CommentDisplayProvider>();
    final commentFontSize = display.commentFontSize;
    final replyFontSize = display.commentReplyFontSize;

    final Color primaryTextColor;
    final Color secondaryTextColor;
    final Color usernameColor;

    if (widget.isAmStyle) {
      primaryTextColor = Colors.white;
      secondaryTextColor = const Color(0xB3FFFFFF);
      usernameColor = const Color(0xB3FFFFFF);
    } else {
      final colorScheme = Theme.of(context).colorScheme;
      primaryTextColor = colorScheme.onSurface;
      secondaryTextColor = colorScheme.onSurfaceVariant;
      usernameColor = colorScheme.primary;
    }

    // loading 指示器颜色：AM 风格保持白色，MD3 风格跟随莫奈色（primary）。
    final indicatorColor = widget.isAmStyle
        ? primaryTextColor
        : Theme.of(context).colorScheme.primary;

    if (_isLoading) {
      return Center(child: M3ELoadingIndicator(color: indicatorColor));
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: secondaryTextColor),
              const SizedBox(height: 12),
              Text(
                '加载评论失败',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: secondaryTextColor),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _fetchComments,
                style: TextButton.styleFrom(foregroundColor: primaryTextColor),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_activeList.isEmpty && _hotComments.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.comment_outlined, size: 48, color: secondaryTextColor),
            const SizedBox(height: 12),
            Text(
              // 本地歌曲未匹配在线歌曲时，评论无法定位到在线歌曲线程
              _isUnmatchedLocal ? '未匹配在线歌曲' : '暂无评论',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: secondaryTextColor),
            ),
            if (_isUnmatchedLocal) ...[
              const SizedBox(height: 4),
              Text(
                '在歌曲菜单「匹配在线信息」后可查看评论',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: secondaryTextColor,
                    ),
              ),
            ],
          ],
        ),
      );
    }

    // 构建显示列表：歌手评论 + 全部评论。
    // 主列表（最热/最新）里也可能带 isStar 的歌手评论，而「歌手评论」栏
    // 只来自 /comment/music 的 star_cmts/hot_list，不一定包含它（可能为空）。
    // 统一在此把主列表里的歌手评论补进「歌手评论」栏（按 id 去重），
    // 并从主列表移除，避免歌手评论重复或「歌手评论」栏空着。
    // 范围筛选：mine 只保留自己的评论、singer 只保留歌手评论（均为客户端过滤）
    final mine = _scope == CommentScope.mine;
    final singer = _scope == CommentScope.singer;
    final ownUserid = mine ? KugouApiClient().userid : null;
    final hotFromComments = mine
        ? const <KugouComment>[]
        : _activeList.where((c) => c.isStar).toList();
    // 「最热」= 原生 topliked 的点赞序；时间模式客户端按时间排
    final baseRegular = _sortMode == CommentSortMode.hottest
        ? _activeList.where((c) => !c.isStar).toList()
        : sortCommentsForDisplay(
            _activeList.where((c) => !c.isStar).toList(), _sortMode);
    final regularComments = mine
        ? baseRegular.where((c) => isOwnComment(c, ownUserid)).toList()
        : (singer ? const <KugouComment>[] : baseRegular);
    final mainSectionLabel = mine
        ? '我的评论'
        : switch (_sortMode) {
            CommentSortMode.hottest => '最热评论',
            CommentSortMode.timeDesc => '最新评论',
            CommentSortMode.timeAsc => '最早评论',
          };
    final starFromHot = _hotComments.where((c) => c.isStar).toSet();
    final singerComments = mine
        ? const <KugouComment>[]
        : <KugouComment>[
            ..._hotComments,
            for (final c in hotFromComments)
              if (!starFromHot.any((s) => s.id == c.id)) c,
          ];

    // 筛选下没有任何自己的评论：给可操作的提示（而不是空列表 + 加载更多）
    if (mine && regularComments.isEmpty) {
      final loggedIn = KugouApiClient().isLoggedIn;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.person_outline, size: 48, color: secondaryTextColor),
              const SizedBox(height: 12),
              Text(
                loggedIn ? '暂无你的评论' : '登录后可查看自己的评论',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: secondaryTextColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '仅筛选已加载的 ${_activeList.length} 条评论，可通过「加载更多」继续查找',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: secondaryTextColor.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // 「歌手」下没有歌手评论
    if (singer && singerComments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.star_outline, size: 48, color: secondaryTextColor),
              const SizedBox(height: 12),
              Text(
                '暂无歌手评论',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: secondaryTextColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final displayItems = <_CommentDisplayItem>[];

    if (singerComments.isNotEmpty) {
      displayItems.add(_CommentDisplayItem.header('歌手评论'));
      for (final c in singerComments) {
        displayItems.add(_CommentDisplayItem.comment(c));
      }
    }
    if (regularComments.isNotEmpty) {
      displayItems.add(_CommentDisplayItem.header(mainSectionLabel));
      for (final c in regularComments) {
        displayItems.add(_CommentDisplayItem.comment(c));
      }
    }

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: ShaderMask(
                shaderCallback: (Rect bounds) {
                  const double fadeHeight = 24.0;
                  final double fadeRatio = (fadeHeight / bounds.height).clamp(0.0, 0.5);
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: [0.0, fadeRatio, 1.0 - fadeRatio, 1.0],
                  ).createShader(bounds);
                },
                blendMode: BlendMode.dstIn,
                child: Md3PullToRefresh(
                  onRefresh: () => _fetchComments(silent: true),
                  child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8,
                    ),
                  itemCount: displayItems.length + (_activeHasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == displayItems.length) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: _isLoadingMore
                              ? M3ELoadingIndicator(
                                  constraints: BoxConstraints.tightFor(width: 24, height: 24,
                                    ),
                                  color: indicatorColor,
                                  )
                              : TextButton(
                                  onPressed: _loadMore,
                                  style: TextButton.styleFrom(
                                    foregroundColor: primaryTextColor,
                                  ),
                                  child: const Text('加载更多'),
                                ),
                        ),
                      );
                    }

                    final item = displayItems[index];
                    if (item.isHeader) {
                      return _buildSectionHeader(item.headerTitle!, primaryTextColor,
                        );
                    }
                    return _buildCommentItem(
                      item.comment!,
                      primaryTextColor,
                      secondaryTextColor,
                      usernameColor,
                      commentFontSize,
                      replyFontSize,
                    );
                  },
                ),
                  ),
              ),
            ),
            // 输入框内联在列表下方并常驻（showComposer=false 时整块不存在）
            if (widget.showComposer) _buildComposer(),
          ],
        ),
      ],
    );
  }

  /// 评论输入框。半透明背景能透出播放器的模糊封面（用户要求的观感）。
  Widget _buildComposer() {
    return CommentComposer(
      sending: _sendingComment,
      // 评论弹层不会随键盘上移，输入框必须自己避让，否则被输入法遮挡
      avoidKeyboard: true,
      replyToName: _replyTarget?.displayName,
      onCancelReply: () => setState(() => _replyTarget = null),
      isAmStyle: widget.isAmStyle,
      onSubmit: _submitComment,
    );
  }

  Widget _buildSectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildCommentItem(
    KugouComment comment,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
    double commentFontSize,
    double replyFontSize,
  ) {
    final floorState = _floorStates[comment.id];
    final head = _commentHeadChildren(
      comment,
      floorState,
      primaryTextColor,
      secondaryTextColor,
      usernameColor,
      commentFontSize,
    );
    final floorBody = _commentFloorBody(
      comment,
      floorState,
      primaryTextColor,
      secondaryTextColor,
      usernameColor,
      replyFontSize,
    );
    final isOwn = isOwnComment(comment, KugouApiClient().userid);
    // 卡片动作：有楼中楼就展开/收起，无回复时长文展开/收起（与拆分前同一判据）
    final VoidCallback? toggle = comment.replyCount > 0
        ? () => _toggleFloor(comment)
        : (_needsTruncate(comment.content)
              ? () => _toggleContent(comment.id)
              : null);

    // tv: 楼中楼必须从卡片停点里拆出来。整卡当停点时，焦点矩形＝展开后的真实高度
    // （可达数屏），dpad 的 DpadScroll.ensureVisible 对超视口目标走「居中」分支并被
    // clamp 到 maxScrollExtent → 展开即跳列表最底；同时未裁切的巨高矩形让「下」方向
    // 的候选判定永不把卡内回复当候选，而卡内一切又都在 ExcludeFocus 里
    // （「加载更多回复」不可达）。
    // 拆分后：头部一个停点 + 每条回复一个停点 + 加载更多回复停点，尺寸正常，自然滚动回归。
    // 卡内图片九宫格/点赞行小控件在 TV 上仍不是独立停点（纯手势点触目标）。
    final Widget contentColumn = kTvBuild
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DpadFocusable(
                debugLabel: 'tv/comment-head-${comment.id}',
                onSelect: toggle,
                onLongSelect: isOwn
                    ? () {
                        AppHaptics.mediumImpact(HapticCategory.listItem);
                        _deleteOwnComment(comment);
                      }
                    : null,
                // SizedBox(width: double.infinity) 把头部宽度钉回外层列宽；
                // 内层 Column 必须显式 start，默认 center 会让正文整体右移。
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: head,
                  ),
                ),
              ),
              floorBody,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [...head, floorBody],
          );

    // key 继续挂在整项 Padding 上（不要下沉到头部）：_commentTopInViewport 量的
    // 是整项顶部相对视口的位置，_scrollToCommentAfterCollapse 靠它收起后回位。
    final Widget item = Padding(
      key: _keyForComment(comment.id),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAvatar(comment, usernameColor),
          const SizedBox(width: 12),
          Expanded(child: contentColumn),
        ],
      ),
    );

    // 手机侧本人评论的长按删除仍包在整卡上（与拆分前逐字一致）；TV 已接到头部停点
    if (isOwn && !kTvBuild) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: () {
          AppHaptics.mediumImpact(HapticCategory.listItem);
          _deleteOwnComment(comment);
        },
        child: item,
      );
    }
    return item;
  }

  /// 评论卡「头部」子项（用户名/正文/图片/点赞回复行），**不含楼中楼**。
  ///
  /// 单一事实来源：手机侧把这份 List 和楼中楼直接平铺进外层 Column（与拆分前
  /// 逐层等价），TV 侧只把这份 List 包进头部停点。两条装配路径共用同一份，
  /// 避免评论正文写两遍日后走样。
  /// 同一份逻辑在 lib/widgets/playlist_comments_view.dart，改动需同步。
  List<Widget> _commentHeadChildren(
    KugouComment comment,
    _FloorState? floorState,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
    double commentFontSize,
  ) {
    return [
      // 用户名 + 徽章 + 时间
      Row(
        children: [
          Flexible(
            child: Text(
              comment.username,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(
                    color: usernameColor,
                    fontWeight: FontWeight.w500,
                  ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (comment.isStar) ...[
            const SizedBox(width: 6),
            _buildBadge('歌手', usernameColor),
          ],
          if (comment.isHot) ...[
            const SizedBox(width: 6),
            _buildBadge('热门', usernameColor),
          ],
          const SizedBox(width: 8),
          Text(
            _formatTime(comment.time),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: secondaryTextColor.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      // 评论内容（长评论展开/收起，带动画）
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        alignment: Alignment.topLeft,
        child: _buildContent(
          comment,
          primaryTextColor,
          secondaryTextColor,
          commentFontSize,
        ),
      ),
      if (comment.images.isNotEmpty) ...[
        const SizedBox(height: 6),
        CommentImageGrid(
          images: comment.images,
          onTapImage: (index, originRect) => showCommentImageViewer(
            context,
            images: comment.images,
            initialIndex: index,
            originRect: originRect,
          ),
        ),
      ],
      // 点赞 + 回复
      const SizedBox(height: 6),
      Row(
        children: [
          if (comment.likes > 0) ...[
            Icon(
              Icons.thumb_up_outlined,
              size: 12,
              color: secondaryTextColor.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 4),
            Text(
              _formatLike(comment.likes),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: secondaryTextColor.withValues(alpha: 0.5),
              ),
            ),
          ],
          // 回复按钮
          if (comment.replyCount > 0) ...[
            const SizedBox(width: 16),
            GestureDetector(
              onTap: () => _toggleFloor(comment),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: floorState?.expanded == true ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      size: 14,
                      color: usernameColor,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    floorState?.expanded == true
                        ? '收起回复'
                        : '查看${comment.replyCount}条回复',
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: usernameColor),
                  ),
                ],
              ),
            ),
          ],
          if (widget.showComposer || widget.onReplyComment != null)
            const SizedBox(width: 16),
          if (widget.showComposer || widget.onReplyComment != null)
            GestureDetector(
            onTap: () => _beginReply(CommentReplyTarget(top: comment)),
            child: Row(
              children: [
                Icon(Icons.reply, size: 14, color: usernameColor),
                const SizedBox(width: 4),
                Text(
                  '回复',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: usernameColor),
                ),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  /// 楼层评论（楼中楼，带展开动画 + 左侧竖条收纳把手），**不含评论卡头部**。
  ///
  /// 与 [_commentHeadChildren] 配对，两条装配路径共用同一份。
  /// 同一份逻辑在 lib/widgets/playlist_comments_view.dart，改动需同步。
  Widget _commentFloorBody(
    KugouComment comment,
    _FloorState? floorState,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
    double replyFontSize,
  ) {
    // 楼层评论（带展开动画）
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topLeft,
      child: floorState?.expanded == true
          // 左侧竖条收纳按钮 + 楼中楼内容
          ? IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildFloorCollapseHandle(
                    onTap: () => _toggleFloor(comment),
                    lineColor: secondaryTextColor.withValues(
                      alpha: 0.28,
                    ),
                    iconColor: usernameColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildFloorReplies(
                      comment,
                      floorState!,
                      primaryTextColor,
                      secondaryTextColor,
                      usernameColor,
                      replyFontSize,
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  /// 进入「回复这条评论」模式：触屏点按与 TV 停点共用这一份，
  /// 保证 TV 不砍掉任何既有能力。
  ///
  /// 同一份逻辑在 lib/widgets/playlist_comments_view.dart，改动需同步。
  void _beginReply(CommentReplyTarget target) {
    AppHaptics.selectionClick(HapticCategory.listItem);
    if (widget.showComposer) {
      // 托盘/弹层里输入框常驻：就地进入回复模式
      setState(() => _replyTarget = target);
    } else {
      // 播放器评论 tab 没有输入框：弹出仅输入框的托盘去回复
      widget.onReplyComment?.call(target);
    }
  }

  Widget _buildContent(
    KugouComment comment,
    Color primaryTextColor,
    Color secondaryTextColor,
    double fontSize,
  ) {
    final content = comment.content;
    if (!_needsTruncate(content) || _expandedContents.contains(comment.id)) {
      return RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: content,
              // 必须从主题派生 fontFamily：裸 TextStyle 会让 RichText 走引擎
              // 默认字体，绕过全局字体设置（与 playlist_comments_view 同口径）。
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: primaryTextColor,
                height: 1.4,
                fontSize: fontSize,
              ),
            ),
            if (_needsTruncate(content) &&
                _expandedContents.contains(comment.id))
              WidgetSpan(
                child: GestureDetector(
                  onTap: () => _toggleContent(comment.id),
                  child: Text(
                    ' 收起',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: secondaryTextColor),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '${content.substring(0, 120)}...',
            // 同 _buildContent 另一分支：从主题派生 fontFamily，跟随全局字体。
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: primaryTextColor,
              height: 1.4,
              fontSize: fontSize,
            ),
          ),
          WidgetSpan(
            child: GestureDetector(
              onTap: () => _toggleContent(comment.id),
              child: Text(
                '展开',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: secondaryTextColor),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 楼中楼左侧的竖条收纳按钮。
  ///
  /// 一条与楼中楼等高的竖线 + 底部向上箭头，整条可点击收起楼中楼，
  /// 方便在楼中楼较长时无需滚回顶部即可收纳。仅在展开楼中楼时渲染。
  ///
  /// tv: 不适用（竖条收纳把手是纯手势命中区）；TV 收起走头部停点的
  /// onSelect（同一 [_toggleFloor] 入口），功能未少。
  /// 同一份逻辑在 lib/widgets/playlist_comments_view.dart，改动需同步。
  Widget _buildFloorCollapseHandle({
    required VoidCallback onTap,
    required Color lineColor,
    required Color iconColor,
  }) {
    return Semantics(
      button: true,
      label: '收起回复',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 20,
          child: Column(
            children: [
              // 顶部圆点：与右侧楼中楼矩形顶部（margin top 10）对齐
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: lineColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              // 竖线：从圆点下方延伸到楼中楼底部
              Expanded(
                child: Container(
                  width: 2,
                  margin: const EdgeInsets.only(top: 3),
                  decoration: BoxDecoration(
                    color: lineColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              // 底部收纳图标
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(
                  Icons.keyboard_arrow_up,
                  size: 16,
                  color: iconColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFloorReplies(
    KugouComment comment,
    _FloorState state,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
    double replyFontSize,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: secondaryTextColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 回复列表：按 pid 嵌套，同层按时间倒序（新的在前）
          for (final node in buildReplyTree(state.replies))
            _buildFloorReplyItem(
              comment,
              node,
              primaryTextColor,
              secondaryTextColor,
              usernameColor,
              replyFontSize,
            ),
          // 加载中
          if (state.loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: M3ELoadingIndicator(
                    constraints: BoxConstraints.tightFor(width: 16, height: 16),
                    color: usernameColor),
              ),
            ),
          // 空状态
          if (!state.loading && state.initialized && state.replies.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  state.message.isNotEmpty ? state.message : '暂无回复',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: secondaryTextColor),
                ),
              ),
            ),
          // 加载更多
          if (state.hasMore && !state.loading && state.replies.isNotEmpty)
            Center(
              // tv: TV 构建下「加载更多回复」单停点（GestureDetector 不可聚焦；
              // OK=加载下一页楼中楼）
              child: kTvBuild
                  ? DpadFocusable(
                      debugLabel: 'tv/comment-floor-more-${comment.id}',
                      onSelect: () => _fetchFloorReplies(comment),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          state.message.contains('失败') ? '加载失败，点击重试' : '加载更多回复',
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: usernameColor),
                        ),
                      ),
                    )
                  : GestureDetector(
                      onTap: () => _fetchFloorReplies(comment),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          state.message.contains('失败') ? '加载失败，点击重试' : '加载更多回复',
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: usernameColor),
                        ),
                      ),
                    ),
            ),
          // 全部加载完
          if (!state.hasMore && !state.loading && state.replies.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '已加载全部回复',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: secondaryTextColor.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 楼中楼嵌套的每级缩进量与最大缩进级数。
  ///
  /// 层级很深时继续缩进会把正文挤成窄条，超过 [_maxReplyIndentDepth] 级后
  /// 不再增加缩进，只靠排列顺序体现从属关系。
  static const double _replyIndentPerDepth = 16.0;
  static const int _maxReplyIndentDepth = 4;

  Widget _buildFloorReplyItem(
    KugouComment top,
    CommentReplyNode node,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
    double fontSize,
  ) {
    final reply = node.reply;
    // 嵌套渲染后被回复的那条就在上方，引用后缀是重复信息；父级不在已加载数据
    // 里（孤儿）时保留原文，否则看不出在回复谁。
    final content = node.isOrphan
        ? reply.content
        : stripReplyQuote(reply.content);
    final Widget item = Padding(
      padding: EdgeInsets.only(
        top: 6,
        bottom: 6,
        left:
            node.depth.clamp(0, _maxReplyIndentDepth) * _replyIndentPerDepth,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSmallAvatar(reply, usernameColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        reply.username,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: usernameColor,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _formatTime(reply.time),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: secondaryTextColor.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  content,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: primaryTextColor,
                    height: 1.3,
                    fontSize: fontSize,
                  ),
                ),
                if (reply.images.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  CommentImageGrid(
                    images: reply.images,
                    onTapImage: (index, originRect) => showCommentImageViewer(
                      context,
                      images: reply.images,
                      initialIndex: index,
                      originRect: originRect,
                    ),
                  ),
                ],
                // 楼中楼：回复某条具体回复（pid=该回复，is_t=0）
                const SizedBox(height: 2),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _beginReply(CommentReplyTarget(top: top, reply: reply)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.reply, size: 12, color: usernameColor),
                      const SizedBox(width: 3),
                      Text(
                        '回复',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: usernameColor,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final isOwn = isOwnComment(reply, KugouApiClient().userid);
    // tv: 每条回复各自一个停点。onSelect＝触屏那条「回复」按钮的同一动作（_beginReply），
    // 本人回复把长按删除接 onLongSelect——dpad 里给了 onLongSelect 时 onSelect 改在松手触发，
    // 两者永不重叠，与卡片头部停点同一口径。卡内图片九宫格在 TV 仍不是停点：
    // tv: 不适用（图片查看依赖拖动/双指缩放，遥控无等价语义）。
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'tv/comment-reply-${reply.id}',
        onSelect: () => _beginReply(CommentReplyTarget(top: top, reply: reply)),
        onLongSelect: isOwn
            ? () {
                AppHaptics.mediumImpact(HapticCategory.listItem);
                _deleteOwnComment(reply, floorRoot: top);
              }
            : null,
        child: item,
      );
    }
    // 自己的回复支持长按删除；非本人回复不响应长按
    if (!isOwn) return item;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () {
        AppHaptics.mediumImpact(HapticCategory.listItem);
        _deleteOwnComment(reply, floorRoot: top);
      },
      child: item,
    );
  }

  Widget _buildAvatar(KugouComment comment, Color usernameColor) {
    final avatarUrl = _fixAvatarUrl(comment.avatar);
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 18,
        backgroundColor: usernameColor.withValues(alpha: 0.15),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: avatarUrl,
            memCacheWidth: 108,
            memCacheHeight: 108,
            width: 36,
            height: 36,
            fit: BoxFit.cover,
            placeholder: (_, _) => _buildTextAvatar(comment, usernameColor),
            errorWidget: (_, _, _) => _buildTextAvatar(comment, usernameColor),
          ),
        ),
      );
    }
    return _buildTextAvatar(comment, usernameColor);
  }

  Widget _buildSmallAvatar(KugouComment comment, Color usernameColor) {
    final avatarUrl = _fixAvatarUrl(comment.avatar);
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 12,
        backgroundColor: usernameColor.withValues(alpha: 0.15),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: avatarUrl,
            memCacheWidth: 72,
            memCacheHeight: 72,
            width: 24,
            height: 24,
            fit: BoxFit.cover,
            placeholder: (_, _) =>
                _buildSmallTextAvatar(comment, usernameColor),
            errorWidget: (_, _, _) =>
                _buildSmallTextAvatar(comment, usernameColor),
          ),
        ),
      );
    }
    return _buildSmallTextAvatar(comment, usernameColor);
  }

  Widget _buildTextAvatar(KugouComment comment, Color usernameColor) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: usernameColor.withValues(alpha: 0.15),
      child: Text(
        comment.username.isNotEmpty ? comment.username[0] : '?',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: usernameColor),
      ),
    );
  }

  Widget _buildSmallTextAvatar(KugouComment comment, Color usernameColor) {
    return CircleAvatar(
      radius: 12,
      backgroundColor: usernameColor.withValues(alpha: 0.15),
      child: Text(
        comment.username.isNotEmpty ? comment.username[0] : '?',
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: usernameColor, fontSize: 11),
      ),
    );
  }
}

/// 显示列表项（header 或 comment）
class _CommentDisplayItem {
  final String? headerTitle;
  final KugouComment? comment;

  bool get isHeader => headerTitle != null;

  _CommentDisplayItem.header(this.headerTitle) : comment = null;
  _CommentDisplayItem.comment(this.comment) : headerTitle = null;
}
