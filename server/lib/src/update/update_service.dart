import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// How this installation can be updated.
enum UpdateMode {
  /// Linux service installed by install.sh: a root systemd unit runs
  /// install.sh when the server writes an update request.
  systemd,

  /// Windows desktop app: the exe replaces itself and restarts.
  windows,

  /// macOS desktop app: the server unpacks the new app, the menu bar app
  /// swaps the bundle.
  macos,

  /// Development build or unknown installation: only a notice.
  manual,
}

/// A release on GitHub.
class Release {
  final String tag;
  final String notes;
  final Uri url;
  final DateTime? publishedAt;

  /// Asset name → download URL.
  final Map<String, Uri> assets;

  const Release({
    required this.tag,
    required this.notes,
    required this.url,
    required this.publishedAt,
    required this.assets,
  });

  factory Release.fromGitHub(Map<String, Object?> j) => Release(
    tag: j['tag_name'] as String,
    notes: (j['body'] as String?) ?? '',
    url: Uri.parse(j['html_url'] as String),
    publishedAt: DateTime.tryParse('${j['published_at']}'),
    assets: {
      for (final a in (j['assets'] as List? ?? const []).cast<Map>())
        '${a['name']}': Uri.parse('${a['browser_download_url']}'),
    },
  );
}

/// Version from a tag or `git describe` ("v0.6.0", "v0.5.0-3-gabc123").
class Version implements Comparable<Version> {
  final int major, minor, patch;

  /// Commits after the tag (git describe); 0 for a release.
  final int ahead;

  const Version(this.major, this.minor, this.patch, [this.ahead = 0]);

  static final _pattern = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-(\d+)-g[0-9a-f]+)?',
  );

  static Version? tryParse(String? s) {
    final m = _pattern.firstMatch(s?.trim() ?? '');
    if (m == null) return null;
    return Version(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.tryParse(m[4] ?? '') ?? 0,
    );
  }

  @override
  int compareTo(Version o) => major != o.major
      ? major.compareTo(o.major)
      : minor != o.minor
      ? minor.compareTo(o.minor)
      : patch != o.patch
      ? patch.compareTo(o.patch)
      : ahead.compareTo(o.ahead);

  bool operator >(Version o) => compareTo(o) > 0;

  @override
  String toString() => 'v$major.$minor.$patch${ahead > 0 ? '+$ahead' : ''}';
}

/// State of an installation in progress.
enum UpdatePhase { idle, downloading, installing, restarting, failed }

typedef HttpGet = Future<List<int>> Function(Uri url);

/// Checks GitHub for new releases and installs them (see [UpdateMode]).
class UpdateService {
  static const repo = 'StefanRiese/ranzen';
  static final latestUrl = Uri.parse(
    'https://api.github.com/repos/$repo/releases/latest',
  );

  /// Running version (`git describe` of the release build), null in dev.
  final String? currentVersion;
  final UpdateMode mode;
  bool _checkEnabled;
  final String dataDir;

  /// Path of the running executable (Windows self-update).
  final String executable;

  /// Called when the new version is ready (Windows/macOS): restart.
  final Future<void> Function()? onReadyToRestart;
  final void Function(String message) log;
  final HttpGet _get;
  final DateTime Function() _now;

  Release? _latest;
  DateTime? _checkedAt;
  String? _checkError;
  UpdatePhase _phase = UpdatePhase.idle;
  String? _installError;
  Timer? _timer;
  Timer? _firstCheck;
  Future<Release?>? _checking;

  static const checkInterval = Duration(hours: 12);

  UpdateService({
    required this.currentVersion,
    required this.mode,
    required this.dataDir,
    bool checkEnabled = true,
    String? executable,
    this.onReadyToRestart,
    void Function(String message)? log,
    HttpGet? get,
    DateTime Function()? now,
  }) : _checkEnabled = checkEnabled,
       executable = executable ?? Platform.resolvedExecutable,
       log = log ?? ((_) {}),
       _get = get ?? _httpGet,
       _now = now ?? DateTime.now;

