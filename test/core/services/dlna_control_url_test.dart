import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/dlna_service.dart';

/// 乐播 / 乐视接收端的非标准 controlURL 回归（2026-11-10）。
///
/// **现象**：投屏到「乐播」接收端时提示
/// `投屏操作失败：FormatException: Scheme not starting with alphabetic
/// character (at character 1) _urn:schemas-upnp-org:service:AVTransport_control`。
///
/// **根因**：这类设备把 controlURL 写成首段含冒号的相对引用，RFC 3986 不允许，
/// dlna_dart 内部的 `Uri.parse(URLBase).resolve(controlURL)` 直接抛
/// FormatException。实际设备接受 `POST /_urn:..._control`，
/// 拼成绝对地址即可正常投屏。
void main() {
  DLNADevice buildDevice(
    List<Map<String, String>> services, {
    String urlBase = 'http://10.17.41.43:49152',
  }) {
    return DLNADevice(
      DeviceInfo(
        urlBase,
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        '投屏电视U2',
        services,
      ),
    );
  }

  Map<String, String> avTransport(String controlUrl) => {
    'serviceType': 'urn:schemas-upnp-org:service:AVTransport:1',
    'serviceId': 'urn:upnp-org:serviceId:AVTransport',
    'controlURL': controlUrl,
  };

  test('乐播式 controlURL 归一化为绝对地址后不再抛 FormatException', () {
    final device = buildDevice([
      avTransport('_urn:schemas-upnp-org:service:AVTransport_control'),
    ]);

    // 修复前：dlna_dart 的 controlURL 解析直接抛异常
    expect(() => device.controlURL('AVTransport'), throwsFormatException);

    DlnaService.normalizeControlUrls(device);

    expect(
      device.controlURL('AVTransport'),
      'http://10.17.41.43:49152/_urn:schemas-upnp-org:service:AVTransport_control',
    );
  });

  test('URLBase 自带尾部斜杠时不产生双斜杠', () {
    final device = buildDevice(
      [avTransport('_urn:schemas-upnp-org:service:AVTransport_control')],
      urlBase: 'http://10.17.41.43:49152/',
    );

    DlnaService.normalizeControlUrls(device);

    expect(
      device.controlURL('AVTransport'),
      'http://10.17.41.43:49152/_urn:schemas-upnp-org:service:AVTransport_control',
    );
  });

  test('标准相对路径与绝对地址保持原样（原逻辑不受影响）', () {
    final device = buildDevice([
      avTransport('/upnp/control/AVTransport1'),
      {
        'serviceType': 'urn:schemas-upnp-org:service:RenderingControl:1',
        'serviceId': 'urn:upnp-org:serviceId:RenderingControl',
        'controlURL': 'http://10.17.41.43:9000/rc',
      },
    ]);

    DlnaService.normalizeControlUrls(device);

    // 能正常 resolve 的值不改写，仍按 dlna_dart 原逻辑拼地址
    expect(
      device.info.serviceList[0]['controlURL'],
      '/upnp/control/AVTransport1',
    );
    expect(device.controlURL('AVTransport'),
        'http://10.17.41.43:49152/upnp/control/AVTransport1');
    expect(device.controlURL('RenderingControl'),
        'http://10.17.41.43:9000/rc');
  });
}
