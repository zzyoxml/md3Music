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
    super.dispose();
  }

  Future<void> _initLogin() async {
    final kugouProvider = context.read<KugouProvider>();
    await kugouProvider.generateQrCode();
    setState(() {
      _statusText = '请使用酷狗音乐 App 扫码登录';
    });
    _startCheck();
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
      debugPrint('Base64 decode error: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('登录酷狗音乐'),
      ),
      body: Center(
        child: Consumer<KugouProvider>(
          builder: (context, kugouProvider, child) {
            final qrData = kugouProvider.qrData;
            final qrImgBase64 = qrData?.base64;
            final qrKeyImg = kugouProvider.qrKey?.qrcodeImg;

            final qrImgBytes = _decodeBase64Image(qrImgBase64);

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
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
                                  child: Image.memory(
                                    qrImgBytes,
                                    fit: BoxFit.cover,
                                  ),
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
                                  : const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          _statusText,
                          style: textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _refreshQrCode,
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新二维码'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
