import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

import '../api/api.dart';
import '../api/cache.dart';
import '../api/embedded_web.dart';
import '../api/server_control.dart';
import '../auth/sessions.dart';
import '../config/app_config.dart';
import '../config/env.dart';
import '../config/server_settings.dart';
import '../desktop/build_info.g.dart';
import '../notify/notifier.dart';
import '../notify/poller.dart';
import '../sph/liblanis_gateway.dart';
import '../sph/sph_gateway.dart';
import '../sph/sph_service.dart';
import '../storage/app_database.dart';
import '../storage/settings_store.dart';
import '../sync/sync_service.dart';

/// Log sink: one line, [isError] for stderr-like messages.
typedef LogLine = void Function(String line, bool isError);

/// Creates the portal access for a set of credentials (tests: fake).
typedef GatewayFactory = SphGateway Function(SphCredentials credentials);

/// Startup failure with a sysexits-style exit code.
class AppServerException implements Exception {
  final String message;
  final int exitCode;

  const AppServerException(this.message, this.exitCode);

  @override
  String toString() => message;
}

/// The running HTTP server with database, portal session and sync.
///
/// Configuration comes from environment variables / config.env ([start]'s
/// `env`), overlaid by the settings made in the web UI (stored in the
/// database). Without Schulportal credentials or web UI password the server
/// runs in setup mode: the web UI shows the setup page, authorized by a
/// one-time token ([setupUrl]).
class AppServer implements ServerControl {
  final HttpServer _http;
  final AppDatabase _db;
  final ResponseCache _cache;
  final Api _api;
  final Map<String, String> _base;
  final WebSettingsStore _web;
  final GatewayFactory _gateway;
  final SchoolDirectory _schools;
  final LogLine _log;

  /// Config the server was started with (for settings needing a restart).
  final AppConfig startedConfig;

  AppConfig _config;
  SphService _service;
  SyncService _sync;
  SetupToken? _setupToken;
  Future<void> _applying = Future.value();
  Future<void>? _stopping;

  AppServer._(
    this._http,
    this._db,
    this._cache,
    this._api,
    this._base,
    this._web,
    this._gateway,
    this._schools,
    this._log,
    this._config,
    this._service,
    this._sync,
    this._setupToken,
  ) : startedConfig = _config;

  AppConfig get config => _config;

  int get port => _http.port;

  /// Address of the web UI for a browser on this machine.
  Uri get localUrl => localUrlFor(_config.host, port);

  /// Setup page with token while the server is not set up, else null.
  Uri? get setupUrl {
    final t = _setupToken;
    if (t == null) return null;
    return localUrl.replace(
      path: '/einrichtung',
      queryParameters: {'token': t.value},
    );
  }

  /// Browser address for a server listening on [host] (0.0.0.0/:: → loopback).
  static Uri localUrlFor(String host, int port) {
    final h = switch (host) {
      '0.0.0.0' || '' => '127.0.0.1',
      '::' => '[::1]',
      final h when h.contains(':') && !h.startsWith('[') => '[$h]',
      final h => h,
    };
    return Uri.parse('http://$h:$port/');
  }

