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
import '../config/accounts.dart';
import '../config/app_config.dart';
import '../config/migrate_accounts.dart';
import '../config/env.dart';
import '../config/server_settings.dart';
import '../desktop/build_info.g.dart';
import '../notify/notifier.dart';
import '../net/ports.dart';
import '../notify/poller.dart';
import '../sph/liblanis_gateway.dart';
import '../sph/sph_gateway.dart';
import '../sph/sph_service.dart';
import '../storage/app_database.dart';
import '../storage/portal_state.dart';
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

/// One account (child): its own portal session, cache, sync and
/// notifications, served by its own [Api].
class _Account {
  AccountConfig config;
  SphService service;
  final ResponseCache cache;
  final Api api;
  late SyncService sync;

  _Account(this.config, this.service, this.cache, this.api);

  String get prefix => scopePrefix(config.id);
}

/// The running HTTP server with database, portal sessions and sync.
///
/// Configuration comes from environment variables / config.env ([start]'s
/// `env`), overlaid by the settings made in the web UI (stored in the
/// database). The accounts (children) are kept in the database (see
/// [AccountStore]). Without an account or web UI password the server runs in
/// setup mode: the web UI shows the setup page, authorized by a one-time token
/// ([setupUrl]).
class AppServer implements ServerControl {
  final HttpServer _http;
  final AppDatabase _db;
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
  final UpdateService _update;
  final AccountStore _accountStore;

  /// The accounts in display order; the first one answers the API paths
  /// without account.
  final _accounts = <String, _Account>{};
  SetupToken? _setupToken;
  Future<void> _applying = Future.value();
  Future<void>? _stopping;

  AppServer._(
    this._http,
    this._db,
    this._api,
    this._base,
    this._web,
    this._gateway,
    this._mealsGateway,
    this._untisGateway,
    this._schools,
    this._log,
    this._config,
    this._update,
    this._setupToken,
  ) : startedConfig = _config,
      _accountStore = AccountStore(_db);

  AppConfig get config => _config;

  int get port => _http.port;

  /// Number of accounts (children).
  int get accountCount => _accounts.length;

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
    try {
      // Update from versions with one account in the settings.
      migrateLegacyAccount(
        db: db,
        env: env,
        web: web,
        store: AccountStore(db),
        log: info,
      );
    } on Object catch (e) {
      db.close();
      throw AppServerException('Cannot update the account settings: $e', 78);
    }
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

    // Routes the requests to the accounts; serves no account itself.
    final api = Api(
      passwordHash: config.appPasswordHash,
      sessions: SessionStore(ttl: config.sessionTtl, database: db),
      cookieSecure: config.cookieSecure,
      trustProxy: config.trustProxy,
      webDir: webDir,
      embeddedWeb: embedded,
      passwordIterations: passwordIterations,
    );

