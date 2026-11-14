import '../../core/layout/page_layout.dart';
import '../../core/utils/app_text_context_menu.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../player/car_mode_panel.dart';
import '../../services/kugou_api/kugou_models.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with CarModePanelSuppressor<LoginPage> {
  Timer? _checkTimer;
  bool _pollInFlight = false;
  String _statusText = '正在生成二维码...';

  /// 0=酷狗扫码 1=手机 2=微信 3=QQ
  int _tabIndex = 0;

  /// 二维码会话代次：切 Tab / 刷新时自增，迟到的异步响应据此丢弃。
  int _qrGeneration = 0;

  // 手机登录表单
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();
  bool _sendingCode = false;
  bool _loggingIn = false;
  int _countdown = 0;
  Timer? _countdownTimer;

  // 微信 / QQ 扫码会话
  KugouWxQrSession? _wxSession;
  KugouQqQrSession? _qqSession;

  @override
  void initState() {
    super.initState();
    // 验证码输满 6 位后自动尝试登录
    _codeCtrl.addListener(_onCodeChanged);
    // 本页不显示车机模式常驻播放器面板
    suppressCarModePanel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initLogin();
    });
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _countdownTimer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _codeFocus.dispose();
    releaseCarModePanel();
    super.dispose();
  }

  void _switchTab(int idx) {
    if (_tabIndex == idx) return;
    _stopPolling();
    _qrGeneration++;
    _countdownTimer?.cancel();
    _countdown = 0;
    setState(() {
      _tabIndex = idx;
      _phoneCtrl.clear();
      _codeCtrl.clear();
      _wxSession = null;
      _qqSession = null;
    });
    _initLogin();
  }

  /// 停掉轮询并复位「在途」标记（切 Tab / 刷新二维码 / 页面关闭都走这里）。
  void _stopPolling() {
    _checkTimer?.cancel();
    _checkTimer = null;
    _pollInFlight = false;
  }

  Future<void> _initLogin() async {
    final generation = _qrGeneration;
    switch (_tabIndex) {
      case 0:
        await _initKugouQr(generation);
      case 2:
        await _initWxLogin(generation);
      case 3:
        await _initQqLogin(generation);
      default:
        if (!mounted) return;
        setState(() {
          _statusText = '请输入手机号获取验证码';
        });
    }
  }

  Future<void> _initKugouQr(int generation) async {
    final kugouProvider = context.read<KugouProvider>();
    await kugouProvider.generateQrCode();
    if (!mounted || generation != _qrGeneration || _tabIndex != 0) return;
    setState(() {
      _statusText = '请使用酷狗音乐 App 扫码登录';
    });
    _startKugouCheck(generation);
  }

  Future<void> _initWxLogin(int generation) async {
    final kugouProvider = context.read<KugouProvider>();
    if (!mounted || generation != _qrGeneration) return;
    setState(() {
      _statusText = '正在生成微信二维码...';
    });
    final session = await kugouProvider.createWxLoginQr();
    if (!mounted || generation != _qrGeneration || _tabIndex != 2) return;
    setState(() {
      _wxSession = session;
      _statusText = session == null
          ? (kugouProvider.error ?? '生成微信二维码失败')
          : '请使用微信扫一扫';
    });
    if (session != null) _startWxCheck(generation, session);
  }

  Future<void> _initQqLogin(int generation) async {
    final kugouProvider = context.read<KugouProvider>();
    if (!mounted || generation != _qrGeneration) return;
    setState(() {
      _statusText = '正在生成 QQ 二维码...';
    });
    final session = await kugouProvider.createQqLoginQr();
    if (!mounted || generation != _qrGeneration || _tabIndex != 3) return;
    setState(() {
      _qqSession = session;
      _statusText = session == null
          ? (kugouProvider.error ?? '生成 QQ 二维码失败')
          : '请使用手机 QQ 扫一扫';
    });
    if (session != null) _startQqCheck(generation, session);
  }

  /// 统一的 2s 轮询骨架：负责代次守卫、在途去重与异常兜底。
  ///
  /// [tick] 返回 true 表示继续轮询；false 表示已到终态（成功/过期/被拦截）。
  void _startPolling(int generation, Future<bool> Function() tick) {
    _stopPolling();
    _checkTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted || generation != _qrGeneration) {
        timer.cancel();
        return;
      }
      if (_pollInFlight) return;
      _pollInFlight = true;
      try {
        final keepGoing = await tick();
        if (!keepGoing) timer.cancel();
      } catch (e) {
        timer.cancel();
        if (mounted && generation == _qrGeneration) {
          setState(() {
            _statusText = '扫码状态检查失败，请刷新二维码';
          });
        }
      } finally {
        _pollInFlight = false;
      }
    });
  }

  void _startKugouCheck(int generation) {
    final kugouProvider = context.read<KugouProvider>();
    _startPolling(generation, () async {
      final status = await kugouProvider.checkQrCode();
      if (!mounted || generation != _qrGeneration) return false;
      if (status == null) {
        if (kugouProvider.error != null) {
          setState(() => _statusText = kugouProvider.error!);
        }
        return true;
      }
      if (status == 4) {
        await _onLoginSuccess();
        return false;
      }
      if (status == 800 || status == 0) {
        setState(() => _statusText = '二维码已过期，请刷新重试');
        return false;
      }
      if (status == 2 || status == 803) {
        setState(() => _statusText = '已扫码，请在手机上确认登录');
      } else if (status == 1) {
        setState(() => _statusText = '等待扫码...');
      }
      return true;
    });
  }

  void _startWxCheck(int generation, KugouWxQrSession session) {
    final kugouProvider = context.read<KugouProvider>();
    _startPolling(generation, () async {
      final result = await kugouProvider.checkWxLogin(session.uuid);
      if (!mounted || generation != _qrGeneration) return false;
      switch (result.kind) {
        case WxScanKind.success:
          final ok = await kugouProvider.completeThirdPartyLogin(
            token: result.token!,
            userid: result.userid!,
            vipToken: result.vipToken,
          );
          if (!ok) {
            if (mounted) {
              setState(() => _statusText = kugouProvider.error ?? '微信登录失败');
            }
            return false;
          }
          await _onLoginSuccess();
          return false;
        case WxScanKind.expired:
        case WxScanKind.rejected:
          setState(() => _statusText = result.message ?? '微信登录已结束');
          return false;
        case WxScanKind.error:
          setState(() => _statusText = result.message ?? '微信登录失败，请重试');
          return false;
        case WxScanKind.waiting:
        case WxScanKind.scanned:
          setState(() => _statusText = result.message ?? '等待扫描...');
          return true;
      }
    });
  }

  void _startQqCheck(int generation, KugouQqQrSession session) {
    final kugouProvider = context.read<KugouProvider>();
    _startPolling(generation, () async {
      final result = await kugouProvider.checkQqLogin(session);
      if (!mounted || generation != _qrGeneration) return false;
      switch (result.kind) {
        case QqScanKind.success:
          final ok = await kugouProvider.completeThirdPartyLogin(
            token: result.token!,
            userid: result.userid!,
            vipToken: result.vipToken,
          );
          if (!ok) {
            if (mounted) {
              setState(() => _statusText = kugouProvider.error ?? 'QQ 登录失败');
            }
            return false;
          }
          await _onLoginSuccess();
          return false;
        case QqScanKind.expired:
          setState(() => _statusText = result.message ?? '二维码已失效，请刷新');
          return false;
        case QqScanKind.blocked:
          // 风控拦截：明确告知且不自动重试（重试只会持续打上游）。
          setState(() => _statusText = result.message ?? 'QQ 扫码接口暂时不可用');
          return false;
        case QqScanKind.error:
          setState(() => _statusText = result.message ?? 'QQ 登录失败，请重试');
          return false;
        case QqScanKind.waiting:
        case QqScanKind.scanned:
          setState(() => _statusText = result.message ?? '等待 QQ 扫码...');
          return true;
      }
    });
  }

  Future<void> _refreshQrCode() async {
    _stopPolling();
    _qrGeneration++;
    final generation = _qrGeneration;
    setState(() {
      _statusText = '正在刷新二维码...';
    });
    await _initLogin();
    if (!mounted || generation != _qrGeneration) return;
  }

  Uint8List? _decodeBase64Image(String? base64Str) {
    if (base64Str == null || base64Str.isEmpty) return null;
    try {
      String data = base64Str;
      if (data.startsWith('data:image')) {
        final commaIndex = data.indexOf(',');
        if (commaIndex != -1) {
          data = data.substring(commaIndex + 1);
        }
      }
      return base64Decode(data);
    } catch (e) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('登录酷狗音乐')),
      body: ContentWidth(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Tab 切换：只放 label 不放 icon —— 四个「图标+文字」在 360dp
                // 窄屏会溢出成横向滚动，纯文字约 256dp 可一屏放下。
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: M3EToggleButtonGroup(
                    actions: const [
                      M3EToggleButtonGroupAction(label: Text('酷狗')),
                      M3EToggleButtonGroupAction(label: Text('手机')),
                      M3EToggleButtonGroupAction(label: Text('微信')),
                      M3EToggleButtonGroupAction(label: Text('QQ')),
                    ],
                    selectedIndex: _tabIndex,
                    onSelectedIndexChanged: (index) {
                      if (index != null) _switchTab(index);
                    },
                  ),
                ),
                const SizedBox(height: 16),
                if (_tabIndex == 0) _buildQrTab(colorScheme, textTheme),
                if (_tabIndex == 1) _buildPhoneTab(colorScheme, textTheme),
                if (_tabIndex == 2) _buildWxTab(colorScheme, textTheme),
                if (_tabIndex == 3) _buildQqTab(colorScheme, textTheme),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _statusText,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_tabIndex == 3) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'QQ 扫码受上游风控影响时可能不可用，可改用微信或酷狗扫码',
                      textAlign: TextAlign.center,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQrTab(ColorScheme colorScheme, TextTheme textTheme) {
    return Consumer<KugouProvider>(
      builder: (context, kugouProvider, child) {
        final qrData = kugouProvider.qrData;
        final qrImgBase64 = qrData?.base64;
        final qrKeyImg = kugouProvider.qrKey?.qrcodeImg;
        final qrImgBytes = _decodeBase64Image(qrImgBase64);
        return _loginCard(
          colorScheme,
          Column(
            children: [
              _qrFrame(
                colorScheme,
                qrImgBytes != null
                    ? Image.memory(qrImgBytes, fit: BoxFit.cover)
                    : qrKeyImg != null
                    ? Image.network(
                        qrKeyImg,
                        fit: BoxFit.cover,
                        frameBuilder:
                            (context, child, frame, wasSynchronouslyLoaded) {
                              if (wasSynchronouslyLoaded) return child;
                              return AnimatedOpacity(
                                opacity: frame == null ? 0 : 1,
                                duration: const Duration(milliseconds: 200),
                                child: child,
                              );
                            },
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(
                            child: Icon(Icons.qr_code, size: 80),
                          );
                        },
                      )
                    : const Center(child: M3ELoadingIndicator()),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _refreshQrCode,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新二维码'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWxTab(ColorScheme colorScheme, TextTheme textTheme) {
    final bytes = _decodeBase64Image(_wxSession?.imageBase64);
    return _loginCard(
      colorScheme,
      Column(
        children: [
          _qrFrame(
            colorScheme,
            bytes != null
                ? Image.memory(bytes, fit: BoxFit.cover)
                : const Center(child: M3ELoadingIndicator()),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _refreshQrCode,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新微信二维码'),
          ),
        ],
      ),
    );
  }

  Widget _buildQqTab(ColorScheme colorScheme, TextTheme textTheme) {
    final bytes = _decodeBase64Image(_qqSession?.imageBase64);
    return _loginCard(
      colorScheme,
      Column(
        children: [
          _qrFrame(
            colorScheme,
            bytes != null
                ? Image.memory(bytes, fit: BoxFit.cover)
                : const Center(child: M3ELoadingIndicator()),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _refreshQrCode,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新 QQ 二维码'),
          ),
        ],
      ),
    );
  }

  /// 三种扫码共用的二维码外框（统一 200×200 + 描边 + 圆角）。
  Widget _qrFrame(ColorScheme colorScheme, Widget child) {
    return Container(
      width: 200,
      height: 200,
      decoration: BoxDecoration(
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.5),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(12), child: child),
    );
  }

  Widget _buildPhoneTab(ColorScheme colorScheme, TextTheme textTheme) {
    return _loginCard(
      colorScheme,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _phoneCtrl,
            contextMenuBuilder: buildAppTextContextMenu,
            keyboardType: TextInputType.phone,
            maxLength: 11,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _codeFocus.requestFocus(),
            decoration: const InputDecoration(
              labelText: '手机号',
              prefixIcon: Icon(Icons.phone),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeCtrl,
                  contextMenuBuilder: buildAppTextContextMenu,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  focusNode: _codeFocus,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _onLoginPhone(),
                  decoration: const InputDecoration(
                    labelText: '验证码',
                    prefixIcon: Icon(Icons.message),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: (_sendingCode || _countdown > 0)
                    ? null
                    : _onSendCode,
                child: Text(_countdown > 0 ? '${_countdown}s' : '发送'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loggingIn ? null : _onLoginPhone,
            icon: _loggingIn
                ? const M3ELoadingIndicator(
                    constraints: BoxConstraints.tightFor(width: 16, height: 16),
                  )
                : const Icon(Icons.login),
            label: const Text('登录'),
          ),
        ],
      ),
    );
  }

  Widget _loginCard(ColorScheme colorScheme, Widget child) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SizedBox(width: 280, child: child),
      ),
    );
  }

  /// 验证码输满 6 位即自动尝试登录（maxLength=6 保证到 6 位就是"输满"；
  /// 登录中由 _onLoginPhone 的防重入守卫拦下，输错重填后再次输满会重新触发）
  void _onCodeChanged() {
    if (_codeCtrl.text.length == 6 && !_loggingIn) {
      _onLoginPhone();
    }
  }

  Future<void> _onSendCode() async {
    final phone = _phoneCtrl.text.trim();
    final kugou = context.read<KugouProvider>();
    setState(() => _sendingCode = true);
    final ok = await kugou.sendLoginCaptcha(phone);
    if (!mounted) return;
    setState(() => _sendingCode = false);
    if (ok) {
      setState(() => _statusText = '验证码已发送');
      _startCountdown();
      // 发送成功后焦点自动落到验证码框，方便用户直接输入
      _codeFocus.requestFocus();
    } else {
      setState(() => _statusText = kugou.error ?? '发送失败');
    }
  }

  void _startCountdown() {
    _countdown = 60;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) t.cancel();
    });
  }

  Future<void> _onLoginPhone() async {
    if (_loggingIn) return; // 自动登录触发与按钮点击共用，防止并发重复登录
    final phone = _phoneCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (phone.length != 11) {
      setState(() => _statusText = '请输入11位手机号');
      return;
    }
    if (code.isEmpty) {
      setState(() => _statusText = '请输入验证码');
      return;
    }
    final kugou = context.read<KugouProvider>();
    setState(() {
      _loggingIn = true;
      _statusText = '登录中...';
    });
    final result = await kugou.loginByPhone(phone, code);
    if (!mounted) return;
    setState(() => _loggingIn = false);

    switch (result.status) {
      case PhoneLoginStatus.success:
        await _onPhoneLoginSuccess();
      case PhoneLoginStatus.needChooseAccount:
        // 该手机号绑定多个账号：弹出账号选择，二次登录
        await _choosePhoneAccount(phone, code);
      case PhoneLoginStatus.failed:
        setState(() => _statusText = kugou.error ?? '登录失败');
    }
  }

  /// 扫码 / 手机验证码登录成功后的统一收尾：
  /// 停轮询 → 同步收藏 → 提示 → 关闭登录页。
  Future<void> _onLoginSuccess() async {
    if (!mounted) return;
    _stopPolling();
    // 登录后重新从云端同步「我喜欢的」，让红心立即生效
    unawaited(context.read<FavoritesProvider>().loadFavorites());
    setState(() => _statusText = '登录成功！');
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) Navigator.of(context).pop();
  }

  /// 手机验证码登录成功的收尾（与扫码登录共用 [_onLoginSuccess]）。
  Future<void> _onPhoneLoginSuccess() => _onLoginSuccess();

  /// 一个手机号绑定多个账号：弹出候选列表，选择后携 userid 二次登录
  Future<void> _choosePhoneAccount(String phone, String code) async {
    final kugou = context.read<KugouProvider>();
    final accounts = kugou.pendingLoginAccounts;
    if (accounts.isEmpty) {
      setState(() => _statusText = kugou.error ?? '登录失败');
      return;
    }

    final selected = await showM3EModalBottomSheet<KugouLoginAccount>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final tt = Theme.of(ctx).textTheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '该手机号绑定多个账号，请选择要登录的账号',
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: accounts.length,
                  separatorBuilder: (_, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final a = accounts[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cs.primary.withValues(alpha: 0.15),
                        child: Text(
                          (a.nickname != null && a.nickname!.isNotEmpty)
                              ? a.nickname!.characters.first
                              : '?',
                          style: TextStyle(color: cs.onPrimaryContainer),
                        ),
                      ),
                      title: Text(
                        (a.nickname != null && a.nickname!.isNotEmpty)
                            ? a.nickname!
                            : '账号 ${a.userid}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('ID: ${a.userid}'),
                      onTap: () => Navigator.pop(ctx, a),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (selected == null || !mounted) return;
    setState(() {
      _loggingIn = true;
      _statusText = '登录中...';
    });
    final ok = await kugou.loginByPhoneWithAccount(
      phone,
      code,
      selected.userid,
    );
    if (!mounted) return;
    setState(() => _loggingIn = false);
    if (ok) {
      await _onPhoneLoginSuccess();
    } else {
      setState(() => _statusText = kugou.error ?? '登录失败');
    }
  }
}
