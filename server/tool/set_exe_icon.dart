// Writes an .ico file as application icon into a Windows executable (the icon
// Explorer, taskbar and Alt+Tab show). Runs on Windows only (UpdateResource).
//
//   dart run tool/set_exe_icon.dart <file.exe> <icon.ico>
//
// The release build runs `server check` afterwards to make sure the exe still
// works.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _rtIcon = 3, _rtGroupIcon = 14;
const _langNeutral = 0;

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _begin = _kernel32
    .lookupFunction<
      Pointer Function(Pointer<Utf16>, Int32),
      Pointer Function(Pointer<Utf16>, int)
    >('BeginUpdateResourceW');
final _update = _kernel32
    .lookupFunction<
      Int32 Function(Pointer, Pointer, Pointer, Uint16, Pointer<Uint8>, Uint32),
      int Function(Pointer, Pointer, Pointer, int, Pointer<Uint8>, int)
    >('UpdateResourceW');
final _end = _kernel32
    .lookupFunction<Int32 Function(Pointer, Int32), int Function(Pointer, int)>(
      'EndUpdateResourceW',
    );

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: set_exe_icon.dart <file.exe> <icon.ico>');
    exit(64);
  }
  if (!Platform.isWindows) _fail('runs on Windows only');
  final exe = File(args[0]).absolute.path;
  final ico = ByteData.sublistView(File(args[1]).readAsBytesSync());

  // ICONDIR: reserved, type (1 = icon), count; then 16-byte ICONDIRENTRYs.
  if (ico.getUint16(0, Endian.little) != 0 ||
      ico.getUint16(2, Endian.little) != 1) {
    _fail('${args[1]} is not an .ico file');
  }
  final count = ico.getUint16(4, Endian.little);
  final images = <Uint8List>[];
  // GRPICONDIR: same header, 14-byte entries with a resource ID instead of
  // the file offset.
  final group = ByteData(6 + 14 * count)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, count, Endian.little);
  for (var i = 0; i < count; i++) {
    final e = 6 + 16 * i;
    final size = ico.getUint32(e + 8, Endian.little);
    final offset = ico.getUint32(e + 12, Endian.little);
    images.add(Uint8List.sublistView(ico, offset, offset + size));
    final g = 6 + 14 * i;
    for (var b = 0; b < 4; b++) {
      group.setUint8(g + b, ico.getUint8(e + b)); // width, height, colors, 0
    }
    group
      // Planes must be 1 (Pillow writes 0 for PNG entries).
      ..setUint16(g + 4, 1, Endian.little)
      ..setUint16(g + 6, ico.getUint16(e + 6, Endian.little), Endian.little)
      ..setUint32(g + 8, size, Endian.little)
      ..setUint16(g + 12, i + 1, Endian.little); // RT_ICON id
  }

  using((arena) {
    final handle = _begin(exe.toNativeUtf16(allocator: arena), 0);
    if (handle == nullptr) _fail('BeginUpdateResource failed for $exe');
    void put(int type, int id, Uint8List data) {
      final buf = arena<Uint8>(data.length)
        ..asTypedList(data.length).setAll(0, data);
      // MAKEINTRESOURCE: integer IDs passed as pointer values.
      final ok = _update(
        handle,
        Pointer.fromAddress(type),
        Pointer.fromAddress(id),
        _langNeutral,
        buf,
        data.length,
      );
      if (ok == 0) {
        _end(handle, 1);
        _fail('UpdateResource failed (type $type, id $id)');
      }
    }

    for (var i = 0; i < images.length; i++) {
      put(_rtIcon, i + 1, images[i]);
    }
    put(_rtGroupIcon, 1, group.buffer.asUint8List());
    if (_end(handle, 0) == 0) _fail('EndUpdateResource failed');
  });
  stdout.writeln('$exe: icon with $count sizes from ${args[1]}');
}

Never _fail(String message) {
  stderr.writeln('set_exe_icon: $message');
  exit(1);
}
