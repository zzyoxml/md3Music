import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 展示本应用自身许可证（GNU AGPL-3.0）全文。
///
/// 与设置页「开源许可」（showLicensePage，展示第三方依赖许可）不同，
/// 此页展示的是本应用仓库根目录 `LICENSE` 文件（asset 键为 `LICENSE`）。
class LicenseViewPage extends StatefulWidget {
  const LicenseViewPage({super.key});

  @override
  State<LicenseViewPage> createState() => _LicenseViewPageState();
}

class _LicenseViewPageState extends State<LicenseViewPage> {
  String _text = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await rootBundle.loadString('LICENSE');
      if (!mounted) return;
      setState(() => _text = text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '许可证文件加载失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('本应用许可证')),
      body: _error != null
          ? Center(child: Text(_error!))
          : _text.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: SelectableText(
                    _text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.5,
                    ),
                  ),
                ),
    );
  }
}
