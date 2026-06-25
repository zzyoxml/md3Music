import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 数据迁移工具 - 清除旧版本的全局键名，避免数据混乱
/// 
/// 在登录页面调用此方法，或创建一个设置选项让用户手动执行
class DataMigrationTool {
  
  /// 清除旧版本的全局SharedPreferences键
  /// 这些键可能导致多用户数据混乱
  static Future<void> clearOldGlobalKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 旧版本使用的全局键名（这些会导致数据混乱）
      final oldKeys = [
        'kugou_token',
        'kugou_userid',
        'kugou_vip_token',
        'kugou_dfid',
      ];
      
      int clearedCount = 0;
      for (final key in oldKeys) {
        final exists = prefs.containsKey(key);
        if (exists) {
          await prefs.remove(key);
          clearedCount++;
          print('🧹 [Migration] 已清除旧键: $key');
        }
      }
      
      // 也清除当前用户ID记录，强制重新登录
      await prefs.remove('kugou_current_userid');
      
      print('✅ [Migration] 数据迁移完成，共清除 $clearedCount 个旧键');
      print('⚠️ [Migration] 请重新登录以生成新的用户隔离键');
      
    } catch (e) {
      print('❌ [Migration] 数据迁移失败: $e');
    }
  }
  
  /// 检查是否存在旧版本的全局键
  static Future<bool> hasOldGlobalKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey('kugou_token') || 
             prefs.containsKey('kugou_userid') ||
             prefs.containsKey('kugou_vip_token');
    } catch (e) {
      return false;
    }
  }
  
  /// 显示数据迁移对话框
  static Future<void> showMigrationDialog(BuildContext context) async {
    final hasOldData = await hasOldGlobalKeys();
    
    if (!hasOldData) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 没有发现旧数据，无需迁移'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    
    if (!context.mounted) return;
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🔧 数据迁移'),
        content: const Text(
          '检测到旧版本的登录数据，这可能导致显示其他用户的信息。\n\n'
          '建议执行数据迁移来修复此问题。\n\n'
          '执行后需要重新登录。'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await clearOldGlobalKeys();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('✅ 数据迁移完成，请重新登录'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: const Text('执行迁移'),
          ),
        ],
      ),
    );
  }
}
