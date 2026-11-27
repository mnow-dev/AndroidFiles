import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_files/src/adb_client.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/disk_space.dart';
import 'package:android_files/src/hard_links.dart';
import 'package:android_files/src/manifest.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/os.dart';
import 'package:android_files/src/tar_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Number of hardlinks to [path], via the platform's stat tool.
int? linkCount(String path) {
  final r = Platform.isMacOS
      ? Process.runSync('stat', ['-f', '%l', path])
      : Platform.isLinux
      ? Process.runSync('stat', ['-c', '%h', path])
      : null;
  return r == null ? null : int.tryParse((r.stdout as String).trim());
}

Uint8List tarFile(String name, String content) {
  final payload = utf8.encode(content);
  final h = Uint8List(512);
  final n = utf8.encode(name);
  h.setRange(0, n.length, n);
  h.setRange(124, 136, ascii.encode('${payload.length.toRadixString(8).padLeft(11, '0')} '));
  h.setRange(136, 148, ascii.encode('${1700000000.toRadixString(8).padLeft(11, '0')} '));
  h[156] = '0'.codeUnitAt(0);
  return (BytesBuilder()
        ..add(h)
        ..add(Uint8List((payload.length + 511) & ~511)
          ..setRange(0, payload.length, payload))
        ..add(Uint8List(1024)))
      .takeBytes();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('af_platform_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('localJoin turns tar-style paths into native ones', () {
    final p = localJoin('base', 'DCIM/Camera/a.jpg');
    expect(
      p,
      Platform.isWindows ? r'base\DCIM\Camera\a.jpg' : 'base/DCIM/Camera/a.jpg',
    );
    expect(localBaseName(p), 'a.jpg');
  });

  test('hardLinkOrCopy links on a local filesystem', () async {
    final src = File(localJoin(tmp.path, 'src.txt'))..writeAsStringSync('hi');
    final dst = localJoin(tmp.path, 'snap/sub/dst.txt');
    expect(await hardLinkOrCopy(src.path, dst), true);
    expect(File(dst).readAsStringSync(), 'hi');
    final links = linkCount(dst);
    if (links != null) expect(links, 2);
  });

  test('hardLinkOrCopy falls back to a copy when linking fails', () async {
    final src = File(localJoin(tmp.path, 'src.txt'))..writeAsStringSync('v1');
    final dst = File(localJoin(tmp.path, 'dst.txt'))..writeAsStringSync('old');
    // link() refuses an existing target; the copy then overwrites it.
    expect(await hardLinkOrCopy(src.path, dst.path), false);
    expect(dst.readAsStringSync(), 'v1');
  });

  test('driveSpaceForPath reports the volume, even for a missing folder', () {
    final space = driveSpaceForPath(localJoin(tmp.path, 'not/yet/created'));
    if (!Platform.isWindows && !Platform.isMacOS) {
      expect(space, isNull);
      return;
    }
    expect(space, isNotNull);
    expect(space!.totalBytes, greaterThan(0));
    expect(space.freeBytes, inInclusiveRange(1, space.totalBytes));
    if (Platform.isMacOS) {
      // Cross-check the FFI struct layout against df's view of the volume.
      final df = Process.runSync('df', ['-k', tmp.path]).stdout as String;
      final totalKb = int.parse(df.trim().split('\n').last.split(RegExp(r'\s+'))[1]);
      expect(space.totalBytes ~/ 1024, totalKb);
    }
  });

  test('an unplugged /Volumes drive is detected, never measured', () {
    const path = '/Volumes/__androidfiles_no_such_drive__/PhoneBackup';
    if (Platform.isMacOS) {
      expect(unmountedVolume(path), '__androidfiles_no_such_drive__');
      expect(driveSpaceForPath(path), isNull);
      expect(unmountedVolume(tmp.path), isNull);
    } else {
      expect(unmountedVolume(path), isNull);
    }
  });

  test('":" and "\\" in phone filenames survive on macOS/Linux', () async {
    final x = TarExtractor(tmp.path);
    await x.add(tarFile(r'D/12:30 a\b.txt', 'ok'));
    await x.close();
    final f = File(localJoin(tmp.path, r'D/12:30 a\b.txt'));
    if (Platform.isWindows) {
      // ':' would name an alternate data stream there — skipped, not written.
      expect(x.filesWritten, 0);
    } else {
      expect(f.readAsStringSync(), 'ok');
      // …and the manifest keys it under the same name the phone uses, so the
      // next incremental run sees it as unchanged.
      final man = await localManifest(tmp.path, 'D');
      expect(man.keys, [r'D/12:30 a\b.txt']);
    }
  });

  test('Bonjour dns-sd line parsers and IPv6 MdnsService.ip', () {
    final added = AdbClient.parseBonjourBrowseLine(
      '19:06:19.862  Add        2  11 local.               _adb-tls-connect._tcp. adb-3B241FDJH002HF-G9VfIY',
    );
    expect(added, isNotNull);
    expect(added!.added, true);
    expect(added.instance, 'adb-3B241FDJH002HF-G9VfIY');

    final target = AdbClient.parseBonjourLookupLine(
      '19:06:44.139  adb-3B241FDJH002HF-G9VfIY._adb-tls-connect._tcp.local. can be reached at Android_K971XTXF.local.:44533 (interface 11)',
    );
    expect(target, ('Android_K971XTXF.local.', '44533'));

    const v4 = MdnsService(
      instance: 'adb-1',
      type: '_adb-tls-connect._tcp',
      address: '192.168.0.117:44533',
    );
    expect(v4.ip, '192.168.0.117');
    expect(v4.isIpv4, true);

    const v6 = MdnsService(
      instance: 'adb-1',
      type: '_adb-tls-connect._tcp',
      address: '[fe80::1a2b:3c4d]:44533',
    );
    expect(v6.ip, 'fe80::1a2b:3c4d');
    expect(v6.isIpv4, false);
  });

  test('dedupeTransports drops IPv6 duplicate when IPv4 shares port and model', () {
    final devices = [
      const AdbDevice(
        serial: '192.168.0.117:44533',
        state: 'device',
        model: 'Pixel 8',
      ),
      const AdbDevice(
        serial: '[fe80::5cd4:10ff:fe55:81a1%en0]:44533',
        state: 'device',
        model: 'Pixel 8',
      ),
    ];
    AppController.dedupeTransports(devices);
    expect(devices.map((d) => d.serial), ['192.168.0.117:44533']);
  });

  test('dedupeTransports collapses ip:port and _adb-tls-connect sharing ro.serialno', () {
    final samePhone = [
      const AdbDevice(
        serial: '192.168.0.116:36687',
        state: 'device',
        model: 'Pixel 8',
      ),
      const AdbDevice(
        serial: 'adb-3B241FDJH002HF-G9VfIY._adb-tls-connect._tcp',
        state: 'device',
        model: 'Pixel 8',
      ),
    ];
    AppController.dedupeTransports(
      samePhone,
      const [],
      const {'192.168.0.116:36687': '3B241FDJH002HF'},
    );
    expect(samePhone.map((d) => d.serial), ['192.168.0.116:36687']);

    // Two distinct Pixel 8s with different hardware serials must both stay.
    final twoPhones = [
      const AdbDevice(
        serial: '192.168.0.116:36687',
        state: 'device',
        model: 'Pixel 8',
      ),
      const AdbDevice(
        serial: 'adb-OTHER999999-AbCdEf._adb-tls-connect._tcp',
        state: 'device',
        model: 'Pixel 8',
      ),
    ];
    AppController.dedupeTransports(
      twoPhones,
      const [],
      const {'192.168.0.116:36687': '3B241FDJH002HF'},
    );
    expect(twoPhones.length, 2);
  });

  test('parseWifiLinkInfo parses 2.4 GHz, 5 GHz, 6 GHz, and dumpsys wifi output', () {
    const pixel24 =
        'WifiInfo: SSID: "IkeNet2206", Wi-Fi standard: 11n, RSSI: -61, '
        'Link speed: 173Mbps, Tx Link speed: 52Mbps, Frequency: 2427MHz';
    final info24 = AdbClient.parseWifiLinkInfo(pixel24);
    expect(info24, isNotNull);
    expect(info24!.linkSpeedMbps, 52); // prefers Tx link speed
    expect(info24.bandLabel, '2.4 GHz');
    expect(info24.isSlow24Ghz, isTrue);
    expect(info24.shortLabel, '2.4 GHz · 52 Mbps');
    expect(info24.rssiDbm, -61);
    expect(info24.detailTooltip, contains('2.4 GHz'));

    const wifi6 =
        'WifiInfo: SSID: "Home5G", Wi-Fi standard: 11ax, RSSI: -48, '
        'Link speed: 866Mbps, Tx Link speed: 1200Mbps, Frequency: 5200MHz';
    final info5 = AdbClient.parseWifiLinkInfo(wifi6);
    expect(info5!.bandLabel, '5 GHz');
    expect(info5.isSlow24Ghz, isFalse);
    expect(info5.shortLabel, '5 GHz · 1200 Mbps');

    const wifi6e =
        'mWifiInfo SSID: "Lab6E", Link speed: 2401Mbps, Frequency: 6175MHz, RSSI: -52';
    final info6 = AdbClient.parseWifiLinkInfo(wifi6e);
    expect(info6!.bandLabel, '6 GHz');
    expect(info6.shortLabel, '6 GHz · 2401 Mbps');

    expect(AdbClient.parseWifiLinkInfo('Wifi is disabled'), isNull);
    expect(AdbClient.parseWifiLinkInfo('Link speed: -1Mbps'), isNull);
  });
}
