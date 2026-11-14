import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/utils/live_filter.dart';

Song _song(String title) => Song(
      id: '1',
      title: title,
      artist: 'a',
      album: 'b',
      duration: const Duration(seconds: 200),
    );

/// 「过滤 Live/现场版本」的正则判定自检：改联动规则必须连跑此测试。
void main() {
  test('live 版本命中', () {
    final live = [
      '一个像夏天一个像秋天 (Live)',
      '是妈妈是女儿(Live)',
      '是妈妈是女儿（现场）',
      '是妈妈是女儿（现场版）',
      '是妈妈是女儿 - Live',
      '是妈妈是女儿/Live',
      '是妈妈是女儿 Live版',
      '是妈妈是女儿 (Live).mp3', // displayName 剥掉 .mp3 后命中
      '(Live at Wembley)', // 括号内 Live 后跟正文也算现场版
      '一个像夏天一个像秋天（Live 2020）',
      '一个像夏天一个像秋天 - Live 2020',
    ];
    for (final t in live) {
      expect(isLiveSong(_song(t)), isTrue, reason: '应命中: $t');
    }
  });

  test('正常歌名不命中', () {
    final normal = [
      '一个像夏天一个像秋天',
      'Alive',
      'Livin\' on a Prayer',
      '孤独现场会', // "现场" 前后有字，不是独立词
      '一个像夏天一个像秋天.mp3',
      'Live and Let Die', // Live 开头的正经歌名
      'Livehouse 天黑请闭嘴', // Live 后紧跟字母的合成词
      'Live, Laugh, Love', // Live 后接标点再接英文词
    ];
    for (final t in normal) {
      expect(isLiveSong(_song(t)), isFalse, reason: '不应命中: $t');
    }
  });
}
