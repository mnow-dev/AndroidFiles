import 'package:android_files/src/adb_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shellQuote escapes single quotes', () {
    expect(AdbClient.shellQuote('/sdcard/DCIM'), "'/sdcard/DCIM'");
    expect(AdbClient.shellQuote("it's"), "'it'\\''s'");
  });
}
