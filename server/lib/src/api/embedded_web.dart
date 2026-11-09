import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

/// Web UI files compiled into the executable (desktop builds), served like
/// the files from WEB_DIR: unknown paths get index.html (SPA routing).
class EmbeddedWeb {
  final Map<String, _File> _files;

  EmbeddedWeb._(this._files);

  /// [files] maps paths relative to the web root (`js/app.js`) to their
  /// content as base64.
  factory EmbeddedWeb.fromBase64(Map<String, String> files) => EmbeddedWeb._({
    for (final MapEntry(:key, :value) in files.entries)
      key: _File(base64.decode(value), _contentType(key)),
  });

  bool get isEmpty => _files.isEmpty;
  int get length => _files.length;

  /// Response for [request], or null if neither the file nor index.html exist.
  Response? serve(Request request) {
    final path = request.url.path;
    final file =
        _files[path.isEmpty ? 'index.html' : path] ?? _files['index.html'];
    if (file == null) return null;
    final headers = {'content-type': file.contentType, 'etag': file.etag};
    if (request.headers['if-none-match'] == file.etag) {
      return Response.notModified(headers: {'etag': file.etag});
    }
    return Response.ok(
      request.method == 'HEAD' ? null : file.bytes,
      headers: {...headers, 'content-length': '${file.bytes.length}'},
    );
  }

  static String _contentType(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'html' => 'text/html; charset=utf-8',
      'css' => 'text/css; charset=utf-8',
      'js' || 'mjs' => 'text/javascript; charset=utf-8',
      'json' => 'application/json',
      'webmanifest' => 'application/manifest+json',
      'svg' => 'image/svg+xml',
      'png' => 'image/png',
      'ico' => 'image/x-icon',
      'txt' => 'text/plain; charset=utf-8',
      _ => 'application/octet-stream',
    };
  }
}

class _File {
  final Uint8List bytes;
  final String contentType;
  final String etag;

  _File(this.bytes, this.contentType)
    : etag = '"${sha1.convert(bytes).toString().substring(0, 16)}"';
}
