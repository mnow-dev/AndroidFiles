/// The tree's backup selection as two path sets: [checked] folders/files that
/// are in, and [excluded] carve-outs unticked under a checked ancestor. For
/// any path, the NEAREST ancestor-or-self appearing in either set decides —
/// so a checked folder minus an excluded child keeps the rest, and re-ticking
/// that child brings it back.
bool _covers(String prefix, String path) =>
    path == prefix || path.startsWith('$prefix/');

/// Whether [path] ends up in the backup under [checked]/[excluded].
bool isPathSelected(String path, Set<String> checked, Set<String> excluded) {
  var best = -1;
  var selected = false;
  for (final c in checked) {
    if (_covers(c, path) && c.length > best) {
      best = c.length;
      selected = true;
    }
  }
  for (final e in excluded) {
    if (_covers(e, path) && e.length > best) {
      best = e.length;
      selected = false;
    }
  }
  return selected;
}

/// Flip [path]'s membership, mutating [checked]/[excluded] in place: turn it
/// off by dropping a direct check or carving it out of a checked parent; turn
/// it on by lifting a direct exclude or adding a fresh check. Either way, drop
/// now-redundant descendants of [path].
void togglePath(String path, Set<String> checked, Set<String> excluded) {
  if (isPathSelected(path, checked, excluded)) {
    if (!checked.remove(path)) excluded.add(path);
  } else {
    if (!excluded.remove(path)) checked.add(path);
  }
  checked.removeWhere((p) => p != path && p.startsWith('$path/'));
  excluded.removeWhere((p) => p != path && p.startsWith('$path/'));
}
