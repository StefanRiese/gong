import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'win32.dart';

/// Menu commands sent from the tray to the main isolate.
enum TrayCommand { quit, restart }

/// Notification area icon with a popup menu (right click):
/// open web UI, edit settings, show log, restart, quit.
///
/// The Win32 message loop blocks, so it runs in its own isolate; the window
/// procedure is called synchronously on that isolate's thread.
class WindowsTray {
  final int _hwnd;
  final ReceivePort _port;
  final Future<void> _exited;

  WindowsTray._(this._hwnd, this._port, this._exited);

  /// Starts the tray isolate; [onCommand] receives menu commands.
  static Future<WindowsTray> start({
    required String url,
    required String configPath,
    required String logPath,
    required Uint8List iconPng,
    String? startupHint,
    required void Function(TrayCommand command) onCommand,
    required void Function(String message) onError,
  }) async {
    final port = ReceivePort();
    final ready = Completer<int>();
    port.listen((message) {
      switch (message) {
        case 'quit' || 'restart':
          onCommand(TrayCommand.values.byName(message as String));
        case int hwnd when !ready.isCompleted:
          ready.complete(hwnd);
        case String error when !ready.isCompleted:
          ready.completeError(StateError(error));
        case String error:
          onError(error);
      }
    });
    final exitPort = ReceivePort();
    final exited = exitPort.first;
    await Isolate.spawn(
      _trayMain,
      _TrayArgs(
        port.sendPort,
        url,
        configPath,
        logPath,
        TransferableTypedData.fromList([iconPng]),
        startupHint,
      ),
      debugName: 'tray',
      onExit: exitPort.sendPort,
    );
    try {
      return WindowsTray._(await ready.future, port, exited);
    } on Object {
      port.close();
      rethrow;
    }
  }

  /// Removes the icon and waits (max. 2 s) for the tray isolate to end.
  Future<void> close() async {
    PostMessage(Pointer.fromAddress(_hwnd), WM_CLOSE, 0, 0);
    await _exited.timeout(const Duration(seconds: 2), onTimeout: () {});
    _port.close();
  }
}

class _TrayArgs {
  final SendPort port;
  final String url;
  final String configPath;
  final String logPath;
  final TransferableTypedData icon;
  final String? startupHint;

  _TrayArgs(
    this.port,
    this.url,
    this.configPath,
    this.logPath,
    this.icon,
    this.startupHint,
  );
}

const _callbackMessage = WM_APP + 1;
const _idOpen = 1, _idSettings = 2, _idLog = 3, _idRestart = 4, _idQuit = 5;

void _trayMain(_TrayArgs args) {
  final arena = Arena();
  try {
    _runTray(args, arena);
  } on Object catch (e) {
    args.port.send('Tray: $e');
  } finally {
    arena.releaseAll();
  }
}

