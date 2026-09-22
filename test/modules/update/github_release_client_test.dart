import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/update/github_release_client.dart';
import 'package:md3music/modules/update/release_info.dart';

void main() {
  test('仓库地址为唯一来源常量', () {
    expect(
      GithubReleaseClient.apiLatestUri.toString(),
      'https://api.github.com/repos/zzyoxml/md3Music/releases/latest',
    );
    expect(
      GithubReleaseClient.htmlLatestUri.toString(),
      'https://github.com/zzyoxml/md3Music/releases/latest',
    );
    expect(GithubReleaseClient.userAgent, isNotEmpty);
  });

  group('parseTagFromRedirectLocation', () {
    test('标准 Location 解析出 tag', () {
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/zzyoxml/md3Music/releases/tag/v5.6.5',
        ),
        'v5.6.5',
      );
    });

    test('容忍查询串与锚点', () {
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/zzyoxml/md3Music/releases/tag/v5.6.5?x=1',
        ),
        'v5.6.5',
      );
    });

    test('无 tag 段或空值返回 null', () {
      expect(parseTagFromRedirectLocation(null), isNull);
      expect(parseTagFromRedirectLocation(''), isNull);
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/zzyoxml/md3Music/releases',
        ),
        isNull,
      );
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/zzyoxml/md3Music/releases/tag/',
        ),
        isNull,
      );
    });
  });

  group('ReleaseInfo.fromTag', () {
    test('剥离 v 前缀得到展示版本号', () {
      final info = ReleaseInfo.fromTag(
        tagName: 'v5.6.5',
        htmlUrl: 'https://github.com/zzyoxml/md3Music/releases/tag/v5.6.5',
      );
      expect(info.tagName, 'v5.6.5');
      expect(info.version, '5.6.5');
    });

    test('无 v 前缀时原样保留', () {
      final info = ReleaseInfo.fromTag(
        tagName: '5.6.5',
        htmlUrl: 'https://example.com',
      );
      expect(info.version, '5.6.5');
    });
  });
}
