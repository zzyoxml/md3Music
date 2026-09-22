import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/listen_together/join_room_sheet.dart';

void main() {
  test('extractRoomNumber', () {
    expect(extractRoomNumber('12345678'), '12345678');
    expect(extractRoomNumber('来一起听吧 房间号：88489912 快加入'), '88489912');
    expect(extractRoomNumber('无数字'), isNull);
    expect(extractRoomNumber('12 34'), isNull); // 过短片段不误报
  });
}