    final HttpServer http;
    try {
      final handler = const Pipeline()
          .addMiddleware(logRequests(logger: log))
          .addHandler(api.handler);
      http = await _listen(handler, config.host, config.port);
    } on Object {
      await api.close();
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
    api.update = update;

    final server = AppServer._(
      http,
      db,
      api,
      env,
      web,
      makeGateway,
      makeMeals,
      makeUntis,
      schools ?? SchoolDirectory(),
      log,
      config,
      update,
      null,
    );
    api
      ..control = server
      ..defaultAccount = (() => server._accounts.values.firstOrNull?.api);
    for (final c in server._accountStore.load()) {
      server._accounts[c.id] = server._createAccount(c);
    }
    if (server._needsSetup) {
      server._setupToken = SetupToken.create(dataDir: config.dataDir);
    }

    final webSource = webDir != null
        ? ', web UI from $webDir'
        : embedded != null
        ? ', embedded web UI'
        : '';
    info('Listening on http://${config.host}:${http.port}$webSource');
    if (server._needsSetup) {
      info(
        'Not set up yet (Schulportal account or web UI password missing). '
        'Setup page: ${server.setupUrl}',
      );
    } else {
      server._logStatus();
      server._startSyncs();
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
    PortalState state,
    AppConfig config,
    CasedaConfig? caseda,
    UntisConfig? untis,
    void Function(String) info,
    MealsGatewayFactory makeMeals,
    UntisGatewayFactory makeUntis,
  ) => SyncService(
    service: service,
    cache: cache,
    db: state,
    config: config.sync,
    meals: caseda == null ? null : makeMeals(caseda),
    untis: untis == null ? null : makeUntis(untis),
    log: info,
  );

  static Poller? _createPoller(
    SyncService sync,
    PortalState state,
    SettingsStore settings,
    AppConfig config,
    void Function(String) info,
    ({String name, String id})? Function() label,
  ) {
    final ntfy = config.ntfy;
    if (ntfy == null || config.poller.kinds.isEmpty) return null;
    return Poller(
      sync: sync,
      db: state,
      notifier: LabeledNotifier(
        NtfyNotifier(
          server: ntfy.server,
          topic: ntfy.topic,
          token: ntfy.token,
          appUrl: config.appUrl,
        ),
        label,
      ),
      config: config.poller,
      substitutionFilter: () => settings.load().substitutionFilter,
      log: info,
    );
  }

  /// Name and id of an account for notifications; null while there is only
  /// one account (nothing to tell apart).
  ({String name, String id})? _label(String id) {
    if (_accounts.length < 2) return null;
    return (name: _accounts[id]?.config.name ?? '', id: id);
  }

  /// No account or no web UI password yet.
  bool get _needsSetup => _config.needsSetup || _accounts.isEmpty;

  void _info(String m) => _log('${DateTime.now().toIso8601String()} $m', false);

  void _logStatus() {
    final c = _config;
    for (final a in _accounts.values) {
      _info(
        'Schulportal account: school ${a.config.sph.schoolId}, '
        'user ${a.config.sph.username}',
      );
    }
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
    if (c.ntfy != null && c.poller.kinds.isNotEmpty) {
      _info(
        'Notifications via ${c.ntfy!.server.host}: '
        '${c.poller.kinds.map((k) => k.name).join(', ')}'
        '${sc.enabled ? '' : ' (only on manual refresh, SYNC=false)'}',
      );
    } else {
      _info('Notifications disabled (NTFY_TOPIC not set)');
    }
  }

  // --- ServerControl -----------------------------------------------------------

  @override
  bool get setupRequired => _needsSetup;

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
      'CASEDA_BALANCE_WARNING': (c.mealsBalanceWarningCents / 100)
          .toStringAsFixed(2)
          .replaceAll('.', ','),
    };
    return {
      'setupRequired': _needsSetup,
      'values': values,
      'secrets': {
        'NTFY_TOKEN': (c.ntfy?.token ?? '').isNotEmpty,
        'APP_PASSWORD': c.appPasswordHash.isNotEmpty,
      },
      'sources': {
        for (final k in [...values.keys, 'NTFY_TOKEN'])
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
  Future<ApplyResult> apply(Map<String, String> changes) =>
      _exclusive(() => _apply(changes));

  /// Runs [action] after the changes before it (one change at a time).
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _applying.then((_) => action());
    _applying = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<ApplyResult> _apply(Map<String, String> changes) async {
    final previous = _config;
    final wasSetup = _needsSetup;
    final web = {..._web.load(), ...changes};
    final next = AppConfig.fromEnv(_merge(_base, web));
    if (next.port != previous.port) {
      final problem = await portProblem(next.port);
      if (problem != null) throw ConfigException([problem]);
    }

    _web.save(web);
    await _reconfigure(next);
    _checkSetupDone(wasSetup);
    _info('Settings changed: ${changes.keys.join(', ')}');
    return ApplyResult(restartRequired: _pendingRestart(next));
  }

  /// Applies a new configuration: every account gets a new sync and
  /// notifications (schedule, ntfy, …).
  Future<void> _reconfigure(AppConfig next) async {
    _api.passwordHash = next.appPasswordHash;
    _update.checkEnabled = next.updateCheck;
    _config = next;
    for (final account in _accounts.values) {
      await account.sync.stop();
      _wire(account);
    }
    if (!_needsSetup) {
      _logStatus();
      _startSyncs();
    }
  }

  /// Leaves setup mode once an account and the web UI password exist.
  void _checkSetupDone(bool wasSetup) {
    if (!wasSetup || _needsSetup) return;
    _setupToken?.discard();
    _setupToken = null;
    _info('Setup done');
    _logStatus();
    _startSyncs();
  }

  /// Starts the sync of all accounts, one after the other so the portal does
  /// not get all requests at once.
  void _startSyncs() {
    var i = 0;
    for (final account in _accounts.values) {
      account.sync.start(firstDelay: Duration(seconds: 5 + 20 * i++));
    }
  }

  // --- accounts (children) -----------------------------------------------------

  _Account _createAccount(AccountConfig c) {
    final service = SphService(_gateway(c.sph));
    final cache = Api.createCache(
      store: ScopedCacheStore(_db, scopePrefix(c.id)),
    );
    final api =
        Api(
            service: service,
            passwordHash: _config.appPasswordHash,
            sessions: _api.sessions,
            limiter: _api.limiter,
            cache: cache,
            settings: SettingsStore(_db, scopePrefix(c.id)),
          )
          ..control = this
          ..update = _update;
    _api.children[c.id] = api;
    return _wire(_Account(c, service, cache, api));
  }

  /// (Re)creates sync and notifications of [account] from the current
  /// configuration; the old sync must be stopped before.
  _Account _wire(_Account account) {
    final c = account.config;
    final state = ScopedState(_db, account.prefix);
    account.sync = _createSync(
      account.service,
      account.cache,
      state,
      _config,
      c.caseda,
      c.untis,
      _info,
      _mealsGateway,
      _untisGateway,
    );
    account.api
      ..service = account.service
      ..sync = account.sync
      ..poller = _createPoller(
        account.sync,
        state,
        account.api.settings,
        _config,
        _info,
        () => _label(c.id),
      )
      ..meals = c.caseda == null ? null : _mealsGateway(c.caseda!)
      ..mealsBalanceWarningCents = _config.mealsBalanceWarningCents
      ..untisEnabled = c.untis != null;
    return account;
  }

  @override
  List<Map<String, Object?>> listAccounts() => [
    for (final a in _accounts.values) a.config.describe(),
  ];

  static bool _sameLogin(SphCredentials a, SphCredentials b) =>
      a.schoolId == b.schoolId &&
      a.username.toLowerCase() == b.username.toLowerCase();

  /// Tries a Schulportal login (new or changed credentials).
  Future<void> _testLogin(SphCredentials credentials) async {
    final probe = SphService(_gateway(credentials));
    try {
      await probe.account();
    } finally {
      await probe.dispose();
    }
  }

  /// Tries the logins of [next] that are new or changed against [previous].
  Future<void> _verifyLogins(
    AccountConfig next,
    AccountConfig? previous,
  ) async {
    final p = previous?.sph, n = next.sph;
    if (p == null ||
        p.schoolId != n.schoolId ||
        p.username != n.username ||
        p.password != n.password) {
      await _testLogin(n);
    }
    final pc = previous?.caseda, nc = next.caseda;
    if (nc != null &&
        (pc?.url != nc.url ||
            pc?.username != nc.username ||
            pc?.password != nc.password)) {
      await _mealsGateway(nc).load(DateTime.now());
    }
    final pu = previous?.untis, nu = next.untis;
    if (nu != null &&
        (pu?.server != nu.server ||
            pu?.school != nu.school ||
            pu?.username != nu.username ||
            pu?.password != nu.password)) {
      await _untisGateway(nu).load(DateTime.now());
    }
  }

  void _checkNotDuplicate(AccountConfig next) {
    for (final a in _accounts.values) {
      if (a.config.id != next.id && _sameLogin(a.config.sph, next.sph)) {
        throw const ConfigException([
          'This Schulportal account is already set up',
        ]);
      }
    }
  }

  @override
  Future<Map<String, Object?>> addAccount(Map<String, Object?> data) =>
      _exclusive(() async {
        final wasSetup = _needsSetup;
        if (_accounts.length >= AccountConfig.maxAccounts) {
          throw const ConfigException([
            'At most ${AccountConfig.maxAccounts} accounts',
          ]);
        }
        final cfg = AccountConfig.parse(
          data,
          id: AccountConfig.newId(_accounts.keys.toSet()),
        );
        _checkNotDuplicate(cfg);
        await _verifyLogins(cfg, null);
        _accountStore.save([for (final a in _accounts.values) a.config, cfg]);
        final account = _accounts[cfg.id] = _createAccount(cfg);
        _info('Account added: ${cfg.name}');
        if (!_needsSetup) account.sync.start();
        _checkSetupDone(wasSetup);
        return cfg.describe();
      });

  @override
  Future<Map<String, Object?>> updateAccount(
    String id,
    Map<String, Object?> data,
  ) => _exclusive(() async {
    final account = _accounts[id];
    if (account == null) throw const AccountNotFound();
    final previous = account.config;
    final next = AccountConfig.parse(data, id: id, base: previous);
    _checkNotDuplicate(next);
    await _verifyLogins(next, previous);

    final p = previous.sph, n = next.sph;
    final newService =
        p.schoolId != n.schoolId ||
        p.username != n.username ||
        p.password != n.password;
    await account.sync.stop();
    if (!_sameLogin(p, n)) {
      // Another person: nothing of the old account may show up.
      account.cache.clear();
      _db.resetPortalState(account.prefix);
    }
    if (previous.caseda?.url != next.caseda?.url ||
        previous.caseda?.username.toLowerCase() !=
            next.caseda?.username.toLowerCase()) {
      account.cache.remove(CacheKeys.meals);
    }
    if (previous.untis?.server != next.untis?.server ||
        previous.untis?.school != next.untis?.school ||
        previous.untis?.username.toLowerCase() !=
            next.untis?.username.toLowerCase()) {
      account.cache.remove(CacheKeys.untis);
    }
    if (newService) {
      await account.service.dispose();
      account.service = SphService(_gateway(n));
    }
    account.config = next;
    _accountStore.save([for (final a in _accounts.values) a.config]);
    _wire(account);
    if (!_needsSetup) account.sync.start();
    _info('Account changed: ${next.name}');
    return next.describe();
  });

  @override
  Future<void> removeAccount(String id) => _exclusive(() async {
    final account = _accounts[id];
    if (account == null) throw const AccountNotFound();
    if (_accounts.length <= 1) {
      throw ArgumentError('The last account cannot be removed');
    }
    await account.sync.stop();
    await account.api.close();
    await account.service.dispose();
    await account.cache.close();
    _db.resetPortalState(account.prefix);
    _accounts.remove(id);
    _api.children.remove(id);
    _accountStore.save([for (final a in _accounts.values) a.config]);
    _info('Account removed: ${account.config.name}');
  });

  @override
  Future<List<School>> searchSchools(String query) => _schools.search(query);

  /// Listens on [host]:[port]. `0.0.0.0` (all IPv4 addresses) also listens on
  /// IPv6 where available: clients that resolve the name via mDNS
  /// (`lumo.local`) often get the IPv6 address only.
  static Future<HttpServer> _listen(
    Handler handler,
    String host,
    int port,
  ) async {
    if (host == '0.0.0.0') {
      try {
        return await io.serve(handler, InternetAddress.anyIPv6, port);
      } on SocketException {
        // no IPv6 on this machine
      }
    }
    return io.serve(handler, host, port);
  }

  /// Stops listening, the sync and the portal sessions; closes the database.
  Future<void> stop() => _stopping ??= () async {
    await _applying;
    _update.stop();
    await _api.close(); // open event streams would keep the server open
    for (final account in _accounts.values) {
      await account.api.close();
    }
    await _http
        .close()
        .then<void>((_) {})
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => _http.close(force: true).then<void>((_) {}),
        );
    for (final account in _accounts.values) {
      await account.sync.stop();
      await account.service.dispose();
      await account.cache.close();
    }
    _db.close();
  }();
}
