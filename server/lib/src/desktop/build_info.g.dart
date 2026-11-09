// Build information and embedded files of packaged builds.
//
// This committed version is a placeholder for development and the Linux
// release. deploy/build-release.sh regenerates it with tool/embed_assets.dart
// for the Windows and macOS desktop builds and restores it afterwards.

/// Release version (`git describe`), null in development builds.
const String? buildVersion = null;

/// Web UI files (path relative to web/ → base64); empty = not embedded.
const Map<String, String> embeddedWebFiles = {};

/// Tray icon (PNG, base64) for the Windows notification area.
const String trayIconPng = '';
