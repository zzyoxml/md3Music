import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/models/song.dart';
import '../../services/kugou_api/kugou_endpoints.dart';

/// 写真响应体拉取器。测试注入自定义实现即可完全脱离网络。
typedef ArtistPhotoFetcher = Future<String> Function(Uri uri);

Future<String> _defaultFetcher(Uri uri) async => (await http.get(uri)).body;

/// 歌手写真数据源（`/images/audio`，Rust 侧 `kugou_api_server/rust/src/modules/images.rs`）。
///
/// MD3 播放页（[ArtistPhotoBackground]）与 AM 播放页（[AmArtistPhotoLayer]）
/// 共用同一份「拉取 + 解析」，避免两处各写一份后漂移。
class ArtistPhotoService {
  ArtistPhotoService({ArtistPhotoFetcher? fetcher})
      : _fetcher = fetcher ?? _defaultFetcher;

  final ArtistPhotoFetcher _fetcher;

  /// 组件默认取的全局实例。
  ///
  /// 刻意做成**可变静态字段**而不是 getter/setter 包私有字段：后者会触发
  /// `unnecessary_getters_setters` lint。供测试替换（tearDown 必须还原）。
  static ArtistPhotoService instance = ArtistPhotoService();

  /// 拉取某首歌的歌手写真 URL 列表。
  ///
  /// hash 为空、本地服务器未就绪（[KugouEndpoints.baseUrl] 为空）、请求失败、
  /// 响应非法时一律返回空列表——调用方据此回落到「无写真」形态，绝不抛异常。
  ///
  /// [artistId] / [artistName]：写真**归属过滤**（见 [itemBelongsToArtist]）。
  /// 上游按「歌曲 hash」返回该曲**全部歌手**的写真（请求带 `show_authors=1`），
  /// 所以歌手详情页查合作曲时会拿到别人的照片。播放页要的是「这首歌的歌手们」，
  /// 不传即可保持原样。
  Future<List<String>> load({
    required String hash,
    int count = 20,
    String? artistId,
    String? artistName,
  }) async {
    if (hash.isEmpty) return const <String>[];
    final base = KugouEndpoints.baseUrl;
    if (base.isEmpty) return const <String>[];
    final uri = Uri.parse(
      '$base${KugouEndpoints.imagesAudio}'
      '?hash=${Uri.encodeQueryComponent(hash)}&count=$count',
    );
    final String body;
    try {
      body = await _fetcher(uri);
    } catch (_) {
      return const <String>[];
    }
    return parseUrls(body, artistId: artistId, artistName: artistName);
  }

