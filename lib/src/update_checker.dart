import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The app's own version. Keep in sync with pubspec.yaml's `version:` — the
/// update check compares this against the latest GitHub release tag, so if it
/// drifts below the real shipped version the app nags about an update that is
/// already installed.
const appVersion = '0.1.3';

const _releasesApi =
    'https://api.github.com/repos/mnow-dev/AndroidFiles/releases/latest';

class UpdateInfo {
  final String version; // normalised, e.g. "0.2.0"
  final String url; // release page to open
  const UpdateInfo(this.version, this.url);
}

/// Checks GitHub Releases for a newer build. This is the notify-only half of
/// "auto-update": it never downloads or swaps anything, just points the user
/// at the release page. Kept deliberately incapable of failing loudly — a
/// background check on launch must not be able to take the app down.
class UpdateChecker {
  /// Details of a newer release, or null if up to date, offline, rate-limited,
  /// or anything unexpected. Never throws.
  static Future<UpdateInfo?> latestIfNewer({
    String current = appVersion,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(_releasesApi));
      // GitHub's API rejects requests without a User-Agent.
      req.headers.set(HttpHeaders.userAgentHeader, 'AndroidFiles/$current');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null; // 404 = no releases yet, etc.
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?)?.trim();
      final url = (json['html_url'] as String?)?.trim();
      if (tag == null || url == null) return null;
      if (!isRemoteNewer(tag, current)) return null;
      return UpdateInfo(_parse(tag)!.join('.'), url);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Whether release tag [remoteTag] names a version newer than [current].
  /// Pure and total (false on anything unparseable) so it can be unit-tested
  /// without a network.
  static bool isRemoteNewer(String remoteTag, String current) {
    final remote = _parse(remoteTag);
    return remote != null && _isNewer(remote, _parse(current));
  }

  /// "v1.2.3" / "1.2.3" -> [1,2,3]. A trailing pre-release ("-beta") is
  /// dropped, so 1.2.3-beta and 1.2.3 compare equal — deliberately
  /// conservative: better to miss a nag than to fire a wrong one.
  static List<int>? _parse(String s) {
    var t = s.trim();
    if (t.isNotEmpty && (t[0] == 'v' || t[0] == 'V')) t = t.substring(1);
    final dash = t.indexOf('-');
    if (dash != -1) t = t.substring(0, dash);
    final nums = <int>[];
    for (final p in t.split('.')) {
      final n = int.tryParse(p);
      if (n == null) return null;
      nums.add(n);
    }
    return nums.isEmpty ? null : nums;
  }

  static bool _isNewer(List<int> a, List<int>? b) {
    if (b == null) return false;
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// Open a URL in the default browser via the Windows shell.
  static Future<void> open(String url) async {
    // `start` is a cmd builtin; the empty first argument is the window title,
    // so a URL isn't mistaken for one.
    await Process.run('cmd', ['/c', 'start', '', url]);
  }
}
