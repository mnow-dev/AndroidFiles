import 'package:android_files/src/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseDeviceManifest strips parent and skips malformed lines', () {
    const raw = '137307|1706053130|/sdcard/Documents/a.pdf\n'
        'garbage line without pipes\n'
        '114323|1707181867|/sdcard/Documents/sub/Zażółć gęślą.pdf\n'
        '99|123|/elsewhere/outside.txt\n';
    final m = parseDeviceManifest(raw, '/sdcard');
    expect(m.length, 2);
    expect(m['Documents/a.pdf']!.size, 137307);
    expect(m['Documents/sub/Zażółć gęślą.pdf']!.mtimeSec, 1707181867);
  });

  test('parseMd5Manifest extracts hashes and normalizes case', () {
    const raw = 'bd06942a63d197784f24cab5088c17a2  /sdcard/Documents/a.pdf\n'
        'md5sum: /sdcard/Documents/locked.pdf: Permission denied\n'
        '2019A99E2D7C214F44E9ADDB7F244DA8  /sdcard/Documents/sub/ż ó.pdf\n';
    final m = parseMd5Manifest(raw, '/sdcard');
    expect(m.length, 2);
    expect(m['Documents/a.pdf'], 'bd06942a63d197784f24cab5088c17a2');
    expect(m['Documents/sub/ż ó.pdf'], '2019a99e2d7c214f44e9addb7f244da8');
  });

  test('diffManifests classifies changed, unchanged, localOnly', () {
    final device = {
      'D/same.jpg': const FileMeta(100, 1000),
      'D/mtime-close.jpg': const FileMeta(100, 1001),
      'D/mtime-far.jpg': const FileMeta(100, 1010),
      'D/size-diff.jpg': const FileMeta(101, 1000),
      'D/new.jpg': const FileMeta(5, 1000),
    };
    final local = {
      'D/same.jpg': const FileMeta(100, 1000),
      'D/mtime-close.jpg': const FileMeta(100, 1000),
      'D/mtime-far.jpg': const FileMeta(100, 1000),
      'D/size-diff.jpg': const FileMeta(100, 1000),
      'D/deleted-on-device.jpg': const FileMeta(7, 900),
    };
    final diff = diffManifests(device, local);
    expect(diff.unchanged, unorderedEquals(['D/same.jpg', 'D/mtime-close.jpg']));
    expect(diff.changed,
        unorderedEquals(['D/mtime-far.jpg', 'D/size-diff.jpg', 'D/new.jpg']));
    expect(diff.localOnly, ['D/deleted-on-device.jpg']);
  });
}
