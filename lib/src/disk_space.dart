import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'os.dart';

/// Free/total bytes on the volume that holds a local path.
class DriveSpace {
  final String root; // e.g. "V:\" on Windows, "Neptune-Ext" or "/" on macOS
  final int freeBytes;
  final int totalBytes;
  const DriveSpace(this.root, this.freeBytes, this.totalBytes);
}

/// Free/total space for the drive that holds [path], or null if it can't be
/// determined (unsupported platform, no drive letter, unmounted volume). Works
/// before the destination folder itself exists.
DriveSpace? driveSpaceForPath(String path) {
  if (path.trim().isEmpty) return null;
  if (Platform.isWindows) return _windowsSpace(path);
  if (Platform.isMacOS) return _macSpace(path);
  return null;
}

// --- Windows: GetDiskFreeSpaceExW on the drive root ---

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

DriveSpace? _windowsSpace(String path) {
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

// --- macOS: statfs(2) on the nearest existing ancestor ---

/// Darwin's 64-bit-inode `struct statfs` (`<sys/mount.h>`), 2168 bytes. Only
/// the block counters and the mount path are read; the rest pins the layout.
final class _StatFs extends Struct {
  @Uint32()
  external int bsize;
  @Int32()
  external int iosize;
  @Uint64()
  external int blocks;
  @Uint64()
  external int bfree;
  @Uint64()
  external int bavail;
  @Uint64()
  external int files;
  @Uint64()
  external int ffree;
  @Array(2)
  external Array<Int32> fsid;
  @Uint32()
  external int owner;
  @Uint32()
  external int type;
  @Uint32()
  external int flags;
  @Uint32()
  external int fssubtype;
  @Array(16)
  external Array<Uint8> fstypename;
  @Array(1024)
  external Array<Uint8> mntonname;
  @Array(1024)
  external Array<Uint8> mntfromname;
  @Uint32()
  external int flagsExt;
  @Array(7)
  external Array<Uint32> reserved;
}

typedef _StatFsNative = Int32 Function(Pointer<Utf8>, Pointer<_StatFs>);
typedef _StatFsDart = int Function(Pointer<Utf8>, Pointer<_StatFs>);

/// arm64 has only the 64-bit-inode statfs; on x86_64 that layout is exported
/// as `statfs$INODE64` and plain `statfs` is the legacy struct.
final _statfs = Platform.isMacOS ? _lookupStatfs() : null;

_StatFsDart _lookupStatfs() {
  final libc = DynamicLibrary.process();
  final name = libc.providesSymbol(r'statfs$INODE64')
      ? r'statfs$INODE64'
      : 'statfs';
  return libc.lookupFunction<_StatFsNative, _StatFsDart>(name);
}

DriveSpace? _macSpace(String path) {
  final fn = _statfs;
  if (fn == null) return null;
  // An unplugged drive's /Volumes path would walk up to the startup disk and
  // report its space instead — show nothing rather than the wrong drive.
  if (unmountedVolume(path) != null) return null;
  var dir = Directory(path.trim()).absolute;
  while (!dir.existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }

  final pathPtr = dir.path.toNativeUtf8();
  final buf = calloc<_StatFs>();
  try {
    if (fn(pathPtr, buf) != 0) return null;
    final s = buf.ref;
    final mount = _cString(s.mntonname, 1024);
    // The startup disk's writable half is mounted at /System/Volumes/Data;
    // "/" is how people know it. External drives go by their volume name.
    final label = mount.startsWith('/Volumes/')
        ? mount.substring('/Volumes/'.length)
        : '/';
    return DriveSpace(label, s.bavail * s.bsize, s.blocks * s.bsize);
  } finally {
    calloc.free(pathPtr);
    calloc.free(buf);
  }
}

String _cString(Array<Uint8> a, int max) {
  final bytes = <int>[];
  for (var i = 0; i < max && a[i] != 0; i++) {
    bytes.add(a[i]);
  }
  return utf8.decode(bytes, allowMalformed: true);
}
