import 'package:android_files/src/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isRemoteNewer', () {
    test('a higher release is newer', () {
      expect(UpdateChecker.isRemoteNewer('v0.2.0', '0.1.0'), isTrue);
      expect(UpdateChecker.isRemoteNewer('v1.0.0', '0.9.9'), isTrue);
      expect(UpdateChecker.isRemoteNewer('v0.1.1', '0.1.0'), isTrue);
    });

    test('same or lower is not newer', () {
      expect(UpdateChecker.isRemoteNewer('v0.1.0', '0.1.0'), isFalse);
      expect(UpdateChecker.isRemoteNewer('v0.1.0', '0.2.0'), isFalse);
      expect(UpdateChecker.isRemoteNewer('v0.0.9', '0.1.0'), isFalse);
    });

    test('the v prefix is optional on either side', () {
      expect(UpdateChecker.isRemoteNewer('0.2.0', 'v0.1.0'), isTrue);
      expect(UpdateChecker.isRemoteNewer('V0.2.0', '0.1.0'), isTrue);
    });

    test('differing component counts compare by value, not length', () {
      expect(UpdateChecker.isRemoteNewer('v1', '0.9.9'), isTrue);
      expect(UpdateChecker.isRemoteNewer('v1.0', '1.0.0'), isFalse);
      expect(UpdateChecker.isRemoteNewer('v1.0.0.1', '1.0.0'), isTrue);
    });

    test('a pre-release suffix is dropped, so it ties the release', () {
      expect(UpdateChecker.isRemoteNewer('v0.2.0-beta', '0.2.0'), isFalse);
      expect(UpdateChecker.isRemoteNewer('v0.3.0-rc1', '0.2.0'), isTrue);
    });

    test('garbage never reports an update', () {
      expect(UpdateChecker.isRemoteNewer('nightly', '0.1.0'), isFalse);
      expect(UpdateChecker.isRemoteNewer('v1.x', '0.1.0'), isFalse);
      expect(UpdateChecker.isRemoteNewer('', '0.1.0'), isFalse);
    });
  });
}
