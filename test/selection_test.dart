import 'package:android_files/src/selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isPathSelected', () {
    test('a checked folder covers itself and its descendants', () {
      final checked = {'/sdcard/DCIM'};
      final excluded = <String>{};
      expect(isPathSelected('/sdcard/DCIM', checked, excluded), isTrue);
      expect(isPathSelected('/sdcard/DCIM/Camera', checked, excluded), isTrue);
      expect(isPathSelected('/sdcard/DCIM/Camera/a.jpg', checked, excluded),
          isTrue);
    });

    test('siblings of a checked folder are not selected', () {
      expect(isPathSelected('/sdcard/Music', {'/sdcard/DCIM'}, {}), isFalse);
      expect(isPathSelected('/sdcard', {'/sdcard/DCIM'}, {}), isFalse);
    });

    test('a prefix is a path boundary, not a substring', () {
      // /sdcard/DCIM must not cover /sdcard/DCIM2.
      expect(isPathSelected('/sdcard/DCIM2/x', {'/sdcard/DCIM'}, {}), isFalse);
    });

    test('an exclude carves a subtree out of a checked ancestor', () {
      final checked = {'/sdcard/DCIM'};
      final excluded = {'/sdcard/DCIM/Camera'};
      expect(isPathSelected('/sdcard/DCIM', checked, excluded), isTrue);
      expect(isPathSelected('/sdcard/DCIM/Camera', checked, excluded), isFalse);
      expect(isPathSelected('/sdcard/DCIM/Camera/a.jpg', checked, excluded),
          isFalse);
      expect(isPathSelected('/sdcard/DCIM/Screenshots', checked, excluded),
          isTrue);
    });

    test('the deepest directive wins (re-include under an exclude)', () {
      final checked = {'/sdcard/DCIM', '/sdcard/DCIM/Camera/keep'};
      final excluded = {'/sdcard/DCIM/Camera'};
      expect(
          isPathSelected('/sdcard/DCIM/Camera/keep', checked, excluded), isTrue);
      expect(isPathSelected('/sdcard/DCIM/Camera/keep/x', checked, excluded),
          isTrue);
      expect(isPathSelected('/sdcard/DCIM/Camera/other', checked, excluded),
          isFalse);
    });
  });

  group('togglePath', () {
    test('toggling a fresh path checks it', () {
      final checked = <String>{};
      final excluded = <String>{};
      togglePath('/sdcard/DCIM', checked, excluded);
      expect(checked, {'/sdcard/DCIM'});
      expect(excluded, isEmpty);
    });

    test('unticking a child under a checked parent excludes it', () {
      final checked = {'/sdcard/DCIM'};
      final excluded = <String>{};
      togglePath('/sdcard/DCIM/Camera', checked, excluded);
      expect(checked, {'/sdcard/DCIM'});
      expect(excluded, {'/sdcard/DCIM/Camera'});
      expect(isPathSelected('/sdcard/DCIM/Camera', checked, excluded), isFalse);
    });

    test('re-ticking an excluded child lifts the exclude', () {
      final checked = {'/sdcard/DCIM'};
      final excluded = {'/sdcard/DCIM/Camera'};
      togglePath('/sdcard/DCIM/Camera', checked, excluded);
      expect(excluded, isEmpty);
      expect(isPathSelected('/sdcard/DCIM/Camera', checked, excluded), isTrue);
    });

    test('unchecking a parent clears its now-redundant excludes', () {
      final checked = {'/sdcard/DCIM'};
      final excluded = {'/sdcard/DCIM/Camera'};
      togglePath('/sdcard/DCIM', checked, excluded);
      expect(checked, isEmpty);
      expect(excluded, isEmpty);
    });

    test('checking a folder drops redundant checked descendants', () {
      final checked = {'/sdcard/DCIM/Camera'};
      final excluded = <String>{};
      togglePath('/sdcard/DCIM', checked, excluded);
      expect(checked, {'/sdcard/DCIM'});
    });

    test('a direct check toggles straight back off', () {
      final checked = {'/sdcard/DCIM'};
      final excluded = <String>{};
      togglePath('/sdcard/DCIM', checked, excluded);
      expect(checked, isEmpty);
      expect(excluded, isEmpty);
    });
  });
}
