import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/private/custom_download_directory_access.dart';

void main() {
  group('ensureCustomDownloadDirectoryAccess', () {
    test('already granted does not open the permission request', () async {
      var requests = 0;

      final allowed = await ensureCustomDownloadDirectoryAccess(
        checkPermission: () async => true,
        requestPermission: () async {
          requests++;
          return true;
        },
      );

      expect(allowed, isTrue);
      expect(requests, 0);
    });

    test('requests once after a denied status and accepts a grant', () async {
      var checks = 0;
      var requests = 0;

      final allowed = await ensureCustomDownloadDirectoryAccess(
        checkPermission: () async {
          checks++;
          return false;
        },
        requestPermission: () async {
          requests++;
          return true;
        },
      );

      expect(allowed, isTrue);
      expect(checks, 1);
      expect(requests, 1);
    });

    test('returns denied when the user does not grant access', () async {
      var requests = 0;

      final allowed = await ensureCustomDownloadDirectoryAccess(
        checkPermission: () async => false,
        requestPermission: () async {
          requests++;
          return false;
        },
      );

      expect(allowed, isFalse);
      expect(requests, 1);
    });
  });
}