  /// Opens the database and starts listening. Throws [AppServerException]
  /// for configuration/database problems and [SocketException] if the port
  /// is in use.
  static Future<AppServer> start(
    Map<String, String> env, {
    required LogLine log,
    GatewayFactory? gateway,
    SchoolDirectory? schools,
    int? passwordIterations,
  }) async {
    void info(String m) => log('${DateTime.now().toIso8601String()} $m', false);
    final makeGateway =
        gateway ??
        (c) => LiblanisGateway(
          schoolId: c.schoolId,
          username: c.username,
          password: c.password,
        );

    // DATA_DIR and WEB_DIR come from the environment / config file only.
    final AppConfig boot;
    try {
      boot = AppConfig.fromEnv(env, allowIncomplete: true);
    } on ConfigException catch (e) {
      throw AppServerException('$e', 78);
    }
    final webDir = boot.webDir;
    if (webDir != null && !Directory(webDir).existsSync()) {
      throw AppServerException('WEB_DIR does not exist: $webDir', 78);
    }
    final embedded = webDir == null && embeddedWebFiles.isNotEmpty
        ? EmbeddedWeb.fromBase64(embeddedWebFiles)
        : null;

    final AppDatabase db;
    try {
      Directory(boot.dataDir).createSync(recursive: true);
      db = AppDatabase.open(boot.databasePath);
    } on Object catch (e) {
      throw AppServerException(
        'Cannot open database ${boot.databasePath}: $e',
        73, // EX_CANTCREAT
      );
    }

    final web = WebSettingsStore(db);
    _applyResetMarker(boot.dataDir, web, info);
    final AppConfig config;
    try {
      config = AppConfig.fromEnv(
        _merge(env, web.load()),
        allowIncomplete: true,
      );
    } on ConfigException catch (e) {
      db.close();
      throw AppServerException('$e', 78);
    }

    // Cached portal data lives in the database, so it is there right after
    // a restart and while the portal is down.
    final cache = Api.createCache(store: db);
    final settings = SettingsStore(db);
    final service = SphService(makeGateway(config.sph));
    final sync = _createSync(service, cache, db, config, info);
    final api = Api(
      service: service,
      passwordHash: config.appPasswordHash,
      sessions: SessionStore(ttl: config.sessionTtl, database: db),
      cache: cache,
      cookieSecure: config.cookieSecure,
      trustProxy: config.trustProxy,
      webDir: webDir,
      embeddedWeb: embedded,
      poller: _createPoller(sync, db, settings, config, info),
      sync: sync,
      settings: settings,
      passwordIterations: passwordIterations,
    );

    final HttpServer http;
    try {
      http = await io.serve(
        const Pipeline()
            .addMiddleware(logRequests(logger: log))
            .addHandler(api.handler),
        config.host,
        config.port,
      );
    } on Object {
      await api.close();
      await sync.stop();
      await service.dispose();
      db.close();
      rethrow;
    }
    http.autoCompress = true;

    final server = AppServer._(
      http,
      db,
      cache,
      api,
      env,
      web,
      makeGateway,
      schools ?? SchoolDirectory(),
      log,
      config,
      service,
      sync,
      config.needsSetup ? SetupToken.create(dataDir: config.dataDir) : null,
    );
    api.control = server;

    final webSource = webDir != null
        ? ', web UI from $webDir'
        : embedded != null
        ? ', embedded web UI'
        : '';
    info('Listening on http://${config.host}:${http.port}$webSource');
    if (config.needsSetup) {
      info(
        'Not set up yet (Schulportal login or web UI password missing). '
        'Setup page: ${server.setupUrl}',
      );
    } else {
      server._logStatus();
      sync.start();
    }
    return server;
  }

  /// `install.sh --configure` lists the keys it wrote to config.env in
  /// `DATA_DIR/reset-web-settings`: web UI values for them are dropped, so
  /// the new config file values apply.
  static void _applyResetMarker(
    String dataDir,
    WebSettingsStore web,
    void Function(String) info,
  ) {
    final marker = File('$dataDir${Platform.pathSeparator}reset-web-settings');
    if (!marker.existsSync()) return;
    try {
      final keys = marker
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toSet();
      final values = web.load();
      final dropped = keys.where(values.containsKey).toList();
      if (dropped.isNotEmpty) {
        values.removeWhere((k, _) => keys.contains(k));
        web.save(values);
        info('Using config file values for ${dropped.join(', ')}');
      }
      marker.deleteSync();
    } on FileSystemException catch (e) {
      info('Cannot process ${marker.path}: ${e.message}');
    }
  }

