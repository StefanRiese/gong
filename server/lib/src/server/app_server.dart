import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

import '../api/api.dart';
import '../api/embedded_web.dart';
import '../auth/sessions.dart';
import '../config/app_config.dart';
import '../desktop/build_info.g.dart';
import '../notify/notifier.dart';
import '../notify/poller.dart';
import '../sph/liblanis_gateway.dart';
import '../sph/sph_service.dart';
import '../storage/app_database.dart';
import '../storage/settings_store.dart';

/// Log sink: one line, [isError] for stderr-like messages.
typedef LogLine = void Function(String line, bool isError);

/// Startup failure with a sysexits-style exit code.
class AppServerException implements Exception {
  final String message;
  final int exitCode;

  const AppServerException(this.message, this.exitCode);

  @override
  String toString() => message;
}

/// The running HTTP server with database, portal session and poller.
class AppServer {
  final AppConfig config;
  final HttpServer _http;
  final AppDatabase _db;
  final SphService _service;
  final Poller? _poller;
  Future<void>? _stopping;

  AppServer._(this.config, this._http, this._db, this._service, this._poller);

  int get port => _http.port;

  /// Address of the web UI for a browser on this machine.
  Uri get localUrl => localUrlFor(config.host, port);

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
    AppConfig config, {
    required LogLine log,
  }) async {
    void info(String m) => log('${DateTime.now().toIso8601String()} $m', false);

    final webDir = config.webDir;
    if (webDir != null && !Directory(webDir).existsSync()) {
      throw AppServerException('WEB_DIR does not exist: $webDir', 78);
    }
    final embedded = webDir == null && embeddedWebFiles.isNotEmpty
        ? EmbeddedWeb.fromBase64(embeddedWebFiles)
        : null;

    final AppDatabase db;
    try {
      Directory(config.dataDir).createSync(recursive: true);
      db = AppDatabase.open(config.databasePath);
    } on Object catch (e) {
      throw AppServerException(
        'Cannot open database ${config.databasePath}: $e',
        73, // EX_CANTCREAT
      );
    }

    final service = SphService(
      LiblanisGateway(
        schoolId: config.sph.schoolId,
        username: config.sph.username,
        password: config.sph.password,
      ),
    );
    final cache = Api.createCache();

    Poller? poller;
    final ntfy = config.ntfy;
    if (ntfy != null && config.poller.kinds.isNotEmpty) {
      poller = Poller(
        service: service,
        cache: cache,
        db: db,
        notifier: NtfyNotifier(
          server: ntfy.server,
          topic: ntfy.topic,
          token: ntfy.token,
          appUrl: config.appUrl,
        ),
        config: config.poller,
        log: info,
      );
    }

    final api = Api(
      service: service,
      passwordHash: config.appPasswordHash,
      sessions: SessionStore(ttl: config.sessionTtl, database: db),
      cache: cache,
      cookieSecure: config.cookieSecure,
      trustProxy: config.trustProxy,
      webDir: webDir,
      embeddedWeb: embedded,
      poller: poller,
      settings: SettingsStore(db),
    );

    final handler = const Pipeline()
        .addMiddleware(logRequests(logger: log))
        .addHandler(api.handler);

    final HttpServer http;
    try {
      http = await io.serve(handler, config.host, config.port);
    } on Object {
      await service.dispose();
      db.close();
      rethrow;
    }
    http.autoCompress = true;

    final webSource = webDir != null
        ? ', web UI from $webDir'
        : embedded != null
        ? ', embedded web UI'
        : '';
    info(
      'Listening on http://${config.host}:${http.port} '
      '(school ${config.sph.schoolId}, user ${config.sph.username}$webSource)',
    );
    if (poller != null) {
      final c = config.poller;
      info(
        'Notifications via ${poller.notifier.description}: '
        '${c.kinds.map((k) => k.name).join(', ')} every ${c.interval.inMinutes} min '
        '(grades ${c.gradesInterval.inMinutes} min), '
        '${c.activeFromHour}–${c.activeToHour} h',
      );
      poller.start();
    } else {
      info('Notifications disabled (NTFY_TOPIC not set)');
    }
    return AppServer._(config, http, db, service, poller);
  }

  /// Stops listening, the poller and the portal session; closes the database.
  Future<void> stop() => _stopping ??= () async {
    await _http.close();
    await _poller?.stop();
    await _service.dispose();
    _db.close();
  }();
}