  /// 纯函数：解析 `/images/audio` 响应体 → 写真 URL 列表。
  ///
  /// 响应形如 `{"status":1,"data":[[{"author":..,"imgs":{"320":[{"sizable_portrait":..}]}}]]}`：
  /// `data` 是二维数组（分组 → 条目），每个条目的 `imgs` 是「尺寸 → 图片数组」的 Map。
  /// 任何一层类型不符 / 字段缺失都安全跳过，不抛异常。
  ///
  /// [artistId] / [artistName] 任一非空时按写真归属过滤条目（合作曲场景剔除他人
  /// 写真）；两者都不传时行为与历史完全一致——播放页调用方不传。
  static List<String> parseUrls(
    String body, {
    String? artistId,
    String? artistName,
  }) {
    final urls = <String>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return urls;
    }
    if (decoded is! Map<String, dynamic>) return urls;
    if (decoded['status'] != 1) return urls;
    final data = decoded['data'];
    if (data is! List) return urls;
    final filter = (artistId ?? '').trim().isNotEmpty ||
        (artistName ?? '').trim().isNotEmpty;
    for (final group in data) {
      final items = group is List ? group : <Object?>[group];
      for (final item in items) {
        if (item is! Map) continue;
        // 归属不符的条目整条丢弃（该条目下所有尺寸一起不取）
        if (filter &&
            !itemBelongsToArtist(
              item,
              artistId: artistId,
              artistName: artistName,
            )) {
          continue;
        }
        final imgs = item['imgs'];
        if (imgs is! Map) continue;
        for (final imgList in imgs.values) {
          if (imgList is! List) continue;
          for (final img in imgList) {
            if (img is! Map) continue;
            final url = img['sizable_portrait'];
            if (url is String && url.isNotEmpty && !urls.contains(url)) {
              urls.add(url);
            }
          }
        }
      }
    }
    return urls;
  }

  /// 判断一个写真条目是否属于目标歌手。
  ///
  /// **保守规则**（宁可放过，绝不误伤）：条目里既取不到可比对的 id 也取不到可比对的
  /// 名字 → 返回 true（上游没给归属信息，无法判定，保留原样）；能取到任一可比字段
  /// 且命中目标 → true；能取到可比字段但全部不命中 → false（这就是合作曲里混进来的
  /// 他人写真）。
  ///
  /// 只采信**条目自身**的归属标识：`author`（本仓既有注释记录的形态
  /// `{"author":..,"imgs":..}`，可能是字符串名 / Map / 数组）与 `author_id`/
  /// `author_name` 一类标量键。刻意**不看** `authors`/`singerinfo`/`singers` 这类
  /// 「这首歌的全部歌手」数组——合作曲里每个条目都会包含本歌手，用它判定等于没判定。
  /// 同理条目顶层裸 `name` 语义不明（可能是图集名），只在 author 作用域内采信。
  ///
  /// 公开纯函数：本文件不引 Flutter/meta 依赖（不加 `@visibleForTesting`），
  /// 测试与调用方都可直接核对判定结果。
  static bool itemBelongsToArtist(
    Map item, {
    String? artistId,
    String? artistName,
  }) {
    final wantId = (artistId ?? '').trim();
    final wantName = (artistName ?? '').trim().toLowerCase();
    if (wantId.isEmpty && wantName.isEmpty) return true;

    var sawId = false;
    var sawName = false;
    var matched = false;

    // 「可比对」只统计**调用方真的要求核对的维度**：只传 id 而条目只带作者名时，
    // 无法把名字映射到 id，此时必须走「无法判定 → 保留」，否则会把写真整体清空
    // （比混进他人写真更糟）。
    void checkId(Object? raw) {
      if (wantId.isEmpty || raw == null) return;
      final s = raw.toString().trim();
      if (s.isEmpty) return;
      sawId = true;
      if (s == wantId) matched = true;
    }

    void checkName(Object? raw) {
      if (wantName.isEmpty || raw == null) return;
      final s = raw.toString().trim();
      if (s.isEmpty) return;
      sawName = true;
      // 先按整串比（目标歌手名本身可能含「&」「,」等分隔符，如 "A & B" 单人艺名），
      // 再按「多位歌手连写」逐段比：若上游把这首歌的全部歌手塞进 author（如 "甲、乙"），
      // 本歌手也在其中 → 判为命中。这样的形态本就无从区分归属，放行等于回到旧行为，
      // 绝不会比现状更差（反之若按整串不等直接丢弃，会把写真清空）。
      if (s.toLowerCase() == wantName) {
        matched = true;
        return;
      }
      for (final part in splitSongArtistNames(s)) {
        if (part.toLowerCase() == wantName) {
          matched = true;
          return;
        }
      }
    }

    /// [authorScope]：true 表示该 Map 本身就是作者对象（来自 `author` 字段），
    /// 此时裸 `id`/`name` 才是作者 id / 作者名（酷狗 `{name, id}` 约定，
    /// 与 `kugou_models.dart` 解析 `Singers` 同源）；条目顶层的裸 `id`/`name`
    /// 语义不明，不能拿来比对歌手。
    void collect(Map m, {required bool authorScope}) {
      for (final k in const ['author_id', 'authorid', 'singer_id', 'singerid']) {
        checkId(m[k]);
      }
      for (final k in const ['author_name', 'authorname', 'singer_name']) {
        checkName(m[k]);
      }
      if (authorScope) {
        checkId(m['id']);
        checkName(m['name']);
      }
      final author = m['author'];
      if (author is Map) {
        collect(author, authorScope: true);
      } else if (author is List) {
        for (final a in author) {
          if (a is Map) {
            collect(a, authorScope: true);
          } else if (a != null) {
            checkName(a);
          }
        }
      } else if (author != null) {
        checkName(author);
      }
    }

    collect(item, authorScope: false);
    if (!sawId && !sawName) return true;
    return matched;
  }
}