  /// Environment / config file, overlaid by the web UI settings. A web UI
  /// password hash replaces a plain APP_PASSWORD from the config file.
  static Map<String, String> _merge(
    Map<String, String> base,
    Map<String, String> web,
  ) => {
    ...base,
    if (web.containsKey('APP_PASSWORD_HASH')) 'APP_PASSWORD': '',
    ...web,
  };

  static SyncService _createSync(
    SphService service,
    ResponseCache cache,
    AppDatabase db,
    AppConfig config,
    void Function(String) info,
  ) => SyncService(
    service: service,
    cache: cache,
    db: db,
    config: config.sync,
    log: info,
  );

  static Poller? _createPoller(
    SyncService sync,
    AppDatabase db,
    SettingsStore settings,
    AppConfig config,
    void Function(String) info,
  ) {
    final ntfy = config.ntfy;
    if (ntfy == null || config.poller.kinds.isEmpty) return null;
    return Poller(
      sync: sync,
      db: db,
      notifier: NtfyNotifier(
        server: ntfy.server,
        topic: ntfy.topic,
        token: ntfy.token,
        appUrl: config.appUrl,
      ),
      config: config.poller,
      substitutionFilter: () => settings.load().substitutionFilter,
      log: info,
    );
  }

  void _info(String m) => _log('${DateTime.now().toIso8601String()} $m', false);

  void _logStatus() {
    final c = _config;
    _info('Schulportal: school ${c.sph.schoolId}, user ${c.sph.username}');
    final sc = c.sync;
    if (sc.enabled) {
      _info(
        'Sync with Schulportal: substitutions/homework every '
        '${sc.interval.inMinutes} min, course pages every '
        '${sc.detailsInterval.inMinutes} min, '
        '${sc.activeFromHour}–${sc.activeToHour} h',
      );
    } else {
      _info('Background sync disabled (SYNC=false): data is loaded on demand');
    }
    final poller = _api.poller;
    if (poller != null) {
      _info(
        'Notifications via ${poller.notifier.description}: '
        '${c.poller.kinds.map((k) => k.name).join(', ')}'
        '${sc.enabled ? '' : ' (only on manual refresh, SYNC=false)'}',
      );
    } else {
      _info('Notifications disabled (NTFY_TOPIC not set)');
    }
  }

  // --- ServerControl -----------------------------------------------------------

  @override
  bool get setupRequired => _config.needsSetup;

  @override
  bool checkSetupToken(String? token) => _setupToken?.matches(token) ?? false;

