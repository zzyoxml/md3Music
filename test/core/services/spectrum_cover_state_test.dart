import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/spectrum_service.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 频谱「圆盘是否生效」同步镜像的回归测试。
///
/// 这条链路修的是一个真机必现的 bug：迷你条上滑展开时，跟手覆盖层里的播放页是
/// **当场新建**的，它的第一帧就已经在 0<p<1（封面连贯资格正在起点锁存），而它
/// 自己的频谱偏好要等 `initState` 的 post-frame 才异步读到 —— 锁存因此把
/// 「频谱开着」当成「可形变」，每次上滑都飞出一张方封面。
///
/// 镜像存在的意义就是让资格判据**同步可读**，所以这里锁死三件事：
/// 1. 读取偏好会灌镜像（播放页 / bootstrap 都靠它预热）；
/// 2. 写入偏好会**先**灌镜像（与调用方同帧生效，形状判据不落后于本地状态）；
/// 3. `kSpectrumDiscCoverActive` 只在 style 0/1 成立（style 2 是背景层，
///    播放页仍是方封面，形变照旧）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    kSpectrumEnabled = false;
    kSpectrumStyle = 0;
  });

  tearDown(() {
    kSpectrumEnabled = false;
    kSpectrumStyle = 0;
  });

  test('默认（未读到偏好）视为未生效：不得凭空压掉封面连贯', () {
    expect(kSpectrumDiscCoverActive, isFalse);
  });

  test('style 0/1 生效，style 2（背景层）不生效', () {
    kSpectrumEnabled = true;
    kSpectrumStyle = 0;
    expect(kSpectrumDiscCoverActive, isTrue);
    kSpectrumStyle = 1;
    expect(kSpectrumDiscCoverActive, isTrue);
    kSpectrumStyle = 2;
    expect(kSpectrumDiscCoverActive, isFalse, reason: '背景层仍是方封面，形变照旧');
  });

  test('开关关闭时任何样式都不生效', () {
    kSpectrumEnabled = false;
    kSpectrumStyle = 0;
    expect(kSpectrumDiscCoverActive, isFalse);
  });

  test('getter 灌镜像：读取偏好即刷新同步视图', () async {
    SharedPreferences.setMockInitialValues({
      'settings_spectrum_enabled': true,
      'settings_spectrum_style': 1,
    });
    kSpectrumEnabled = false;
    kSpectrumStyle = 0;

    final settings = SettingsRepository();
    await settings.getSpectrumEnabled();
    await settings.getSpectrumStyle();

    expect(kSpectrumEnabled, isTrue);
    expect(kSpectrumStyle, 1);
    expect(kSpectrumDiscCoverActive, isTrue);
  });

  test('getter 读到未设置项时回落默认值 false/0', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    kSpectrumEnabled = true;
    kSpectrumStyle = 1;

    final settings = SettingsRepository();
    await settings.getSpectrumEnabled();
    await settings.getSpectrumStyle();

    expect(kSpectrumEnabled, isFalse);
    expect(kSpectrumStyle, 0);
    expect(kSpectrumDiscCoverActive, isFalse);
  });

  test('setter 先灌镜像再落盘：调用后同帧即可读到新值', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsRepository();

    final pending = settings.setSpectrumEnabled(true);
    expect(
      kSpectrumEnabled,
      isTrue,
      reason: '镜像必须先写：播放页开关是 setState 同帧生效的',
    );
    await pending;

    final pendingStyle = settings.setSpectrumStyle(2);
    expect(kSpectrumStyle, 2);
    expect(
      kSpectrumDiscCoverActive,
      isFalse,
      reason: '样式切到背景层后圆盘立即失效，封面连贯恢复',
    );
    await pendingStyle;

    // 落盘值与镜像一致（下次冷启动由 bootstrap 的 getter 重新灌）
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings_spectrum_enabled'), isTrue);
    expect(prefs.getInt('settings_spectrum_style'), 2);
  });

  test('开关与样式是两个独立字段：后写的那次不覆盖另一项', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsRepository();

    // 顺序刻意与播放页 _loadSpectrumSetting 相反：先写样式、后写开关。
    // 镜像若是「合成一个 active 值」，后写的这次就会把样式抹掉。
    await settings.setSpectrumStyle(2);
    await settings.setSpectrumEnabled(true);
    expect(kSpectrumStyle, 2, reason: '样式不得被开关那次覆盖');
    expect(kSpectrumEnabled, isTrue);
    expect(
      kSpectrumDiscCoverActive,
      isFalse,
      reason: '背景层仍是方封面，形变照旧',
    );

    await settings.setSpectrumStyle(1);
    expect(kSpectrumEnabled, isTrue);
    expect(kSpectrumDiscCoverActive, isTrue);
  });
}
