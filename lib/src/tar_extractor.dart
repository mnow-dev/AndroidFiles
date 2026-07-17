import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Streaming ustar/pax extractor.
///
/// Replaces Windows' bundled bsdtar, which interprets the UTF-8 names in
/// toybox's ustar headers using the ANSI codepage and mangles non-ASCII
/// filenames. Extracting natively also lets us restore mtimes exactly
/// (incremental compares depend on them) and reject path traversal.
class TarExtractor {
  final String destDir;

  /// Entry currently streaming (archive-relative), for progress display.
  String? currentPath;

  /// Regular files fully written so far.
  int filesWritten = 0;

  final List<String> warnings = [];

  TarExtractor(this.destDir);

  final _header = BytesBuilder(copy: false);
  int _payload = 0; // unpadded payload bytes left in current entry
  int _padding = 0; // block padding after the payload

  RandomAccessFile? _out;
  String? _outPath;
  DateTime? _outMtime;

  BytesBuilder? _capture; // payload capture for extension entries
  bool _captureIsPax = false;
  String? _pendingName;
  double? _pendingMtime;
  int? _pendingSize;

  /// Feed archive bytes. Await it — disk writes provide the backpressure.
  Future<void> add(List<int> data) async {
    final chunk = data is Uint8List ? data : Uint8List.fromList(data);
    var i = 0;
    while (i < chunk.length) {
      if (_payload > 0) {
        final n = min(_payload, chunk.length - i);
        final part = Uint8List.sublistView(chunk, i, i + n);
        if (_out != null) {
          await _out!.writeFrom(part);
        } else {
          _capture?.add(part);
        }
        _payload -= n;
        i += n;
        if (_payload == 0) await _finishEntry();
        continue;
      }
      if (_padding > 0) {
        final n = min(_padding, chunk.length - i);
        _padding -= n;
        i += n;
        continue;
      }
      final n = min(512 - _header.length, chunk.length - i);
      _header.add(Uint8List.sublistView(chunk, i, i + n));
      i += n;
      if (_header.length == 512) {
        final block = Uint8List.fromList(_header.takeBytes());
        await _startEntry(block);
      }
    }
  }

  Future<void> close() async {
    if (_out != null) {
      await _out!.close();
      _out = null;
      // A truncated file must not masquerade as a good copy — remove it;
      // the next (incremental) run re-transfers it.
      try {
        await File(_outPath!).delete();
        warnings.add('Removed incomplete file (stream ended mid-transfer): '
            '$_outPath');
      } catch (_) {
        warnings.add('Archive ended mid-file: $_outPath — file is incomplete');
      }
      _outPath = null;
    }
  }

  Future<void> _startEntry(Uint8List h) async {
    if (h.every((b) => b == 0)) return; // end-of-archive marker

    var size = _num(h, 124, 12);
    final type = h[156];

    if (type == 0x4C /* GNU longname */ || type == 0x78 /* pax header */) {
      _capture = BytesBuilder(copy: true);
      _captureIsPax = type == 0x78;
      _payload = size;
      _padding = (512 - size % 512) % 512;
      if (size == 0) await _finishEntry();
      return;
    }
    if (type == 0x67 /* pax global header — irrelevant, skip payload */) {
      _payload = size;
      _padding = (512 - size % 512) % 512;
      return;
    }

    size = _pendingSize ?? size;
    final rawName = _pendingName ?? _entryName(h);
    final mtime = _pendingMtime ?? _num(h, 136, 12).toDouble();
    _pendingName = null;
    _pendingMtime = null;
    _pendingSize = null;

    _payload = size;
    _padding = (512 - size % 512) % 512;
    currentPath = rawName;

    final rel = _sanitize(rawName);
    if (rel == null) {
      warnings.add('Skipped suspicious path in archive: $rawName');
      return; // payload gets skipped (_out and _capture are null)
    }
    final abs = '$destDir\\$rel';

    if (type == 0x35 /* '5' directory */) {
      await Directory(abs).create(recursive: true);
      return;
    }
    if (type == 0x30 /* '0' */ || type == 0 /* legacy regular file */) {
      final f = File(abs);
      await f.parent.create(recursive: true);
      _out = await f.open(mode: FileMode.write);
      _outPath = abs;
      _outMtime =
          DateTime.fromMillisecondsSinceEpoch((mtime * 1000).round(), isUtc: true);
      if (size == 0) await _finishEntry();
      return;
    }
    // Symlinks/hardlinks/devices don't map onto a Windows backup copy.
    warnings.add(
        "Skipped entry type '${String.fromCharCode(type)}' in archive: $rawName");
  }

  Future<void> _finishEntry() async {
    final out = _out;
    if (out != null) {
      await out.close();
      _out = null;
      filesWritten++;
      try {
        await File(_outPath!).setLastModified(_outMtime!.toLocal());
      } catch (_) {
        // Progress matters more than a lost timestamp.
      }
      _outPath = null;
      _outMtime = null;
      return;
    }
    final capture = _capture;
    if (capture != null) {
      _capture = null;
      final payload = capture.takeBytes();
      if (_captureIsPax) {
        _parsePax(payload);
      } else {
        _pendingName = _cstr(payload, 0, payload.length);
      }
    }
  }

  void _parsePax(Uint8List payload) {
    // Records are "<len> <key>=<value>\n" where len counts the whole record.
    var off = 0;
    while (off < payload.length) {
      final sp = payload.indexOf(0x20, off);
      if (sp == -1) break;
      final len = int.tryParse(ascii.decode(payload.sublist(off, sp)));
      if (len == null || len <= 0 || off + len > payload.length) break;
      final record =
          utf8.decode(payload.sublist(sp + 1, off + len - 1), allowMalformed: true);
      final eq = record.indexOf('=');
      if (eq != -1) {
        final key = record.substring(0, eq);
        final value = record.substring(eq + 1);
        switch (key) {
          case 'path':
            _pendingName = value;
          case 'mtime':
            _pendingMtime = double.tryParse(value);
          case 'size':
            _pendingSize = int.tryParse(value);
        }
      }
      off += len;
    }
  }

  /// Windows-relative safe path, or null if the entry must not be written.
  static String? _sanitize(String name) {
    var n = name.replaceAll('\\', '/');
    while (n.startsWith('./')) {
      n = n.substring(2);
    }
    if (n.endsWith('/')) n = n.substring(0, n.length - 1);
    if (n.isEmpty || n.startsWith('/') || n.contains(':')) return null;
    final segments = n.split('/');
    if (segments.any((s) => s == '..' || s == '.' || s.isEmpty)) return null;
    return segments.join('\\');
  }

  static int _num(Uint8List h, int off, int len) {
    if (h[off] & 0x80 != 0) {
      // GNU base-256 for values that don't fit in octal
      var v = h[off] & 0x7F;
      for (var i = off + 1; i < off + len; i++) {
        v = (v << 8) | h[i];
      }
      return v;
    }
    final s = _cstr(h, off, off + len).trim();
    return s.isEmpty ? 0 : int.parse(s, radix: 8);
  }

  static String _entryName(Uint8List h) {
    final name = _cstr(h, 0, 100);
    final prefix = _cstr(h, 345, 500);
    return prefix.isEmpty ? name : '$prefix/$name';
  }

  static String _cstr(Uint8List b, int start, int end) {
    var e = start;
    while (e < end && e < b.length && b[e] != 0) {
      e++;
    }
    return utf8.decode(b.sublist(start, e), allowMalformed: true);
  }
}
