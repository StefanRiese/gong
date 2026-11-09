// Marks a Windows executable as GUI application (IMAGE_SUBSYSTEM_WINDOWS_GUI),
// so starting it opens no console window. Used for the tray build.
//
//   dart run tool/set_gui_subsystem.dart build/.../server.exe

import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: set_gui_subsystem.dart <file.exe>');
    exit(64);
  }
  final file = File(args.single);
  final bytes = file.readAsBytesSync();
  final data = ByteData.sublistView(bytes);

  if (data.getUint16(0, Endian.little) != 0x5A4D) _fail('no MZ header');
  final pe = data.getUint32(0x3C, Endian.little);
  if (data.getUint32(pe, Endian.little) != 0x00004550) _fail('no PE header');
  // PE signature (4) + COFF header (20) → optional header; Subsystem at +68
  // for both PE32 and PE32+.
  final optional = pe + 24;
  final magic = data.getUint16(optional, Endian.little);
  if (magic != 0x10B && magic != 0x20B) _fail('unknown optional header');
  final offset = optional + 68;
  final old = data.getUint16(offset, Endian.little);
  if (old != 2 && old != 3) _fail('unexpected subsystem $old');
  data.setUint16(offset, 2, Endian.little); // IMAGE_SUBSYSTEM_WINDOWS_GUI
  file.writeAsBytesSync(bytes, flush: true);
  stdout.writeln('${file.path}: subsystem $old → 2 (GUI)');
}

Never _fail(String message) {
  stderr.writeln('set_gui_subsystem: $message');
  exit(1);
}
