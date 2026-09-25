import 'package:android_files/src/backup_engine.dart';
import 'package:android_files/src/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, FileMeta> sizes(Map<String, int> byRel) => {
      for (final e in byRel.entries)
        e.key: FileMeta(e.value, 0),
    };

int loadOf(List<String> shard, Map<String, FileMeta> meta) =>
    shard.fold(0, (sum, rel) => sum + (meta[rel]?.size ?? 0));

void main() {
  group('shardByBytes', () {
    test('a single shard keeps the list intact', () {
      final meta = sizes({'a': 1, 'b': 2});
      expect(BackupEngine.shardByBytes(['a', 'b'], meta, 1), [
        ['a', 'b']
      ]);
    });

    test('every file lands in exactly one shard', () {
      final meta = sizes({for (var i = 0; i < 50; i++) 'f$i': i * 1000});
      final shards = BackupEngine.shardByBytes(meta.keys.toList(), meta, 8);
      final flat = shards.expand((s) => s).toList();
      expect(flat.length, 50);
      expect(flat.toSet(), meta.keys.toSet());
    });

    test('balances evenly when no file exceeds its share', () {
      // Mixed sizes, none dominant: the shards should come out near-equal.
      final meta = sizes({for (var i = 1; i <= 40; i++) 'f$i': i * 10000});
      final shards = BackupEngine.shardByBytes(meta.keys.toList(), meta, 4);
      final loads = [for (final s in shards) loadOf(s, meta)];
      final ideal = loads.reduce((a, b) => a + b) / 4;
      // Within 5% of a perfect split.
      for (final l in loads) {
        expect((l - ideal).abs() / ideal, lessThan(0.05));
      }
    });

    test('one dominant file does not drag the other shards down with it', () {
      // A file bigger than an even share sets the floor on the transfer — no
      // split can beat it. What matters is that it goes in a shard of its own
      // and the rest spread evenly, instead of a count-based split handing it
      // a quarter of the small files to drag along behind it.
      final meta = sizes({
        'huge': 1000000,
        for (var i = 0; i < 40; i++) 'tiny$i': 25000,
      });
      final shards = BackupEngine.shardByBytes(meta.keys.toList(), meta, 4);
      final huge = shards.firstWhere((s) => s.contains('huge'));
      expect(huge, ['huge'], reason: 'the big file should travel alone');
      final rest = [
        for (final s in shards)
          if (!s.contains('huge')) loadOf(s, meta)
      ];
      // The remaining 1 MB of tiny files split three ways, evenly.
      final spread = rest.reduce((a, b) => a > b ? a : b) -
          rest.reduce((a, b) => a < b ? a : b);
      expect(spread, lessThanOrEqualTo(25000));
    });

    test('more shards than files yields no empty shards', () {
      final meta = sizes({'a': 10, 'b': 20});
      final shards = BackupEngine.shardByBytes(['a', 'b'], meta, 8);
      expect(shards.length, 2);
      expect(shards.any((s) => s.isEmpty), isFalse);
    });

    test('files missing from the manifest are still transferred', () {
      // A file that appeared after the manifest scan has no size; it must not
      // be dropped from the shards just because it can't be weighed.
      final meta = sizes({'known': 500});
      final shards = BackupEngine.shardByBytes(['known', 'unknown'], meta, 2);
      expect(shards.expand((s) => s).toSet(), {'known', 'unknown'});
    });
  });
}
