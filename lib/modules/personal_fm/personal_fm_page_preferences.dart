import 'package:shared_preferences/shared_preferences.dart';

/// 完整「私人 FM」页面的推荐方式。
///
/// 这里单独使用页面级偏好键，不与发现页内嵌 FM 的电台索引混用。
class PersonalFmPageSelection {
  const PersonalFmPageSelection({
    required this.mode,
    required this.songPoolId,
  });

  final String mode;
  final int songPoolId;
}

class PersonalFmPagePreferences {
  static const modeKey = 'personal_fm_page_selected_mode';
  static const songPoolIdKey = 'personal_fm_page_selected_song_pool_id';

  static Future<PersonalFmPageSelection> load() async {
    final prefs = await SharedPreferences.getInstance();
    return PersonalFmPageSelection(
      mode: prefs.getString(modeKey) ?? 'normal',
      songPoolId: prefs.getInt(songPoolIdKey) ?? 0,
    );
  }

  static Future<void> save({
    required String mode,
    required int songPoolId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(modeKey, mode);
    await prefs.setInt(songPoolIdKey, songPoolId);
  }
}