  /// Mode of this installation: release builds by platform; on Linux only
  /// with the systemd updater set up by install.sh (`UPDATER=systemd`).
  static UpdateMode detectMode({
    required String? version,
    required Map<String, String> env,
    required bool desktop,
  }) {
    if (version == null) return UpdateMode.manual;
    if (desktop && Platform.isWindows) return UpdateMode.windows;
    if (desktop && Platform.isMacOS) return UpdateMode.macos;
    if (Platform.isLinux && env['UPDATER'] == 'systemd') {
      return UpdateMode.systemd;
    }
    return UpdateMode.manual;
  }

  Version? get _current => Version.tryParse(currentVersion);

  bool get updateAvailable {
    final latest = Version.tryParse(_latest?.tag);
    final current = _current;
    return latest != null && current != null && latest > current;
  }

  bool get canInstall =>
      updateAvailable &&
      mode != UpdateMode.manual &&
      _phase != UpdatePhase.downloading &&
      _phase != UpdatePhase.installing &&
      _phase != UpdatePhase.restarting;

  bool get checkEnabled => _checkEnabled;

  /// Switches the periodic check on or off (settings changed).
  set checkEnabled(bool value) {
    if (value == _checkEnabled) return;
    _checkEnabled = value;
    if (value) {
      start();
    } else {
      stop();
    }
  }

  /// Checks now and every [checkInterval] (if enabled).
  void start() {
    if (!_checkEnabled || _timer != null) return;
    _timer = Timer.periodic(checkInterval, (_) => check().ignore());
    _firstCheck = Timer(const Duration(minutes: 1), () => check().ignore());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _firstCheck?.cancel();
    _firstCheck = null;
  }

