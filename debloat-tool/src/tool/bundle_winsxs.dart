import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Verifies the pinned WinSxS (CBS) removal cabs committed under
/// `additionals/packages/winsxs` against `tool/winsxs_packages.json`.
///
/// The cabs were mirrored once from upstream and are committed to this repo, so the
/// build and the runtime never fetch them from the network. Fails the build when a
/// pinned cab is missing or altered, or an unpinned cab is present.
Future<void> main(List<String> args) async {
  final targetDir = Directory(
    _parseArg(args, '--output') ?? _parseArg(args, '-o') ?? 'additionals/packages/winsxs',
  );
  final manifest =
      jsonDecode(File('tool/winsxs_packages.json').readAsStringSync()) as Map<String, dynamic>;
  final List<Map<String, dynamic>> packages = (manifest['packages'] as List<dynamic>)
      .cast<Map<String, dynamic>>();

  stdout.writeln(
    'Verifying ${packages.length} pinned packages (v${manifest['version']}) in ${targetDir.path}...',
  );

  var failures = 0;
  for (final pkg in packages) {
    final name = pkg['name'] as String;
    final file = File('${targetDir.path}/$name');
    if (!file.existsSync()) {
      stderr.writeln('  MISSING $name');
      failures++;
      continue;
    }
    final String actual = sha256.convert(file.readAsBytesSync()).toString();
    if (actual != pkg['sha256']) {
      stderr.writeln('  SHA256 MISMATCH $name (expected ${pkg['sha256']}, got $actual)');
      failures++;
    } else {
      stdout.writeln('  OK $name');
    }
  }

  final Set<String> pinned = packages.map((p) => p['name'] as String).toSet();
  if (targetDir.existsSync()) {
    for (final File f in targetDir.listSync().whereType<File>().where((f) => f.path.endsWith('.cab'))) {
      final String name = f.uri.pathSegments.last;
      if (!pinned.contains(name)) {
        stderr.writeln('  UNPINNED $name (add it to tool/winsxs_packages.json or remove it)');
        failures++;
      }
    }
  }

  if (failures > 0) {
    stderr.writeln('WinSxS package verification failed ($failures problem(s)).');
    exit(1);
  }
  stdout.writeln('WinSxS package verification complete.');
}

String? _parseArg(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}