void _runTray(_TrayArgs args, Arena arena) {
  final hInstance = GetModuleHandle(nullptr);
  final className = 'SchulportalClientTray'.toNativeUtf16(allocator: arena);
  final taskbarCreated = RegisterWindowMessage(
    'TaskbarCreated'.toNativeUtf16(allocator: arena),
  );
  final nid = arena<NOTIFYICONDATA>();
  var iconAdded = false;

  void openUrl() => shellOpen(args.url);

  void showMenu(Pointer hwnd) => using((arena) {
    final menu = CreatePopupMenu();
    void item(int id, String text) =>
        AppendMenu(menu, MF_STRING, id, text.toNativeUtf16(allocator: arena));
    item(_idOpen, 'Schulportal-Client öffnen');
    item(_idSettings, 'Einstellungen bearbeiten');
    item(_idLog, 'Protokoll anzeigen');
    AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
    item(_idRestart, 'Neu starten');
    item(_idQuit, 'Beenden');
    SetMenuDefaultItem(menu, _idOpen, 0);

    final pt = arena<POINT>();
    GetCursorPos(pt);
    // Required so the menu closes when clicking elsewhere.
    SetForegroundWindow(hwnd);
    final id = TrackPopupMenu(
      menu,
      TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
      pt.ref.x,
      pt.ref.y,
      0,
      hwnd,
      nullptr,
    );
    PostMessage(hwnd, WM_NULL, 0, 0);
    DestroyMenu(menu);

    switch (id) {
      case _idOpen:
        openUrl();
      case _idSettings:
        openInNotepad(args.configPath);
      case _idLog:
        openInNotepad(args.logPath);
      case _idRestart:
        args.port.send('restart');
      case _idQuit:
        args.port.send('quit');
    }
  });

  int wndProc(Pointer hwnd, int msg, int wParam, int lParam) {
    if (msg == _callbackMessage) {
      switch (lParam & 0xFFFF) {
        case WM_LBUTTONDBLCLK:
          openUrl();
        case WM_RBUTTONUP || WM_CONTEXTMENU:
          showMenu(hwnd);
      }
      return 0;
    }
    if (msg == taskbarCreated && iconAdded) {
      // Explorer restarted: add the icon again.
      Shell_NotifyIcon(NIM_ADD, nid);
      return 0;
    }
    switch (msg) {
      case WM_ENDSESSION when wParam != 0:
        args.port.send('quit');
        return 0;
      case WM_CLOSE:
        if (iconAdded) Shell_NotifyIcon(NIM_DELETE, nid);
        iconAdded = false;
        DestroyWindow(hwnd);
        return 0;
      case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wParam, lParam);
  }

  final callback = NativeCallable<WndProcNative>.isolateLocal(
    wndProc,
    exceptionalReturn: 0,
  );
  try {
    final wc = arena<WNDCLASSEX>()
      ..ref.cbSize = sizeOf<WNDCLASSEX>()
      ..ref.lpfnWndProc = callback.nativeFunction
      ..ref.hInstance = hInstance
      ..ref.lpszClassName = className;
    if (RegisterClassEx(wc) == 0) throw StateError('RegisterClassEx failed');

    // A hidden top-level window (not message-only) also receives the
    // TaskbarCreated and WM_ENDSESSION broadcasts.
    final hwnd = CreateWindowEx(
      0,
      className,
      'Schulportal-Client'.toNativeUtf16(allocator: arena),
      0,
      0,
      0,
      0,
      0,
      nullptr,
      nullptr,
      hInstance,
      nullptr,
    );
    if (hwnd == nullptr) throw StateError('CreateWindowEx failed');

    nid.ref
      ..cbSize = sizeOf<NOTIFYICONDATA>()
      ..hWnd = hwnd
      ..uID = 1
      ..uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP
      ..uCallbackMessage = _callbackMessage
      ..hIcon = _loadIcon(
        hInstance,
        args.icon.materialize().asUint8List(),
        arena,
      );
    setFixedString(nid.ref.szTip, 128, 'Schulportal-Client');
    if (Shell_NotifyIcon(NIM_ADD, nid) == 0) {
      throw StateError('Shell_NotifyIcon failed');
    }
    iconAdded = true;

    final hint = args.startupHint;
    if (hint != null) {
      nid.ref
        ..uFlags = NIF_INFO
        ..dwInfoFlags = NIIF_INFO;
      setFixedString(nid.ref.szInfoTitle, 64, 'Schulportal-Client');
      setFixedString(nid.ref.szInfo, 256, hint);
      Shell_NotifyIcon(NIM_MODIFY, nid);
      nid.ref.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    }

    args.port.send(hwnd.address);

    final msg = arena<MSG>();
    while (GetMessage(msg, nullptr, 0, 0) > 0) {
      TranslateMessage(msg);
      DispatchMessage(msg);
    }
  } finally {
    callback.close();
  }
}

/// Small icon for the current DPI: the exe's icon resource (set by
/// tool/set_exe_icon.dart, has hand-tuned small sizes), else the embedded
/// PNG, else the generic application icon.
Pointer _loadIcon(Pointer hInstance, Uint8List png, Arena arena) {
  final cx = GetSystemMetrics(SM_CXSMICON), cy = GetSystemMetrics(SM_CYSMICON);
  final fromExe = LoadImage(
    hInstance,
    Pointer.fromAddress(1),
    IMAGE_ICON,
    cx,
    cy,
    0,
  );
  if (fromExe != nullptr) return fromExe;
  if (png.isNotEmpty) {
    final data = arena<Uint8>(png.length);
    data.asTypedList(png.length).setAll(0, png);
    final icon = CreateIconFromResourceEx(
      data,
      png.length,
      1,
      0x00030000,
      cx,
      cy,
      LR_DEFAULTCOLOR,
    );
    if (icon != nullptr) return icon;
  }
  return LoadIcon(nullptr, Pointer.fromAddress(IDI_APPLICATION));
}
