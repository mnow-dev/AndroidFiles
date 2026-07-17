import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateHardLinkWNative = Int32 Function(
    Pointer<Utf16> newFile, Pointer<Utf16> existingFile, Pointer<Void> reserved);
typedef _CreateHardLinkWDart = int Function(
    Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);

final _createHardLinkW = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<_CreateHardLinkWNative, _CreateHardLinkWDart>('CreateHardLinkW');

/// Hardlink [existing] to [link]; falls back to a copy if linking fails
/// (e.g. FAT destination or >1023 links to one file). Returns true if the
/// result was a hardlink, false if it was a copy.
Future<bool> hardLinkOrCopy(String existing, String link) async {
  await Directory(File(link).parent.path).create(recursive: true);
  final linkP = link.toNativeUtf16();
  final existingP = existing.toNativeUtf16();
  try {
    if (_createHardLinkW(linkP, existingP, nullptr) != 0) return true;
  } finally {
    calloc.free(linkP);
    calloc.free(existingP);
  }
  await File(existing).copy(link);
  return false;
}
