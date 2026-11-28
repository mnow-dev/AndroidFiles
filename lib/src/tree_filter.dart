import 'models.dart';

/// Filter criteria for the Device Folders tree (filename/extension search and
/// "Not backed up" status toggle).
class TreeFilter {
  final String query;
  final bool onlyUnbackedUp;

  const TreeFilter({
    this.query = '',
    this.onlyUnbackedUp = false,
  });

  String get _needle => query.trim().toLowerCase();

  bool get isActive => _needle.isNotEmpty || onlyUnbackedUp;

  /// True for entries that have not yet been fully backed up locally.
  static bool needsBackup(EntryBackupStatus? status) =>
      status == EntryBackupStatus.notBackedUp ||
      status == EntryBackupStatus.modified ||
      status == EntryBackupStatus.partial;

  /// Whether [entry] (or any loaded descendant of [entry]) satisfies this
  /// filter. [ancestorMatchedQuery] is true when an expanded parent folder's
  /// own name already matched [query], so its children remain browsable.
  bool matches(
    RemoteEntry entry, {
    required Map<String, EntryBackupStatus> statuses,
    required Map<String, List<RemoteEntry>> children,
    bool ancestorMatchedQuery = false,
  }) {
    if (!isActive) return true;
    final needle = _needle;
    final nameMatched =
        needle.isEmpty || ancestorMatchedQuery || entry.name.toLowerCase().contains(needle);
    final statusMatched = !onlyUnbackedUp || needsBackup(statuses[entry.path]);
    if (nameMatched && statusMatched) return true;

    if (entry.isDir) {
      final kids = children[entry.path];
      if (kids != null) {
        final nextAncestor =
            ancestorMatchedQuery || (needle.isNotEmpty && entry.name.toLowerCase().contains(needle));
        for (final child in kids) {
          if (matches(
            child,
            statuses: statuses,
            children: children,
            ancestorMatchedQuery: nextAncestor,
          )) {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// Whether [entry]'s own name matches [query] (used to propagate
  /// `ancestorMatchedQuery` when recursing into an expanded directory).
  bool nameMatchesQuery(RemoteEntry entry) {
    final needle = _needle;
    return needle.isNotEmpty && entry.name.toLowerCase().contains(needle);
  }
}
