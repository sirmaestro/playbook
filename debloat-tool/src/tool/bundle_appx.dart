import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

Future<void> main(List<String> args) async {
  const targetPath = 'additionals/packages/appx';
  final targetDir = Directory(targetPath);
  if (!targetDir.existsSync()) {
    targetDir.createSync(recursive: true);
  }

  // The CLI refuses to run unless the WinDebloat edition marker is present (see
  // WinRegistryService.isSupported); set it on the CI runner.
  if (Platform.isWindows) {
    try {
      final RegistryKey key = LOCAL_MACHINE.create(r'SOFTWARE\Microsoft\Windows NT\CurrentVersion');
      try {
        key.setValue('EditionSubVersion', const RegistryValue.string('WinDebloat'));
      } finally {
        key.close();
      }
    } catch (_) {}
  }

  stdout.writeln('Downloading VCLibs AppX packages via wdtool...');
  final cliPath = File('build/cli/bundle/bin/main_cli.exe').existsSync()
      ? 'build/cli/bundle/bin/main_cli.exe'
      : (File('../wdtool.exe').existsSync()
            ? '../wdtool.exe'
            : 'wdtool.exe');

  final ProcessResult result = await Process.run(cliPath, [
    'msstore-apps',
    '--id',
    '9NBLGGH3FRZM,9NBLGGH4RV3K',
    '-r',
    'RP',
    '--download',
    targetPath,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    exit(result.exitCode);
  }

  // Flatten Dependencies subfolder into target directory.
  final depsDir = Directory('$targetPath/Dependencies');
  if (depsDir.existsSync()) {
    for (final File entity in depsDir.listSync(recursive: true).whereType<File>()) {
      entity.renameSync('$targetPath/${entity.uri.pathSegments.last}');
    }
    depsDir.deleteSync(recursive: true);
  }

  final List<File> packages = targetDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.appx') || f.path.endsWith('.msix'))
      .toList();

  stdout.writeln('Bundled ${packages.length} AppX packages into $targetPath');
  if (packages.isEmpty) {
    stderr.writeln('Error: No AppX packages downloaded');
    exit(1);
  }
}
