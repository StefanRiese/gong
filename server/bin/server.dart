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

  final service = SphService(
    LiblanisGateway(
      schoolId: config.sph.schoolId,
      username: config.sph.username,
      password: config.sph.password,
    ),
  );
  final api = Api(
    service: service,
    passwordHash: config.appPasswordHash,
    sessions: SessionStore(ttl: config.sessionTtl),
    cookieSecure: config.cookieSecure,
    trustProxy: config.trustProxy,
    webDir: config.webDir,
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

  final done = Completer<void>();
  Future<void> shutdown(ProcessSignal signal) async {
    if (done.isCompleted) return;
    _log('Received $signal, shutting down', false);
    await server.close();
    await service.dispose();
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