  @override
  Map<String, Object?> describeSettings() {
    final c = _config;
    final web = _web.load();
    final effective = _merge(_base, web);
    String? raw(String key) {
      final v = effective[key]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    final values = <String, Object?>{
      'SPH_SCHOOL_ID': c.sph.schoolId,
      'SPH_USERNAME': c.sph.username,
      'SYNC': c.sync.enabled,
      'POLL_INTERVAL_MINUTES': c.sync.interval.inMinutes,
      'GRADES_INTERVAL_MINUTES': c.sync.detailsInterval.inMinutes,
      'ACTIVE_HOURS': '${c.sync.activeFromHour}-${c.sync.activeToHour}',
      'NTFY_URL':
          c.ntfy?.server.toString() ?? raw('NTFY_URL') ?? 'https://ntfy.sh',
      'NTFY_TOPIC': c.ntfy?.topic ?? '',
      'NOTIFY': c.poller.kinds.map((k) => k.name).join(','),
      'NOTIFY_GRADE_VALUES': c.poller.includeGradeValues,
      'APP_URL': c.appUrl?.toString() ?? '',
      'HOST': c.host,
      'PORT': c.port,
      'SESSION_TTL_DAYS': c.sessionTtl.inDays,
      'COOKIE_SECURE': c.cookieSecure,
      'TRUST_PROXY': c.trustProxy,
      'OPEN_BROWSER': c.openBrowser,
    };
    return {
      'setupRequired': c.needsSetup,
      'values': values,
      'secrets': {
        'SPH_PASSWORD': c.sph.password.isNotEmpty,
        'NTFY_TOKEN': (c.ntfy?.token ?? '').isNotEmpty,
        'APP_PASSWORD': c.appPasswordHash.isNotEmpty,
      },
      'sources': {
        for (final k in [...values.keys, 'SPH_PASSWORD', 'NTFY_TOKEN'])
          k: web.containsKey(k)
              ? 'web'
              : _base.containsKey(k)
              ? 'config'
              : 'default',
      },
      'restartRequired': _pendingRestart(c),
      'desktop': embeddedWebFiles.isNotEmpty,
    };
  }

  /// Settings changed since the start that only apply after a restart.
  List<String> _pendingRestart(AppConfig c) {
    final s = startedConfig;
    return [
      if (c.host != s.host) 'HOST',
      if (c.port != s.port) 'PORT',
      if (c.sessionTtl != s.sessionTtl) 'SESSION_TTL_DAYS',
      if (c.cookieSecure != s.cookieSecure) 'COOKIE_SECURE',
      if (c.trustProxy != s.trustProxy) 'TRUST_PROXY',
    ];
  }

  @override
  Future<void> testLogin({
    required int schoolId,
    required String username,
    String? password,
  }) async {
    final pw = password ?? _config.sph.password;
    final probe = SphService(_gateway(SphCredentials(schoolId, username, pw)));
    try {
      await probe.account();
    } finally {
      await probe.dispose();
    }
  }

  @override
  Future<ApplyResult> apply(Map<String, String> changes) {
    // One change at a time.
    final result = _applying.then((_) => _apply(changes));
    _applying = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<ApplyResult> _apply(Map<String, String> changes) async {
    final previous = _config;
    final web = {..._web.load(), ...changes};
    final next = AppConfig.fromEnv(_merge(_base, web));

    final p = previous.sph, n = next.sph;
    final accountChanged =
        p.schoolId != n.schoolId ||
        p.username.toLowerCase() != n.username.toLowerCase();
    final credentialsChanged = accountChanged || p.password != n.password;
    if (credentialsChanged) {
      await testLogin(
        schoolId: n.schoolId,
        username: n.username,
        password: n.password,
      );
    }

    _web.save(web);
    final wasSetup = previous.needsSetup;
    await _reconfigure(
      next,
      newService: credentialsChanged || wasSetup,
      resetData: accountChanged && !wasSetup,
    );
    if (wasSetup) {
      _setupToken?.discard();
      _setupToken = null;
      _info('Setup done');
    }
    _info('Settings changed: ${changes.keys.join(', ')}');
    return ApplyResult(
      restartRequired: _pendingRestart(next),
      accountChanged: accountChanged,
    );
  }

  Future<void> _reconfigure(
    AppConfig next, {
    required bool newService,
    required bool resetData,
  }) async {
    await _sync.stop();
    if (newService) {
      await _service.dispose();
      _service = SphService(_gateway(next.sph));
    }
    if (resetData) {
      // Another account: nothing of the old one may show up.
      _cache.clear();
      _db.resetPortalState();
    }
    _sync = _createSync(_service, _cache, _db, next, _info);
    _api
      ..service = _service
      ..sync = _sync
      ..poller = _createPoller(_sync, _db, _api.settings, next, _info)
      ..passwordHash = next.appPasswordHash;
    _config = next;
    if (!next.needsSetup) {
      _logStatus();
      _sync.start();
    }
  }

  @override
  Future<List<School>> searchSchools(String query) => _schools.search(query);

  /// Stops listening, the sync and the portal session; closes the database.
  Future<void> stop() => _stopping ??= () async {
    await _applying;
    await _api.close(); // open event streams would keep the server open
    await _http
        .close()
        .then<void>((_) {})
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => _http.close(force: true).then<void>((_) {}),
        );
    await _sync.stop();
    await _service.dispose();
    await _cache.close();
    _db.close();
  }();
}
