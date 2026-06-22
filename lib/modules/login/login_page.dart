import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/kugou_provider.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  Timer? _checkTimer;
  String _statusText = '正在生成二维码...';
  bool _isChecking = false;
  int _tabIndex = 0; // 0=二维码 1=手机 2=微信

  // 手机登录表单
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _sendingCode = false;
  bool _loggingIn = false;
  int _countdown = 0;
  Timer? _countdownTimer;

  // 微信登录
  String? _wxUuid;
  Map<String, dynamic>? _wxQrData;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  void _switchTab(int idx) {
    if (_tabIndex == idx) return;
    _checkTimer?.cancel();
    _isChecking = false;
    _countdownTimer?.cancel();
    _countdown = 0;
    setState(() {
      _tabIndex = idx;
      _phoneCtrl.clear();
      _codeCtrl.clear();
      _wxUuid = null;
    });
    _initLogin();
  }

  Future<void> _initLogin() async {
    if (_tabIndex == 0) {
      final kugouProvider = context.read<KugouProvider>();
      await kugouProvider.generateQrCode();
      setState(() {
        _statusText = '请使用酷狗音乐 App 扫码登录';
      });
      _startCheck();
    } else if (_tabIndex == 2) {
      await _initWxLogin();
    } else {
      setState(() {
        _statusText = '请输入手机号获取验证码';
      });
    }
  }

  Future<void> _initWxLogin() async {
    final kugouProvider = context.read<KugouProvider>();
    setState(() {
      _statusText = '正在生成微信二维码...';
    });
    try {
      final api = kugouProvider.apiClient;
      final res = await api.createLoginWx();
      // 响应结构: {errcode, uuid, appname, qrcode: {qrcodebase64, ...}, ...}
      // (不是常见的 {data: {uuid: ...}} 嵌套)
      _wxUuid = res?['uuid']?.toString();
      _wxQrData = res; // 存根对象，二维码图片读 qrcode.qrcodebase64
      setState(() {
        _statusText = _wxUuid == null ? '生成微信二维码失败' : '请使用微信扫码登录';
      });
      if (_wxUuid != null) _startWxCheck();
    } catch (e) {
      setState(() {
        _statusText = '生成微信二维码失败: $e';
      });
    }
  }

  void _startWxCheck() {
    _checkTimer?.cancel();
    _isChecking = true;
    _checkTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted || _wxUuid == null) {
        timer.cancel();
        return;
      }
      final kugouProvider = context.read<KugouProvider>();
      try {
        final res = await kugouProvider.apiClient.checkLoginWx(_wxUuid!);
        // 微信 check 响应根级: {wx_errcode, wx_code}
        final code = res?['wx_code']?.toString();
        final status = res?['wx_errcode'] as int?;
        if (code != null && code.isNotEmpty) {
          timer.cancel();
          _isChecking = false;
          final loginRes = await kugouProvider.apiClient.loginByOpenplat(code);
          final data = loginRes?['data'] as Map?;
          final token = data?['token']?.toString();
          final userid = data?['userid']?.toString();
          final vipToken = data?['vip_token']?.toString();
          if (token != null && userid != null) {
            await kugouProvider.apiClient.setLoginCookies(
              token,
              userid,
              vipToken: vipToken,
            );
            // 触发 provider 拉用户信息
            await kugouProvider.refreshUserInfo();
            if (mounted) {
              setState(() => _statusText = '登录成功！');
              await Future.delayed(const Duration(milliseconds: 800));
              if (mounted) Navigator.of(context).pop();
            }
          } else {
            setState(() => _statusText = '微信登录失败: ${loginRes?['error_msg']}');
          }
        } else if (status == 408) {
          setState(() => _statusText = '等待扫描...');
        } else if (status == 404) {
          setState(() => _statusText = '已扫描，请在手机上确认');
        } else if (status == 402) {
          timer.cancel();
          setState(() => _statusText = '二维码已过期');
        } else if (status == 403) {
          timer.cancel();
          setState(() => _statusText = '已拒绝登录');
        }
      } catch (e) {
              }
    });
  }

  void _startCheck() {
    _checkTimer?.cancel();
    _isChecking = true;
    _checkTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final kugouProvider = context.read<KugouProvider>();
      final status = await kugouProvider.checkQrCode();
      if (status == null) {
        return;
      }
      if (status == 4) {
        timer.cancel();
        _isChecking = false;
        if (mounted) {
          setState(() {
            _statusText = '登录成功！';
          });
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) {
              Navigator.of(context).pop();
            }
          });
        }
      } else if (status == 800 || status == 0) {
        timer.cancel();
        _isChecking = false;
        if (mounted) {
          setState(() {
            _statusText = '二维码已过期，请刷新重试';
          });
        }
      } else if (status == 2 || status == 803) {
        setState(() {
          _statusText = '已扫码，请在手机上确认登录';
        });
      } else if (status == 1) {
        setState(() {
          _statusText = '等待扫码...';
        });
      }
    });
  }

  Future<void> _refreshQrCode() async {
    final kugouProvider = context.read<KugouProvider>();
    setState(() {
      _statusText = '正在刷新二维码...';
    });
    await kugouProvider.generateQrCode();
    setState(() {
      _statusText = '请使用酷狗音乐 App 扫码登录';
    });
    if (!_isChecking) {
      _startCheck();
    }
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
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Tab 切换
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      icon: Icon(Icons.qr_code),
                      label: Text('扫码'),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: Icon(Icons.phone_android),
                      label: Text('手机'),
                    ),
                  ],
                  selected: {_tabIndex},
                  onSelectionChanged: (s) => _switchTab(s.first),
                ),
              ),
              const SizedBox(height: 16),
              if (_tabIndex == 0) _buildQrTab(colorScheme, textTheme),
              if (_tabIndex == 1) _buildPhoneTab(colorScheme, textTheme),
              const SizedBox(height: 16),
              Text(
                _statusText,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
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
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.5),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: qrImgBytes != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(qrImgBytes, fit: BoxFit.cover),
                      )
                    : qrKeyImg != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          qrKeyImg,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return const Center(
                              child: Icon(Icons.qr_code, size: 80),
                            );
                          },
                        ),
                      )
                    : const Center(child: CircularProgressIndicator()),
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

  Widget _buildPhoneTab(ColorScheme colorScheme, TextTheme textTheme) {
    return _loginCard(
      colorScheme,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            maxLength: 11,
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
                  keyboardType: TextInputType.number,
                  maxLength: 6,
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
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: const Text('登录'),
          ),
        ],
      ),
    );
  }

  Widget _buildWxTab(ColorScheme colorScheme, TextTheme textTheme) {
    final base64 = _wxQrData?['qrcode']?['qrcodebase64']?.toString();
    final bytes = _decodeBase64Image(base64);
    return _loginCard(
      colorScheme,
      Column(
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              border: Border.all(
                color: colorScheme.outline.withValues(alpha: 0.5),
                width: 2,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: bytes != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(bytes, fit: BoxFit.cover),
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              _checkTimer?.cancel();
              _initWxLogin();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('刷新微信二维码'),
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
    final ok = await kugou.loginByPhone(phone, code);
    if (!mounted) return;
    setState(() => _loggingIn = false);
    if (ok) {
      setState(() => _statusText = '登录成功！');
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) Navigator.of(context).pop();
    } else {
      setState(() => _statusText = kugou.error ?? '登录失败');
    }
  }
}
