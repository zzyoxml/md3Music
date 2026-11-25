import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';

/// App 功能工具（group = app_features）。
List<McpTool> buildAppFeaturesTools(McpAppFeaturesPort app) => <McpTool>[
      McpTool(
        name: 'md3_get_app_features',
        description: '读取应用功能状态：睡眠定时、均衡器（含可用预设列表）、桌面歌词、'
            '输出模式（system/direct_pcm/usbdevfs，只读）。',
        inputSchema: {'type': 'object', 'properties': <String, Object?>{}},
        group: kMcpGroupAppFeatures,
        handler: (_) async => McpToolResult(app.snapshot().toJson()),
      ),
      McpTool(
        name: 'md3_set_sleep_timer',
        description: '设置睡眠定时（minutes 分钟后自动暂停播放）；minutes=0 表示取消。'
            '当前剩余时间用 md3_get_app_features 查询。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'minutes': <String, Object?>{
              'type': 'integer',
              'description': '定时分钟数，1-480；0 = 取消',
            },
          },
          'required': <Object?>['minutes'],
        },
        isMutating: true,
        group: kMcpGroupAppFeatures,
        handler: (args) async {
          final minutes = requireInt(args, 'minutes', min: 0, max: 480);
          final duration = minutes == 0 ? null : Duration(minutes: minutes);
          await app.setSleepTimer(duration);
          return McpToolResult.text(
              minutes == 0 ? '已取消睡眠定时' : '将在 $minutes 分钟后暂停播放');
        },
      ),
      McpTool(
        name: 'md3_set_eq_enabled',
        description: '开启/关闭均衡器。注意这会实时改变当前播放的声音效果。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'enabled': <String, Object?>{'type': 'boolean', 'description': '是否开启'},
          },
          'required': <Object?>['enabled'],
        },
        isMutating: true,
        group: kMcpGroupAppFeatures,
        requiresConfirmation: true,
        handler: (args) async {
          await app.setEqEnabled(requireBool(args, 'enabled'));
          return const McpToolResult.text('均衡器状态已更新');
        },
      ),
      McpTool(
        name: 'md3_apply_eq_preset',
        description:
            '应用指定名称的均衡器预设（预设名列表见 md3_get_app_features 的 eq.presets）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'name': <String, Object?>{'type': 'string', 'description': '预设名'},
          },
          'required': <Object?>['name'],
        },
        isMutating: true,
        group: kMcpGroupAppFeatures,
        requiresConfirmation: true,
        handler: (args) async {
          final name = requireString(args, 'name');
          final presets = app.snapshot().eqPresets;
          if (!presets.contains(name)) {
            return McpToolResult.error(
                '预设 "$name" 不存在。可用预设：${presets.join('、')}');
          }
          await app.applyEqPreset(name);
          return McpToolResult.text('均衡器已切换到「$name」');
        },
      ),
      McpTool(
        name: 'md3_set_desktop_lyric',
        description: '开启/关闭桌面歌词。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'enabled': <String, Object?>{'type': 'boolean', 'description': '是否开启'},
          },
          'required': <Object?>['enabled'],
        },
        isMutating: true,
        group: kMcpGroupAppFeatures,
        requiresConfirmation: true,
        handler: (args) async {
          await app.setDesktopLyric(requireBool(args, 'enabled'));
          return const McpToolResult.text('桌面歌词状态已更新');
        },
      ),
    ];
