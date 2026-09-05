import 'package:shared_preferences/shared_preferences.dart';

// personal_fm_section 的补货相关依赖统一从此 re-export。
export '../../widgets/sliding_segmented_control.dart';
export '../../widgets/wavy_playback_line.dart';
export '../login/login_page.dart';
export '../player/full_player_route.dart';

/// FM 会话持久化：记录「正在播放的是私人 FM 队列」与当时档位。
///
/// 续播器（_FmRefill）是内存对象，进程被杀后消失；而播放队列由
/// PlayerStateRepository 持久化、冷启动时恢复。两者错位就会导致恢复的队列
/// 永远没人补货。本类负责跨过进程边界传达「这条队列是 FM 电台」。
class FmRefillStore {
  static const _kActive = 'fm_refill_active';
  static const _kStation = 'fm_refill_station';

  /// 内存代次：同一进程内后起的续播器代次更大，防止旧续播器退场时
  /// 清掉新续播器刚写下的标记（换档重起播场景）。冷启动归零无妨：
  /// 恢复路径会重新 markActive 续一代。
  static int _generation = 0;

  /// 起播时调用：标记会话活跃并返回本代代次。
  static int nextGeneration() => ++_generation;

  static Future<void> markActive(int stationIndex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kActive, true);
    await prefs.setInt(_kStation, stationIndex);
  }

  /// 续播器退场时调用：只有本代仍是当前代才清标记。
  static Future<void> clearIfCurrent(int generation) async {
    if (generation != _generation) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kActive, false);
  }

  /// 冷启动自愈入口：会话活跃时返回上次档位，否则 null。
  static Future<int?> activeStationIndex() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_kActive) ?? false)) return null;
    return prefs.getInt(_kStation);
  }
}
