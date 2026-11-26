import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateHardLinkWNative = Int32 Function(
    Pointer<Utf16> newFile, Pointer<Utf16> existingFile, Pointer<Void> reserved);
typedef _CreateHardLinkWDart = int Function(
    Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);

typedef _LinkNative = Int32 Function(Pointer<Utf8> existing, Pointer<Utf8> link);
typedef _LinkDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

/// The platform's "make a hardlink" call; true on success. Resolved on first
/// use (top-level finals are lazy), so neither side's library is touched on
/// the other platform.
final bool Function(String existing, String link) _hardLink = _resolve();

bool Function(String, String) _resolve() {
  if (Platform.isWindows) {
    final fn = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_CreateHardLinkWNative, _CreateHardLinkWDart>(
            'CreateHardLinkW');
    return (existing, link) {
      final linkP = link.toNativeUtf16();
      final existingP = existing.toNativeUtf16();
      try {
        return fn(linkP, existingP, nullptr) != 0;
      } finally {
        calloc.free(linkP);
        calloc.free(existingP);
      }
    };
  }
  // POSIX link(2); libc is already loaded into the process.
  final fn =
      DynamicLibrary.process().lookupFunction<_LinkNative, _LinkDart>('link');
  return (existing, link) {
    final existingP = existing.toNativeUtf8();
    final linkP = link.toNativeUtf8();
    try {
      return fn(existingP, linkP) == 0;
    } finally {
      calloc.free(existingP);
      calloc.free(linkP);
    }
  };
}

/// Hardlink [existing] to [link]; falls back to a copy if linking fails
/// (e.g. a FAT/exFAT destination, or >1023 links to one file on NTFS).
/// Returns true if the result was a hardlink, false if it was a copy.
Future<bool> hardLinkOrCopy(String existing, String link) async {
  await Directory(File(link).parent.path).create(recursive: true);
  if (_hardLink(existing, link)) return true;
  await File(existing).copy(link);
  return false;
}
