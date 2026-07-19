import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Free/total bytes on the volume that holds a Windows path.
class DriveSpace {
  final String root; // e.g. "V:\"
  final int freeBytes;
  final int totalBytes;
  const DriveSpace(this.root, this.freeBytes, this.totalBytes);
}

typedef _GetDiskFreeSpaceExNative =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );
typedef _GetDiskFreeSpaceExDart =
    int Function(
      Pointer<Utf16>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );

final _getDiskFreeSpaceEx = Platform.isWindows
    ? DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_GetDiskFreeSpaceExNative, _GetDiskFreeSpaceExDart>(
            'GetDiskFreeSpaceExW',
          )
    : null;

/// The drive letter root (`V:\`) of a Windows path, or null for UNC/relative.
String? driveRootOf(String path) {
  final m = RegExp(r'^([A-Za-z]):').firstMatch(path.trim());
  return m == null ? null : '${m.group(1)!.toUpperCase()}:\\';
}

/// Free/total space for the drive that holds [path], or null if it can't be
/// determined (non-Windows, no drive letter, unmounted volume). Queries the
/// drive root, so it works even before the destination folder itself exists.
DriveSpace? driveSpaceForPath(String path) {
  final fn = _getDiskFreeSpaceEx;
  if (fn == null) return null;
  final root = driveRootOf(path);
  if (root == null) return null;

  final rootPtr = root.toNativeUtf16();
  final freeAvail = calloc<Uint64>();
  final totalBytes = calloc<Uint64>();
  final totalFree = calloc<Uint64>();
  try {
    if (fn(rootPtr, freeAvail, totalBytes, totalFree) == 0) return null;
    return DriveSpace(root, freeAvail.value, totalBytes.value);
  } finally {
    calloc.free(rootPtr);
    calloc.free(freeAvail);
    calloc.free(totalBytes);
    calloc.free(totalFree);
  }
}
