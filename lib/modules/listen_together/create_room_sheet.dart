import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_toast.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/listen_together_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/listen_together_api.dart';

/// 创建众乐房托盘。
///
/// 返回 true 表示创建成功（调用方负责关闭托盘并跳转房间页）。
/// 房间需要至少一首初始歌曲：默认取当前播放队列前 30 首。
class CreateRoomSheet extends StatefulWidget {
  const CreateRoomSheet({super.key});

  @override
  State<CreateRoomSheet> createState() => _CreateRoomSheetState();
}

class _CreateRoomSheetState extends State<CreateRoomSheet> {
  final _nameCtrl = TextEditingController();
  int _capacity = 5;

  /// 房型下标：0 = 私密房（凭房间号进入），1 = 公开房。
  /// 上游 room_privacy：1 = 公开，2 = 私密。
  int _privacyIndex = 0;
  bool _submitting = false;
  String? _error;

  int get _roomPrivacy => _privacyIndex == 1 ? 1 : 2;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入房间名称');
      return;
    }
    final playerProvider = context.read<PlayerProvider>();
    if (playerProvider.playlist.isEmpty) {
      setState(() => _error = '请先播放任意歌曲，用当前队列作为房间初始歌单');
      return;
    }
    // 本地音乐没有可上报上游的 hash：房间歌单建不起来，提前给出可操作的原因，
    // 不要把「服务端未返回新房间 ID」之类的内部错误丢给用户
    final audios = roomAudioPayload(roomAudiosFromPlaylist(playerProvider.playlist));
    if (audios.isEmpty) {
      setState(() => _error = '当前播放队列里只有本地音乐，本机文件无法加入房间歌单；请先播放任意在线歌曲');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });

    final lt = context.read<ListenTogetherProvider>();
    final account = context.read<KugouProvider>();
    try {
      final ok = await lt.createAndEnter(
        roomName: name,
        roomPrivacy: _roomPrivacy,
        capacity: _capacity,
        initialAudios: audios,
        player: playerProvider,
        account: account,
      );
      if (!mounted) return;
      if (ok) {
        showToast('「$name」已创建');
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = '创建失败，请稍后重试');
      }
    } on ListenTogetherApiError catch (e) {
      // 上游已给出可读文案时原样展示，仅在文案缺失/纯技术串时回退到错误码映射
      if (mounted) {
        setState(() => _error = listenTogetherErrorText(e));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '创建失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final player = context.watch<PlayerProvider>();
    final isPrivate = _privacyIndex == 0;
    // 只统计可上报的在线曲目：队列里混着本地音乐时如实告知实际入房数量
    final usableCount = roomAudiosFromPlaylist(player.playlist).length;
    final localCount = player.playlist.length - usableCount;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                '创建众乐房',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _nameCtrl,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: '房间名称',
                  hintText: '例如：深夜一起听歌',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              // 与设置页「主题模式」同款二选一控件（含相邻按钮挤压动画）
              child: Center(
                child: M3EToggleButtonGroup(
                  actions: const [
                    M3EToggleButtonGroupAction(
                      label: Text('私密房'),
                      icon: Icon(Icons.lock_outline),
                    ),
                    M3EToggleButtonGroupAction(
                      label: Text('公开房'),
                      icon: Icon(Icons.public),
                    ),
                  ],
                  selectedIndex: _privacyIndex,
                  onSelectedIndexChanged: (index) {
                    if (index == null) return;
                    setState(() => _privacyIndex = index);
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                isPrivate
                    ? '私密房：仅凭房间号进入，可设置人数上限'
                    : '公开房：会出现在广场列表中，人数由服务端管理',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            // 人数上限仅对私密房生效（公开房由服务端管理人数）
            if (isPrivate)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  children: [
                    Text('人数上限', style: TextStyle(color: cs.onSurfaceVariant)),
                    Expanded(
                      child: M3ESlider(
                        value: _capacity.toDouble(),
                        min: 2,
                        max: 10,
                        divisions: 8,
                        label: '$_capacity 人',
                        onChanged: (v) => setState(() => _capacity = v.toInt()),
                        // 离散档位自带触觉反馈（M3ESlider 在 divisions 非 null
                        // 时按档位触发），无需额外 haptic 配置
                      ),
                    ),
                    Text('$_capacity 人'),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '房间歌单将使用当前播放队列中的在线歌曲'
                '（${usableCount > 30 ? 30 : usableCount} 首，最多取 30 首）'
                '${localCount > 0 ? '，另有 $localCount 首本地音乐不会加入' : ''}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
              ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('创建并进入'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
