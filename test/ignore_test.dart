import 'package:android_files/src/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool ignored(String path, List<String> patterns) =>
      isIgnored(path, compileIgnorePatterns(patterns));

  group('ignore matching', () {
    test('a single-segment pattern matches that directory at any depth', () {
      expect(ignored('DCIM/.thumbnails/1.jpg', ['.thumbnails']), isTrue);
      expect(ignored('.thumbnails/1.jpg', ['.thumbnails']), isTrue);
      expect(ignored('Pictures/x/.thumbnails/y.png', ['.thumbnails']), isTrue);
    });

    test('the leading dot is significant', () {
      expect(ignored('DCIM/thumbnails/1.jpg', ['.thumbnails']), isFalse);
    });

    test('a multi-segment pattern matches only consecutive segments', () {
      expect(ignored('Android/data/com.app/c', ['Android/data']), isTrue);
      expect(ignored('sdcard/Android/data/f', ['Android/data']), isTrue);
      expect(ignored('Android/media/f', ['Android/data']), isFalse);
      expect(ignored('data/f', ['Android/data']), isFalse);
    });

    test('* and ? are wildcards within a segment', () {
      expect(ignored('.trashed-172-a.jpg', ['.trashed-*']), isTrue);
      expect(ignored('.thumbdata3--196', ['.thumbdata*']), isTrue);
      expect(ignored('LOST.DIR/f00', ['LOST.DI?']), isTrue);
    });

    test('a wildcard never crosses a path separator', () {
      expect(ignored('a/b.txt', ['a*b']), isFalse);
    });

    test('matching is case-insensitive', () {
      expect(ignored('lost.dir/frag', ['LOST.DIR']), isTrue);
    });

    test('ordinary files are kept', () {
      expect(ignored('DCIM/Camera/IMG_0001.jpg', defaultClutterPatterns), isFalse);
      expect(ignored('Download/report.pdf', defaultClutterPatterns), isFalse);
    });

    test('the default set catches common clutter', () {
      expect(ignored('DCIM/.thumbnails/t.jpg', defaultClutterPatterns), isTrue);
      expect(ignored('Android/obb/game/main.obb', defaultClutterPatterns), isTrue);
      expect(ignored('LOST.DIR/0001', defaultClutterPatterns), isTrue);
    });

    test('blank patterns are ignored, empty list matches nothing', () {
      expect(compileIgnorePatterns(['', '   ']), isEmpty);
      expect(ignored('anything/at/all', const []), isFalse);
    });
  });
}
