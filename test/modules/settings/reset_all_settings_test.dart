import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('还原跨模块设置，保留账号凭据、签到、收藏和播放数据', () async {
    final settings = <String, Object>{
      'settings_default_quality': 'flac',
      'settings_crossfade_enabled': true,
      'settings_mcp_enabled': true,
      'settings_windows_two_pane_enabled': false,
      'theme_mode': 'dark',
      'use_background_image': true,
      'background_image_path': 'wallpaper.jpg',
      'custom_text_color': 0xFF734BA1,
      'lyric_font_size': 40.0,
      'md3_lyric_line_balance': true,
      'lyricon_enabled': true,
      'super_lyric_enabled': true,
      'eq_enabled': true,
      'eq_band_level_0': 100,
      'viper_eq_gain_0': 3.0,
      'usb_output_rate': 96000,
      'enable_32bit_output': true,
      'grid_columns': 6,
      'desktop_detail_ratio': 0.5,
      'comment_display_font_size': 23.0,
      'local_music_filter_short_audio': true,
    };
    final retained = <String, Object>{
      'kugou_current_userid': '123',
      'kugou_accounts': '[{"userid":"123"}]',
      'kugou_token': 'legacy-token',
      'device_dfid': 'device-identity',
      'settings_signed_days': <String>['2026-10-20'],
      'settings_signed_days_123': <String>['2026-10-21'],
      'favorite_songs': <String>['song-1'],
      'play_history': <String>['song-2'],
      'player_current_song': 'song-1',
      'local_music_cached_songs': '[]',
      'onboarding_completed': true,
      'unknown_data_key': 'keep',
    };
    SharedPreferences.setMockInitialValues({...settings, ...retained});
    FlutterSecureStorage.setMockInitialValues({
      'kugou_token_123': 'login-token',
      'kugou_vip_token_123': 'vip-token',
      'settings_mcp_token_secure': 'mcp-token',
    });

    final repo = SettingsRepository();
    await repo.resetAllSettingsToDefaults();
    final prefs = await SharedPreferences.getInstance();
    for (final key in settings.keys) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }
    for (final entry in retained.entries) {
      expect(prefs.get(entry.key), entry.value, reason: entry.key);
    }
    const secure = FlutterSecureStorage();
    expect(await secure.read(key: 'kugou_token_123'), 'login-token');
    expect(await secure.read(key: 'kugou_vip_token_123'), 'vip-token');
    expect(await secure.read(key: 'settings_mcp_token_secure'), isNull);
    expect(await repo.getDefaultQuality(), '128');
    expect(await repo.getWindowsTwoPaneEnabled(), isFalse);

    // 空设置再次还原也不删除账号或其余数据。
    await repo.resetAllSettingsToDefaults();
    expect(prefs.getKeys(), retained.keys.toSet());
  });
}
