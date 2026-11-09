// HTTP server for schulportal-client.
//
// Configuration via environment variables or server/.env (see .env.example).

import 'dart:async';
import 'dart:io';

import 'package:schulportal_server/schulportal_server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main(List<String> args) async {
  final envFile = Platform.environment['ENV_FILE'] ?? '.env';
  final AppConfig config;
  try {
    config = AppConfig.fromEnv(loadEnv(path: envFile));
  } on ConfigException catch (e) {
    stderr.writeln(e);
    exit(78); // EX_CONFIG
  }

  if (config.webDir != null && !Directory(config.webDir!).existsSync()) {
    stderr.writeln('WEB_DIR does not exist: ${config.webDir}');
    exit(78);
  }

  final AppDatabase db;
  try {
    Directory(config.dataDir).createSync(recursive: true);
    db = AppDatabase.open(config.databasePath);
  } on Object catch (e) {
    stderr.writeln('Cannot open database ${config.databasePath}: $e');
    exit(73); // EX_CANTCREAT
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
      log: (m) => _log(m, false),
    );
  }

  final api = Api(
    service: service,
    passwordHash: config.appPasswordHash,
    sessions: SessionStore(ttl: config.sessionTtl, database: db),
    cache: cache,
    cookieSecure: config.cookieSecure,
    trustProxy: config.trustProxy,
    webDir: config.webDir,
    poller: poller,
  );

  final handler = const Pipeline()
      .addMiddleware(logRequests(logger: _logRaw))
      .addHandler(api.handler);

  final server = await io.serve(handler, config.host, config.port);
  server.autoCompress = true;
  _log(
    'Listening on http://${config.host}:${server.port} '
    '(school ${config.sph.schoolId}, user ${config.sph.username}'
    '${config.webDir != null ? ', web UI from ${config.webDir}' : ''})',
    false,
  );
  if (poller != null) {
    final c = config.poller;
    _log(
      'Notifications via ${poller.notifier.description}: '
      '${c.kinds.map((k) => k.name).join(', ')} every ${c.interval.inMinutes} min '
      '(grades ${c.gradesInterval.inMinutes} min), '
      '${c.activeFromHour}–${c.activeToHour} h',
      false,
    );
    poller.start();
  } else {
    _log('Notifications disabled (NTFY_TOPIC not set)', false);
  }

  final done = Completer<void>();
  Future<void> shutdown(ProcessSignal signal) async {
    if (done.isCompleted) return;
    _log('Received $signal, shutting down', false);
    await server.close();
    await poller?.stop();
    await service.dispose();
    db.close();
    done.complete();
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
  await done.future;
  exit(0);
}

void _log(String message, bool isError) =>
    _logRaw('${DateTime.now().toIso8601String()} $message', isError);

/// shelf's request log lines already start with a timestamp.
void _logRaw(String line, bool isError) =>
    isError ? stderr.writeln(line) : stdout.writeln(line);
