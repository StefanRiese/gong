// Minimal Win32 bindings for the Windows desktop build: notification area
// icon, popup menu, message boxes, ShellExecute. Only loaded on Windows.
//
// ignore_for_file: non_constant_identifier_names, constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// --- constants -------------------------------------------------------------

const WM_NULL = 0x0000;
const WM_DESTROY = 0x0002;
const WM_CLOSE = 0x0010;
const WM_ENDSESSION = 0x0016;
const WM_COMMAND = 0x0111;
const WM_LBUTTONUP = 0x0202;
const WM_LBUTTONDBLCLK = 0x0203;
const WM_RBUTTONUP = 0x0205;
const WM_CONTEXTMENU = 0x007B;
const WM_APP = 0x8000;

const NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2;
const NIF_MESSAGE = 0x1, NIF_ICON = 0x2, NIF_TIP = 0x4, NIF_INFO = 0x10;
const NIIF_INFO = 0x1;

const MF_STRING = 0x0, MF_SEPARATOR = 0x800;
const TPM_RIGHTBUTTON = 0x2, TPM_NONOTIFY = 0x80, TPM_RETURNCMD = 0x100;

const MB_OK = 0x0, MB_YESNO = 0x4, MB_ICONERROR = 0x10;
const MB_ICONWARNING = 0x30, MB_ICONINFORMATION = 0x40;
const MB_SETFOREGROUND = 0x10000;
const IDYES = 6;

const SW_SHOWNORMAL = 1;
const SM_CXSMICON = 49, SM_CYSMICON = 50;
const IDI_APPLICATION = 32512;
const LR_DEFAULTCOLOR = 0;
const SYNCHRONIZE = 0x00100000;

// --- structs (x64 layout, padding added by dart:ffi) -----------------------

final class POINT extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class MSG extends Struct {
  external Pointer hwnd;
  @Uint32()
  external int message;
  @IntPtr()
  external int wParam;
  @IntPtr()
  external int lParam;
  @Uint32()
  external int time;
  external POINT pt;
  @Uint32()
  external int lPrivate;
}

final class WNDCLASSEX extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int style;
  external Pointer<NativeFunction<WndProcNative>> lpfnWndProc;
  @Int32()
  external int cbClsExtra;
  @Int32()
  external int cbWndExtra;
  external Pointer hInstance;
  external Pointer hIcon;
  external Pointer hCursor;
  external Pointer hbrBackground;
  external Pointer<Utf16> lpszMenuName;
  external Pointer<Utf16> lpszClassName;
  external Pointer hIconSm;
}

final class NOTIFYICONDATA extends Struct {
  @Uint32()
  external int cbSize;
  external Pointer hWnd;
  @Uint32()
  external int uID;
  @Uint32()
  external int uFlags;
  @Uint32()
  external int uCallbackMessage;
  external Pointer hIcon;
  @Array(128)
  external Array<Uint16> szTip;
  @Uint32()
  external int dwState;
  @Uint32()
  external int dwStateMask;
  @Array(256)
  external Array<Uint16> szInfo;
  @Uint32()
  external int uTimeoutOrVersion;
  @Array(64)
  external Array<Uint16> szInfoTitle;
  @Uint32()
  external int dwInfoFlags;
  @Uint32()
  external int guidData1;
  @Uint16()
  external int guidData2;
  @Uint16()
  external int guidData3;
  @Array(8)
  external Array<Uint8> guidData4;
  external Pointer hBalloonIcon;
}

/// Copies [s] into a fixed-size UTF-16 array, truncated and 0-terminated.
void setFixedString(Array<Uint16> target, int length, String s) {
  final units = s.codeUnits;
  final n = units.length < length - 1 ? units.length : length - 1;
  for (var i = 0; i < n; i++) {
    target[i] = units[i];
  }
  target[n] = 0;
}

// --- functions -------------------------------------------------------------

