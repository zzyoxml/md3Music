// 设置页三级子页结构校验：确认下钻后每个设置项都归属到正确的三级页，
// 且没有设置项在迁移中丢失。
//
// 复用搜索索引生成器的源码解析能力（与索引同源），因此不需要启动完整 App。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../scripts/tools/gen_settings_search_index.dart';

void main() {
  final root = Directory.current.path.replaceAll(r'\', '/');
  final entries = collectSettingsSearchEntries(projectRoot: root);

  /// 某设置项所属三级页标题；空串表示仍在二级页内联
  String subpageOf(String label) {
    for (final entry in entries) {
      if (entry.label == label) return entry.subpage;
    }
    fail('搜索索引中不存在设置项「$label」');
  }

  /// 某分类下所有设置项标题
  Set<String> labelsOf(String category) => entries
      .where((e) => e.category == category)
      .map((e) => e.label)
      .toSet();

  test('「外观」的五个三级页归属正确', () {
    expect(subpageOf('车机模式'), '车机模式');
    expect(subpageOf('面板位置'), '车机模式');
    expect(subpageOf('OLED 纯黑深色'), '主题与配色');
    expect(subpageOf('主题色'), '主题与配色');
    expect(subpageOf('app全局字体'), '字体与显示');
    expect(subpageOf('桌面布局'), '导航与布局');
    expect(subpageOf('悬浮迷你播放器'), '导航与布局');
    expect(subpageOf('启用自定义背景图片'), '界面背景');
    expect(subpageOf('文字阴影'), '界面背景');
    // 三级页入口自身可被搜索直达
    expect(subpageOf('主题与配色'), '主题与配色');
    expect(subpageOf('界面背景'), '界面背景');
  });

  test('「外观」设置项在迁移中无丢失', () {
    expect(
      labelsOf('外观'),
      containsAll(<String>[
        '车机模式',
        '检测到车机屏幕时自动开启',
        '面板位置',
        'OLED 纯黑深色',
        '使用系统主题色',
        '封面动态取色',
        '主题色',
        'app全局字体',
        '强调排版',
        '桌面布局',
        '悬浮迷你播放器',
        '启用自定义背景图片',
        '选择背景图片',
        '清除背景图片',
        '背景图片模糊',
        '背景图片透明度',
        '按背景图莫奈取色',
        '文字阴影',
      ]),
    );
  });

  test('「播放」的五个三级页归属正确', () {
    expect(subpageOf('32bit 播放支持'), '音质与输出');
    expect(subpageOf('音质降级提示'), '音质与输出');
    expect(subpageOf('均衡器'), '音效与音量');
    expect(subpageOf('音量均衡'), '音效与音量');
    expect(subpageOf('歌曲淡入淡出'), '播放行为');
    expect(subpageOf('允许与其他应用同时播放音频'), '播放行为');
    expect(subpageOf('显示 MV 弹幕'), '屏幕与视频');
    expect(subpageOf('播放时保持屏幕常亮'), '屏幕与视频');
    expect(subpageOf('MiniPlayer 滑动切歌'), '列表与交互');
    expect(subpageOf('收藏歌单按最近点击排序'), '列表与交互');
  });

  test('「播放」设置项在迁移中无丢失', () {
    expect(
      labelsOf('播放'),
      containsAll(<String>[
        '网络音质',
        '自动领取VIP',
        '32bit 播放支持',
        '音质降级提示',
        '均衡器',
        '禁用App均衡器和音效',
        '音效库',
        '蝰蛇母带处理',
        '蝰蛇母带音源',
        '音量均衡',
        '参考响度',
        '记忆播放状态',
        '启动时自动播放',
        '播放内容',
        '自动打开播放页',
        '暂停淡入淡出',
        '歌曲淡入淡出',
        '淡出时长',
        '自动混音（AutoMix）',
        '允许与其他应用同时播放音频',
        // 2026-10 由「上传听歌时长」扩展为「听歌数据云同步」（总控云端播放历史
        // 上传 + CSCC 真实播放上报 + 听歌等级累计，默认开启）
        '听歌数据云同步',
        '长按封面进入 Zen 模式',
        '横屏隐藏状态栏',
        '播放时保持屏幕常亮',
        '播放 MV 时自动画中画',
        '显示 MV 弹幕',
        '弹幕透明度',
        '关闭本地音乐评论区',
        'MiniPlayer 滑动切歌',
        '收藏歌单按最近点击排序',
      ]),
    );
  });

  test('「播放页样式」的三级页归属正确，歌词动画留在二级页', () {
    expect(subpageOf('歌词双击跳转'), '封面与动态');
    expect(subpageOf('专辑动态封面'), '封面与动态');
    expect(subpageOf('3D 封面'), '封面与动态');
    expect(subpageOf('清理深度图缓存'), '封面与动态');
    expect(subpageOf('封面阴影强度'), '封面与动态');
    expect(subpageOf('男女对唱歌词优化'), '歌词效果');
    expect(subpageOf('歌词辉光效果'), '歌词效果');
    expect(subpageOf('歌词省电模式'), '歌词效果');
    expect(subpageOf('音乐频谱环绕'), '音乐频谱');
    expect(subpageOf('频谱背景高度'), '音乐频谱');
    expect(subpageOf('歌手写真背景轮播'), '播放页背景');
    expect(subpageOf('播放页背景模糊'), '播放页背景');
    expect(subpageOf('进度条波浪起伏'), '进度条');
    // 播放页 chrome 三个形态开关统一归到「顶栏与页签」（此前散在「播放 → 屏幕与视频」）
    expect(subpageOf('横屏控制面板独立页'), '顶栏与页签');
    expect(subpageOf('胶囊按钮收缩'), '顶栏与页签');
    expect(subpageOf('顶栏页签圆点'), '顶栏与页签');
    expect(subpageOf('横屏隐藏状态栏'), '屏幕与视频');
    expect(subpageOf('播放时保持屏幕常亮'), '屏幕与视频');
    // 歌词动画是独立整屏页入口，保留在二级页避免四级导航（R5）
    expect(subpageOf('歌词动画'), isEmpty);
  });

  test('「播放页样式」设置项在迁移中无丢失', () {
    expect(
      labelsOf('播放页样式'),
      containsAll(<String>[
        '歌词双击跳转',
        '专辑动态封面',
        '移动网络下加载动态封面',
        '3D 封面',
        '3D 封面强度',
        'AI 背景修补',
        '清理深度图缓存',
        '歌手写真背景轮播',
        '轮播间隔',
        '写真背景透明度',
        '男女对唱歌词优化',
        '歌词动态颜色',
        '歌词高斯模糊',
        '歌词辉光效果',
        '背景动态流光',
        '播放页背景模糊',
        '歌词省电模式',
        '歌词动画',
        '横屏控制面板独立页',
        '胶囊按钮收缩',
        '顶栏页签圆点',
        '顶栏与页签',
        '音乐频谱环绕',
        '频谱柱数量',
        '频谱动态取色',
        '频谱柱状图透明度',
        '频谱曲线透明度',
        '频谱背景透明度',
        '频谱背景高度',
        '进度条波浪起伏',
      ]),
    );
  });

  test('「歌词」的三级页归属正确，歌词同步留在二级页', () {
    expect(subpageOf('翻译歌词'), '歌词推送');
    expect(subpageOf('罗马音歌词'), '歌词推送');
    expect(subpageOf('ColorOS Bridge 兼容字段'), '歌词推送');
    // 2026-10：原「解锁桌面歌词」单行已被「桌面歌词外观」面板取代
    // （解锁/点击穿透等并入其别名，见 desktop_lyric_settings_panel.dart）
    expect(subpageOf('桌面歌词外观'), '设备歌词');
    expect(subpageOf('蓝牙歌词'), '设备歌词');
    expect(subpageOf('压缩封面图'), '设备歌词');
    expect(subpageOf('锁屏歌词（实验性）'), '设备歌词');
    expect(subpageOf('状态栏歌词'), '设备歌词');
  });

  test('三级页条目均可被搜索直达（subpage 与 category 同时非空）', () {
    final subpageEntries = entries.where((e) => e.subpage.isNotEmpty);
    expect(subpageEntries, isNotEmpty);
    for (final entry in subpageEntries) {
      expect(entry.category, isNotEmpty);
    }
  });

  test('未下钻分类的设置项全部留在二级页', () {
    for (final category in const [
      'USB 独占',
      'AI 代理',
      '震动反馈',
      '缓存与数据',
      '关于',
      '主页管理',
      '桌面快捷方式',
    ]) {
      for (final entry in entries.where((e) => e.category == category)) {
        expect(
          entry.subpage,
          isEmpty,
          reason: '「$category」按设计不下钻，但「${entry.label}」带了三级页归属',
        );
      }
    }
  });
}
