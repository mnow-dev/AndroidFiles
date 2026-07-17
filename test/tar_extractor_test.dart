import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_files/src/tar_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List header(String name, int size, String type, {int mtime = 1700000000}) {
  final h = Uint8List(512);
  final nameBytes = utf8.encode(name);
  h.setRange(0, nameBytes.length, nameBytes);
  h.setRange(124, 136, ascii.encode('${size.toRadixString(8).padLeft(11, '0')} '));
  h.setRange(136, 148, ascii.encode('${mtime.toRadixString(8).padLeft(11, '0')} '));
  h[156] = type.codeUnitAt(0);
  return h;
}

Uint8List padded(List<int> payload) =>
    Uint8List((payload.length + 511) & ~511)..setRange(0, payload.length, payload);

void main() {
  late Directory dest;

  setUp(() => dest = Directory.systemTemp.createTempSync('tarx_'));
  tearDown(() => dest.deleteSync(recursive: true));

  test('extracts UTF-8 names, restores mtime, skips traversal', () async {
    const mtime = 1706053130;
    final longName = 'D/${'x' * 120}.bin';
    final archive = BytesBuilder()
      ..add(header('D/', 0, '5'))
      ..add(header('D/zażółć gęślą.txt', utf8.encode('jaźń').length, '0', mtime: mtime))
      ..add(padded(utf8.encode('jaźń')))
      ..add(header('././@LongLink', utf8.encode(longName).length, 'L'))
      ..add(padded(utf8.encode(longName)))
      ..add(header('ignored', 2, '0'))
      ..add(padded(ascii.encode('ok')))
      ..add(header('../evil.txt', 5, '0'))
      ..add(padded(ascii.encode('bad!!')))
      ..add(header('D/empty.txt', 0, '0'))
      ..add(Uint8List(1024));

    final x = TarExtractor(dest.path);
    final bytes = archive.takeBytes();
    for (var i = 0; i < bytes.length; i += 100) {
      await x.add(bytes.sublist(i, i + 100 > bytes.length ? bytes.length : i + 100));
    }
    await x.close();

    expect(x.filesWritten, 3);
    final utf8File = File('${dest.path}\\D\\zażółć gęślą.txt');
    expect(utf8File.existsSync(), true);
    expect(utf8File.statSync().modified.toUtc(),
        DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true));
    expect(File('${dest.path}\\$longName'.replaceAll('/', '\\')).readAsStringSync(),
        'ok');
    expect(File('${dest.path}\\empty.txt').existsSync(), false);
    expect(File('${dest.path}\\D\\empty.txt').existsSync(), true);
    expect(File('${dest.path}\\evil.txt').existsSync(), false);
    expect(x.warnings.any((w) => w.contains('evil')), true);
  });

  test('truncated stream removes the incomplete file, keeps complete ones',
      () async {
    final archive = BytesBuilder()
      ..add(header('good.txt', 2, '0'))
      ..add(padded(ascii.encode('ok')))
      ..add(header('cut.bin', 4096, '0'))
      ..add(Uint8List(512)); // only 512 of 4096 payload bytes arrive

    final x = TarExtractor(dest.path);
    await x.add(archive.takeBytes());
    await x.close(); // simulates a cancelled/killed stream

    expect(File('${dest.path}\\good.txt').readAsStringSync(), 'ok');
    expect(File('${dest.path}\\cut.bin').existsSync(), false);
    expect(x.warnings.any((w) => w.contains('incomplete')), true);
  });

  test('pax path and mtime records override the header', () async {
    const paxPath = 'D/päx überride.dat';
    String rec(String key, String value) {
      // pax record length counts BYTES of the whole record, itself included
      final bodyBytes = utf8.encode(' $key=$value\n').length;
      var len = bodyBytes + 1;
      while ('$len'.length + bodyBytes != len) {
        len = '$len'.length + bodyBytes;
      }
      return '$len $key=$value\n';
    }

    final pax = utf8.encode(rec('path', paxPath) + rec('mtime', '1600000000'));
    final archive = BytesBuilder()
      ..add(header('PaxHeaders.0/short', pax.length, 'x'))
      ..add(padded(pax))
      ..add(header('D/short.dat', 3, '0'))
      ..add(padded(ascii.encode('abc')))
      ..add(Uint8List(1024));

    final x = TarExtractor(dest.path);
    await x.add(archive.takeBytes());
    await x.close();

    final f = File('${dest.path}\\D\\päx überride.dat');
    expect(f.readAsStringSync(), 'abc');
    expect(f.statSync().modified.toUtc(),
        DateTime.fromMillisecondsSinceEpoch(1600000000 * 1000, isUtc: true));
  });
}