  /// Asks GitHub for the latest release.
  Future<Release?> check() => _checking ??= () async {
    try {
      final body = await _get(latestUrl);
      _latest = Release.fromGitHub(
        (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>(),
      );
      _checkError = null;
      if (updateAvailable) log('Update available: ${_latest!.tag}');
      return _latest;
    } on Object catch (e) {
      _checkError = 'Update-Server nicht erreichbar';
      log('Update check failed: $e');
      return null;
    } finally {
      _checkedAt = _now();
      _checking = null;
    }
  }();

  /// install.sh (root) reports a failed update from the web UI here.
  File get _systemdResult => File('$dataDir/update-result');

  Map<String, Object?> status() {
    if (mode == UpdateMode.systemd && _phase != UpdatePhase.failed) {
      try {
        final r = _systemdResult;
        if (r.existsSync()) {
          final text = r.readAsStringSync().trim();
          if (text.startsWith('failed:')) {
            _phase = UpdatePhase.failed;
            _installError = text.substring(7).trim();
          }
        }
      } on FileSystemException {
        // Not readable: no result to show.
      }
    }
    return _statusJson();
  }

  Map<String, Object?> _statusJson() => {
    'current': currentVersion,
    'latest': _latest?.tag,
    'available': updateAvailable,
    'notes': _latest?.notes,
    'url': _latest?.url.toString(),
    'publishedAt': _latest?.publishedAt?.toUtc().toIso8601String(),
    'checkedAt': _checkedAt?.toUtc().toIso8601String(),
    'checkError': _checkError,
    'checkEnabled': checkEnabled,
    'mode': mode.name,
    'canInstall': canInstall,
    'phase': _phase.name,
    'error': _installError,
  };

  /// Starts installing the latest release; returns right away. Progress:
  /// [status] (`phase`). Throws [StateError] if no update can be installed.
  void install() {
    if (!canInstall) throw StateError('No update to install');
    final release = _latest!;
    _phase = UpdatePhase.downloading;
    _installError = null;
    () async {
      try {
        switch (mode) {
          case UpdateMode.systemd:
            await _requestSystemdUpdate(release);
          case UpdateMode.windows:
            await _installWindows(release);
          case UpdateMode.macos:
            await _installMacos(release);
          case UpdateMode.manual:
            throw StateError('manual');
        }
      } on Object catch (e) {
        _phase = UpdatePhase.failed;
        _installError = e is UpdateException
            ? e.message
            : 'Update fehlgeschlagen';
        log('Update to ${release.tag} failed: $e');
      }
    }();
  }

  /// Linux: the root unit ranzen-update.path watches this file
  /// and runs install.sh for the version in it, which restarts the service.
  Future<void> _requestSystemdUpdate(Release release) async {
    _phase = UpdatePhase.installing;
    try {
      if (_systemdResult.existsSync()) _systemdResult.deleteSync();
    } on FileSystemException {
      // Left over from root; install.sh overwrites it if needed.
    }
    final file = File('$dataDir/update-request');
    await file.writeAsString('${release.tag}\n', flush: true);
    log('Update to ${release.tag} requested');
    _phase = UpdatePhase.restarting;
  }

  /// Windows: a running exe can be renamed but not overwritten.
  Future<void> _installWindows(Release release) async {
    final bytes = await _download(release, 'ranzen-windows-x64.exe');
    _phase = UpdatePhase.installing;
    final exe = File(executable);
    final next = File('${exe.path}.new');
    final old = File('${exe.path}.old');
    await next.writeAsBytes(bytes, flush: true);
    if (old.existsSync()) old.deleteSync();
    exe.renameSync(old.path);
    try {
      next.renameSync(exe.path);
    } on Object {
      File(old.path).renameSync(exe.path); // undo
      rethrow;
    }
    log('Installed ${release.tag}, restarting');
    _phase = UpdatePhase.restarting;
    await onReadyToRestart?.call();
  }

  /// macOS: unpacks the app next to the data; the menu bar app swaps the
  /// bundle when the server exits with [exitUpdateReady].
  Future<void> _installMacos(Release release) async {
    const name = 'ranzen-macos-universal.zip';
    final bytes = await _download(release, name);
    _phase = UpdatePhase.installing;
    final dir = Directory('$dataDir/update');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final zip = File('${dir.path}/$name');
    await zip.writeAsBytes(bytes, flush: true);
    final r = await Process.run('ditto', ['-x', '-k', zip.path, dir.path]);
    zip.deleteSync();
    if (r.exitCode != 0 || !Directory('${dir.path}/Ranzen.app').existsSync()) {
      throw const UpdateException('Update konnte nicht entpackt werden');
    }
    log('Unpacked ${release.tag}, restarting');
    _phase = UpdatePhase.restarting;
    await onReadyToRestart?.call();
  }

  /// Downloads [name] of [release] and checks it against `<name>.sha256`.
  Future<List<int>> _download(Release release, String name) async {
    final url = release.assets[name];
    final sumUrl = release.assets['$name.sha256'];
    if (url == null || sumUrl == null) {
      throw UpdateException('$name fehlt im Release ${release.tag}');
    }
    for (final u in [url, sumUrl]) {
      if (u.scheme != 'https' || u.host != 'github.com') {
        throw const UpdateException('Unerwartete Download-Adresse');
      }
    }
    final expected = utf8
        .decode(await _get(sumUrl))
        .trim()
        .split(RegExp(r'\s+'))
        .first
        .toLowerCase();
    final bytes = await _get(url);
    if (sha256.convert(bytes).toString() != expected) {
      throw const UpdateException(
        'Prüfsumme stimmt nicht – Download beschädigt?',
      );
    }
    return bytes;
  }

  /// Removes leftovers of an earlier update (Windows: the old exe).
  void cleanUp() {
    if (mode != UpdateMode.windows) return;
    final old = File('$executable.old');
    try {
      if (old.existsSync()) old.deleteSync();
    } on FileSystemException {
      // Still in use by the old process; next start.
    }
  }

  static Future<List<int>> _httpGet(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'ranzen';
    try {
      final req = await client.getUrl(url);
      req.headers.set('accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(minutes: 5));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: url);
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in res) {
        out.add(chunk);
      }
      return out.takeBytes();
    } finally {
      client.close();
    }
  }
}

/// Exit code of the macOS server: new app unpacked, swap the bundle.
const exitUpdateReady = 80;

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);

  @override
  String toString() => message;
}