typedef WndProcNative = IntPtr Function(Pointer, Uint32, IntPtr, IntPtr);

final _user32 = DynamicLibrary.open('user32.dll');
final _shell32 = DynamicLibrary.open('shell32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final RegisterClassEx = _user32
    .lookupFunction<
      Uint16 Function(Pointer<WNDCLASSEX>),
      int Function(Pointer<WNDCLASSEX>)
    >('RegisterClassExW');

final CreateWindowEx = _user32
    .lookupFunction<
      Pointer Function(
        Uint32,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Uint32,
        Int32,
        Int32,
        Int32,
        Int32,
        Pointer,
        Pointer,
        Pointer,
        Pointer,
      ),
      Pointer Function(
        int,
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
        int,
        int,
        int,
        int,
        Pointer,
        Pointer,
        Pointer,
        Pointer,
      )
    >('CreateWindowExW');

final DestroyWindow = _user32
    .lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
      'DestroyWindow',
    );

final DefWindowProc = _user32
    .lookupFunction<
      IntPtr Function(Pointer, Uint32, IntPtr, IntPtr),
      int Function(Pointer, int, int, int)
    >('DefWindowProcW');

final GetMessage = _user32
    .lookupFunction<
      Int32 Function(Pointer<MSG>, Pointer, Uint32, Uint32),
      int Function(Pointer<MSG>, Pointer, int, int)
    >('GetMessageW');

final TranslateMessage = _user32
    .lookupFunction<Int32 Function(Pointer<MSG>), int Function(Pointer<MSG>)>(
      'TranslateMessage',
    );

final DispatchMessage = _user32
    .lookupFunction<IntPtr Function(Pointer<MSG>), int Function(Pointer<MSG>)>(
      'DispatchMessageW',
    );

final PostMessage = _user32
    .lookupFunction<
      Int32 Function(Pointer, Uint32, IntPtr, IntPtr),
      int Function(Pointer, int, int, int)
    >('PostMessageW');

final PostQuitMessage = _user32
    .lookupFunction<Void Function(Int32), void Function(int)>(
      'PostQuitMessage',
    );

final RegisterWindowMessage = _user32
    .lookupFunction<
      Uint32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)
    >('RegisterWindowMessageW');

final CreatePopupMenu = _user32
    .lookupFunction<Pointer Function(), Pointer Function()>('CreatePopupMenu');

final DestroyMenu = _user32
    .lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
      'DestroyMenu',
    );

final AppendMenu = _user32
    .lookupFunction<
      Int32 Function(Pointer, Uint32, IntPtr, Pointer<Utf16>),
      int Function(Pointer, int, int, Pointer<Utf16>)
    >('AppendMenuW');

final SetMenuDefaultItem = _user32
    .lookupFunction<
      Int32 Function(Pointer, Uint32, Uint32),
      int Function(Pointer, int, int)
    >('SetMenuDefaultItem');

final TrackPopupMenu = _user32
    .lookupFunction<
      Int32 Function(Pointer, Uint32, Int32, Int32, Int32, Pointer, Pointer),
      int Function(Pointer, int, int, int, int, Pointer, Pointer)
    >('TrackPopupMenu');

final GetCursorPos = _user32
    .lookupFunction<
      Int32 Function(Pointer<POINT>),
      int Function(Pointer<POINT>)
    >('GetCursorPos');

final SetForegroundWindow = _user32
    .lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
      'SetForegroundWindow',
    );

final GetSystemMetrics = _user32
    .lookupFunction<Int32 Function(Int32), int Function(int)>(
      'GetSystemMetrics',
    );

final CreateIconFromResourceEx = _user32
    .lookupFunction<
      Pointer Function(
        Pointer<Uint8>,
        Uint32,
        Int32,
        Uint32,
        Int32,
        Int32,
        Uint32,
      ),
      Pointer Function(Pointer<Uint8>, int, int, int, int, int, int)
    >('CreateIconFromResourceEx');

