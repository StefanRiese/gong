import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

import '../api/api.dart';
import '../api/cache.dart';
import '../api/embedded_web.dart';
import '../api/server_control.dart';
import '../auth/sessions.dart';
import '../caseda/caseda.dart';
import '../untis/untis.dart';
import '../config/app_config.dart';
import '../config/env.dart';
import '../config/server_settings.dart';
import '../desktop/build_info.g.dart';
import '../notify/notifier.dart';
import '../net/mdns.dart';
import '../net/ports.dart';
import '../notify/poller.dart';
import '../sph/liblanis_gateway.dart';
import '../sph/sph_gateway.dart';
import '../sph/sph_service.dart';
import '../storage/app_database.dart';
import '../storage/settings_store.dart';
import '../sync/cache_keys.dart';
import '../sync/sync_service.dart';
import '../update/update_service.dart';

/// Log sink: one line, [isError] for stderr-like messages.
typedef LogLine = void Function(String line, bool isError);

/// Creates the portal access for a set of credentials (tests: fake).
typedef GatewayFactory = SphGateway Function(SphCredentials credentials);

/// Creates the school meals access (tests: fake).
typedef MealsGatewayFactory = MealsGateway Function(CasedaConfig config);

/// Creates the WebUntis access (tests: fake).
typedef UntisGatewayFactory = UntisGateway Function(UntisConfig config);

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
  MdnsResponder? _mdns;
  final AppDatabase _db;
  final ResponseCache _cache;
  final Api _api;
  final Map<String, String> _base;
  final WebSettingsStore _web;
  final GatewayFactory _gateway;
  final MealsGatewayFactory _mealsGateway;
  final UntisGatewayFactory _untisGateway;
  final SchoolDirectory _schools;
  final LogLine _log;

  /// Config the server was started with (for settings needing a restart).
  final AppConfig startedConfig;

  AppConfig _config;
  SphService _service;
  SyncService _sync;
  final UpdateService _update;
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
    this._mealsGateway,
    this._untisGateway,
    this._schools,
    this._log,
    this._config,
    this._service,
    this._sync,
    this._update,
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
    MealsGatewayFactory? mealsGateway,
    UntisGatewayFactory? untisGateway,
    SchoolDirectory? schools,
    int? passwordIterations,
    Future<void> Function()? onUpdateReady,
    HttpGet? updateGet,
  }) async {
    void info(String m) => log('${DateTime.now().toIso8601String()} $m', false);
    final makeGateway =
        gateway ??
        (c) => LiblanisGateway(
          schoolId: c.schoolId,
          username: c.username,
          password: c.password,
        );

    final makeMeals =
        mealsGateway ??
        (c) => CasedaGateway(
          baseUrl: c.url,
          username: c.username,
          password: c.password,
        );

    final makeUntis =
        untisGateway ??
        (c) => UntisWebGateway(
          server: c.server,
          school: c.school,
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
    final sync = _createSync(
      service,
      cache,
      db,
      config,
      info,
      makeMeals,
      makeUntis,
    );
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

    final update = UpdateService(
      currentVersion: buildVersion,
      mode: UpdateService.detectMode(
        version: buildVersion,
        env: env,
        desktop: embeddedWebFiles.isNotEmpty,
      ),
      dataDir: config.dataDir,
      checkEnabled: config.updateCheck,
      onReadyToRestart: onUpdateReady,
      log: info,
      get: updateGet,
    )..cleanUp();
    api
      ..update = update
      ..meals = config.caseda == null ? null : makeMeals(config.caseda!)
      ..mealsBalanceWarningCents = config.mealsBalanceWarningCents
      ..untisEnabled = config.untis != null;

    final server = AppServer._(
      http,
      db,
      cache,
      api,
      env,
      web,
      makeGateway,
      makeMeals,
      makeUntis,
      schools ?? SchoolDirectory(),
      log,
      config,
      service,
      sync,
      update,
      config.needsSetup ? SetupToken.create(dataDir: config.dataDir) : null,
    );
    api.control = server;

    final loopback =
        config.host == 'localhost' ||
        (InternetAddress.tryParse(config.host)?.isLoopback ?? false);
    if (config.mdnsName != null && !loopback) {
      server._mdns = await MdnsResponder.start(config.mdnsName!, log: info);
      if (server._mdns != null) {
        info('mDNS: reachable as http://${config.mdnsName}.local:${http.port}');
      }
    }

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
    update.start();
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
    MealsGatewayFactory makeMeals,
    UntisGatewayFactory makeUntis,
  ) => SyncService(
    service: service,
    cache: cache,
    db: db,
    config: config.sync,
    meals: config.caseda == null ? null : makeMeals(config.caseda!),
    untis: config.untis == null ? null : makeUntis(config.untis!),
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
      'UPDATE_CHECK': c.updateCheck,
      'CASEDA_URL':
          c.caseda?.url.toString() ??
          raw('CASEDA_URL') ??
          'https://www.caseda-schulmenue.de',
      // Switched off keeps the stored login (shown below).
      'CASEDA_ENABLED': c.caseda != null,
      'CASEDA_USERNAME': c.caseda?.username ?? raw('CASEDA_USERNAME') ?? '',
      'CASEDA_BALANCE_WARNING': (c.mealsBalanceWarningCents / 100)
          .toStringAsFixed(2)
          .replaceAll('.', ','),
      'UNTIS_ENABLED': c.untis != null,
      'UNTIS_SERVER': c.untis?.server ?? raw('UNTIS_SERVER') ?? '',
      'UNTIS_SCHOOL': c.untis?.school ?? raw('UNTIS_SCHOOL') ?? '',
      'UNTIS_USERNAME': c.untis?.username ?? raw('UNTIS_USERNAME') ?? '',
    };
    return {
      'setupRequired': c.needsSetup,
      'values': values,
      'secrets': {
        'SPH_PASSWORD': c.sph.password.isNotEmpty,
        'NTFY_TOKEN': (c.ntfy?.token ?? '').isNotEmpty,
        'APP_PASSWORD': c.appPasswordHash.isNotEmpty,
        'CASEDA_PASSWORD': raw('CASEDA_PASSWORD') != null,
        'UNTIS_PASSWORD': raw('UNTIS_PASSWORD') != null,
      },
      'sources': {
        for (final k in [
          ...values.keys,
          'SPH_PASSWORD',
          'NTFY_TOKEN',
          'CASEDA_PASSWORD',
          'UNTIS_PASSWORD',
        ])
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
  Future<void> testCasedaLogin({
    required String username,
    String? password,
    String? url,
  }) async {
    final base = url == null
        ? _config.caseda?.url ?? Uri.parse('https://www.caseda-schulmenue.de')
        : Uri.tryParse(url);
    if (base == null || !base.isScheme('https') || base.host.isEmpty) {
      throw ArgumentError('url must be an https URL');
    }
    final pw = password ?? _config.caseda?.password ?? '';
    await _mealsGateway(
      CasedaConfig(url: base, username: username, password: pw),
    ).load(DateTime.now());
  }

  @override
  Future<String> testUntisLogin({
    required String server,
    required String username,
    String? password,
    String? school,
  }) async {
    final host = UntisConfig.parseServer(server);
    if (host == null) {
      throw ArgumentError('server must be a host name like xyz.webuntis.com');
    }
    final snap = await _untisGateway(
      UntisConfig(
        server: host,
        school: school ?? host.split('.').first,
        username: username,
        password: password ?? _config.untis?.password ?? '',
      ),
    ).load(DateTime.now());
    return snap.className;
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
    if (next.port != previous.port) {
      final problem = await portProblem(next.port);
      if (problem != null) throw ConfigException([problem]);
    }

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

    final pc = previous.caseda, nc = next.caseda;
    final casedaChanged =
        pc?.url != nc?.url ||
        pc?.username != nc?.username ||
        pc?.password != nc?.password;
    if (nc != null && casedaChanged) {
      await _mealsGateway(nc).load(DateTime.now());
    }
    if (pc?.url != nc?.url ||
        pc?.username.toLowerCase() != nc?.username.toLowerCase()) {
      _cache.remove(CacheKeys.meals); // another Caseda account (or none)
    }

    final pu = previous.untis, nu = next.untis;
    if (nu != null &&
        (pu?.server != nu.server ||
            pu?.school != nu.school ||
            pu?.username != nu.username ||
            pu?.password != nu.password)) {
      await _untisGateway(nu).load(DateTime.now());
    }
    if (pu?.server != nu?.server ||
        pu?.school != nu?.school ||
        pu?.username.toLowerCase() != nu?.username.toLowerCase()) {
      _cache.remove(CacheKeys.untis); // another account (or switched off)
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
    _sync = _createSync(
      _service,
      _cache,
      _db,
      next,
      _info,
      _mealsGateway,
      _untisGateway,
    );
    _api
      ..service = _service
      ..sync = _sync
      ..poller = _createPoller(_sync, _db, _api.settings, next, _info)
      ..meals = next.caseda == null ? null : _mealsGateway(next.caseda!)
      ..mealsBalanceWarningCents = next.mealsBalanceWarningCents
      ..untisEnabled = next.untis != null
      ..passwordHash = next.appPasswordHash;
    _update.checkEnabled = next.updateCheck;
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
    _update.stop();
    await _mdns?.stop();
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