final LoadIcon = _user32
    .lookupFunction<
      Pointer Function(Pointer, Pointer),
      Pointer Function(Pointer, Pointer)
    >('LoadIconW');

final DestroyIcon = _user32
    .lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
      'DestroyIcon',
    );

final MessageBox = _user32
    .lookupFunction<
      Int32 Function(Pointer, Pointer<Utf16>, Pointer<Utf16>, Uint32),
      int Function(Pointer, Pointer<Utf16>, Pointer<Utf16>, int)
    >('MessageBoxW');

final Shell_NotifyIcon = _shell32
    .lookupFunction<
      Int32 Function(Uint32, Pointer<NOTIFYICONDATA>),
      int Function(int, Pointer<NOTIFYICONDATA>)
    >('Shell_NotifyIconW');

final ShellExecute = _shell32
    .lookupFunction<
      IntPtr Function(
        Pointer,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Int32,
      ),
      int Function(
        Pointer,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
      )
    >('ShellExecuteW');

final GetModuleHandle = _kernel32
    .lookupFunction<
      Pointer Function(Pointer<Utf16>),
      Pointer Function(Pointer<Utf16>)
    >('GetModuleHandleW');

final CreateMutex = _kernel32
    .lookupFunction<
      Pointer Function(Pointer, Int32, Pointer<Utf16>),
      Pointer Function(Pointer, int, Pointer<Utf16>)
    >('CreateMutexW');

final OpenMutex = _kernel32
    .lookupFunction<
      Pointer Function(Uint32, Int32, Pointer<Utf16>),
      Pointer Function(int, int, Pointer<Utf16>)
    >('OpenMutexW');

/// Resolves all functions above (used by `server check` in CI).
List<Object> resolveAll() => [
  RegisterClassEx,
  CreateWindowEx,
  DestroyWindow,
  DefWindowProc,
  GetMessage,
  TranslateMessage,
  DispatchMessage,
  PostMessage,
  PostQuitMessage,
  RegisterWindowMessage,
  CreatePopupMenu,
  DestroyMenu,
  AppendMenu,
  SetMenuDefaultItem,
  TrackPopupMenu,
  GetCursorPos,
  SetForegroundWindow,
  GetSystemMetrics,
  CreateIconFromResourceEx,
  LoadIcon,
  DestroyIcon,
  MessageBox,
  Shell_NotifyIcon,
  ShellExecute,
  GetModuleHandle,
  CreateMutex,
  OpenMutex,
];

// --- helpers ---------------------------------------------------------------

/// Shows a message box; returns the pressed button (IDYES, …).
int messageBox(String text, String caption, int flags) => using((arena) {
  return MessageBox(
    nullptr,
    text.toNativeUtf16(allocator: arena),
    caption.toNativeUtf16(allocator: arena),
    flags | MB_SETFOREGROUND,
  );
});

/// Opens [file] (URL, document or program) like a double-click in Explorer.
bool shellOpen(String file, {String? parameters}) => using((arena) {
  final r = ShellExecute(
    nullptr,
    'open'.toNativeUtf16(allocator: arena),
    file.toNativeUtf16(allocator: arena),
    parameters == null ? nullptr : parameters.toNativeUtf16(allocator: arena),
    nullptr,
    SW_SHOWNORMAL,
  );
  return r > 32;
});

/// Opens a text file in Notepad (also for files without .txt extension).
bool openInNotepad(String path) =>
    shellOpen('notepad.exe', parameters: '"$path"');

/// Creates a named mutex held for the process lifetime; false if another
/// instance already holds it. (GetLastError is not reliable through dart:ffi,
/// so an existing mutex is detected with OpenMutex.)
bool acquireSingleInstanceMutex(String name) => using((arena) {
  final n = name.toNativeUtf16(allocator: arena);
  if (OpenMutex(SYNCHRONIZE, 0, n) != nullptr) return false;
  return CreateMutex(nullptr, 0, n) != nullptr;
});
