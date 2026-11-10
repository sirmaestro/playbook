import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:win32_registry/win32_registry.dart';

import '../../../core/cli_generator/annotations.dart';
import '../../../core/services/win_registry_service.dart';
import '../../../core/trusted_installer/trusted_installer_service.dart';

part 'utilities_service.g.dart';

@CliCommand(name: 'utilities', description: 'Utilities tweaks')
abstract class UtilitiesService() {
  @CliToggle(
    name: 'hibernation',
    status: 'statusHibernation',
    enable: 'enableHibernation',
    disable: 'disableHibernation',
  )
  bool get statusHibernation;
  Future<void> enableHibernation();
  Future<void> disableHibernation();

  @CliToggle(
    name: 'fast-startup',
    status: 'statusFastStartup',
    enable: 'enableFastStartup',
    disable: 'disableFastStartup',
  )
  bool get statusFastStartup;
  Future<void> enableFastStartup();
  Future<void> disableFastStartup();

  @CliToggle(
    name: 'modern-standby',
    status: 'statusModernStandby',
    enable: 'enableModernStandby',
    disable: 'disableModernStandby',
  )
  bool get statusModernStandby;
  Future<void> enableModernStandby();
  Future<void> disableModernStandby();

  @CliToggle(
    name: 'tm-monitoring',
    status: 'statusTMMonitoring',
    enable: 'enableTMMonitoring',
    disable: 'disableTMMonitoring',
  )
  bool get statusTMMonitoring;
  Future<void> enableTMMonitoring();
  Future<void> disableTMMonitoring();

  @CliToggle(
    name: 'usage-reporting',
    status: 'statusUsageReporting',
    enable: 'enableUsageReporting',
    disable: 'disableUsageReporting',
  )
  bool get statusUsageReporting;
  Future<void> enableUsageReporting();
  Future<void> disableUsageReporting();

  /// The weekly `winget upgrade` scheduled task ("WinDebloat Weekly App Update"). The playbook stages
  /// `WEEKLY-UPDATE.ps1` in `%ProgramData%\WinDebloat\Weekly Update`; enabling registers the task for the
  /// signed-in user through that script, disabling deletes the task (the logs stay).
  @CliToggle(
    name: 'weekly-app-updates',
    status: 'statusWeeklyAppUpdates',
    enable: 'enableWeeklyAppUpdates',
    disable: 'disableWeeklyAppUpdates',
  )
  bool get statusWeeklyAppUpdates;
  Future<void> enableWeeklyAppUpdates();
  Future<void> disableWeeklyAppUpdates();
}

class const UtilitiesServiceImpl() implements UtilitiesService {
  static const String _weeklyTaskName = 'WinDebloat Weekly App Update';
  static const String _weeklyTaskTreeKey =
      r'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\WinDebloat Weekly App Update';

  static String get _weeklyScriptPath {
    final String programData = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    return '$programData\\WinDebloat\\Weekly Update\\WEEKLY-UPDATE.ps1';
  }

  @override
  bool get statusHibernation {
    return WinRegistryService.readInt(
          LOCAL_MACHINE,
          r'SYSTEM\ControlSet001\Control\Power',
          'HibernateEnabled',
        ) ==
        1;
  }

  @override
  Future<void> enableHibernation() async {
    await Future.wait([
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'Software\Policies\Microsoft\Windows\System',
        'ShowHibernateOption',
        1,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Control\Power',
        'HibernateEnabled',
        1,
      ),
      shell.run(r'''
powercfg -h on
powercfg /h /type full
'''),
    ]);
  }

  @override
  Future<void> disableHibernation() async {
    await Future.wait([
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'Software\Policies\Microsoft\Windows\System',
        'ShowHibernateOption',
        0,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Control\Power',
        'HibernateEnabled',
        0,
      ),
      shell.run(r'''
powercfg -h off
'''),
    ]);
  }

  // int? get statusHibernationMode {
  //   return await WinRegistryService.readInt(LOCAL_MACHINE,
  //       r'System\ControlSet001\Control\Power', 'HiberFileType');
  // }

  // Future<void> setHibernateModeReduced() async {
  //   await shell.run('powercfg /h /type reduced');
  // }

  // Future<void> setHibernateModeFull() async {
  //   await shell.run('powercfg /h /type full');
  // }

  @override
  bool get statusFastStartup {
    return WinRegistryService.readInt(
          LOCAL_MACHINE,
          r'System\ControlSet001\Control\Session Manager\Power',
          'HiberbootEnabled',
        ) ==
        1;
  }

  @override
  Future<void> enableFastStartup() async {
    await Future.wait([
      enableHibernation(),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'System\ControlSet001\Control\Session Manager\Power',
        'HiberbootEnabled',
        1,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'Software\Policies\Microsoft\Windows\System',
        'HiberbootEnabled',
        1,
      ),
    ]);
  }

  @override
  Future<void> disableFastStartup() async {
    await Future.wait([
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'System\ControlSet001\Control\Session Manager\Power',
        'HiberbootEnabled',
        0,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'Software\Policies\Microsoft\Windows\System',
        'HiberbootEnabled',
        0,
      ),
    ]);
  }

  @override
  bool get statusModernStandby {
    return WinRegistryService.readInt(
          LOCAL_MACHINE,
          r'System\CurrentControlSet\Control\Power',
          'PlatformAoAcOverride',
        ) !=
        0;
  }

  @override
  Future<void> enableModernStandby() {
    return WinRegistryService.deleteValue(
      LOCAL_MACHINE,
      r'System\CurrentControlSet\Control\Power',
      'PlatformAoAcOverride',
    );
  }

  @override
  Future<void> disableModernStandby() {
    return WinRegistryService.writeRegistryValue(
      LOCAL_MACHINE,
      r'System\CurrentControlSet\Control\Power',
      'PlatformAoAcOverride',
      0,
    );
  }

  @override
  bool get statusTMMonitoring {
    return WinRegistryService.readInt(
              LOCAL_MACHINE,
              r'SYSTEM\ControlSet001\Services\GraphicsPerfSvc',
              'Start',
            ) ==
            2 &&
        WinRegistryService.readInt(LOCAL_MACHINE, r'SYSTEM\ControlSet001\Services\Ndu', 'Start') ==
            2;
  }

  @override
  Future<void> enableTMMonitoring() async {
    await Future.wait([
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\GraphicsPerfSvc',
        'Start',
        2,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\Ndu',
        'Start',
        2,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\DPS',
        'Start',
        2,
      ),
    ]);
  }

  @override
  Future<void> disableTMMonitoring() async {
    await Future.wait([
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\GraphicsPerfSvc',
        'Start',
        4,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\Ndu',
        'Start',
        4,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\DPS',
        'Start',
        4,
      ),
    ]);
  }

  @override
  bool get statusUsageReporting {
    return WinRegistryService.readInt(
          LOCAL_MACHINE,
          r'SYSTEM\ControlSet001\Services\DPS',
          'Start',
        ) !=
        4;
  }

  @override
  Future<void> enableUsageReporting() async {
    await Future.wait([
      TrustedInstallerServiceImpl().executeCommand('wevtutil', [
        'sl',
        'Microsoft-Windows-SleepStudy/Diagnostic',
        '/q:true',
      ]),
      TrustedInstallerServiceImpl().executeCommand('wevtutil', [
        'sl',
        'Microsoft-Windows-Kernel-Processor-Power/Diagnostic',
        '/q:true',
      ]),
      TrustedInstallerServiceImpl().executeCommand('wevtutil', [
        'sl',
        'Microsoft-Windows-UserModePowerService/Diagnostic',
        '/q:true',
      ]),
      WinRegistryService.deleteValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Control\Session Manager\Power',
        'SleepStudyDisabled',
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\DPS',
        'Start',
        2,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\diagsvc',
        'Start',
        2,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\WdiServiceHost',
        'Start',
        2,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\WdiSystemHost',
        'Start',
        2,
      ),
    ]);
  }

  @override
  Future<void> disableUsageReporting() async {
    await Future.wait([
      TrustedInstallerServiceImpl().executeCommand('wevtutil', [
        'sl',
        'Microsoft-Windows-SleepStudy/Diagnostic',
        '/q:false',
      ]),
      TrustedInstallerServiceImpl().executeCommand('wevtutil', [
        'sl',
        'Microsoft-Windows-Kernel-Processor-Power/Diagnostic',
        '/q:false',
      ]),
      TrustedInstallerServiceImpl().executeCommand('wevtutil', [
        'sl',
        'Microsoft-Windows-UserModePowerService/Diagnostic',
        '/q:false',
      ]),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Control\Session Manager\Power',
        'SleepStudyDisabled',
        1,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\DPS',
        'Start',
        4,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\diagsvc',
        'Start',
        4,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\WdiServiceHost',
        'Start',
        4,
      ),
      WinRegistryService.writeRegistryValue(
        LOCAL_MACHINE,
        r'SYSTEM\ControlSet001\Services\WdiSystemHost',
        'Start',
        4,
      ),
    ]);
  }

  @override
  bool get statusWeeklyAppUpdates {
    // Task Scheduler keeps one key per task under TaskCache\Tree, so this needs no process.
    return WinRegistryService.keyExists(LOCAL_MACHINE, _weeklyTaskTreeKey);
  }

  @override
  Future<void> enableWeeklyAppUpdates() async {
    final String script = _weeklyScriptPath;
    if (!File(script).existsSync()) {
      throw FileSystemException(
        'The weekly update script is missing. Apply the WinDebloat playbook first; it stages the script.',
        script,
      );
    }
    final ProcessResult result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script,
      '-Register',
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        [script, '-Register'],
        '${result.stdout}${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  @override
  Future<void> disableWeeklyAppUpdates() async {
    if (!statusWeeklyAppUpdates) return;
    final ProcessResult result = await Process.run('schtasks.exe', [
      '/Delete',
      '/TN',
      _weeklyTaskName,
      '/F',
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'schtasks.exe',
        ['/Delete', '/TN', _weeklyTaskName, '/F'],
        '${result.stdout}${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }
}

@Riverpod(keepAlive: true)
UtilitiesService utilitiesService(Ref ref) {
  return const UtilitiesServiceImpl();
}

@riverpod
bool hibernationStatus(Ref ref) {
  return ref.watch(utilitiesServiceProvider).statusHibernation;
}

@riverpod
bool fastStartupStatus(Ref ref) {
  return ref.watch(utilitiesServiceProvider).statusFastStartup;
}

@riverpod
bool statusModernStandbyStatus(Ref ref) {
  return ref.watch(utilitiesServiceProvider).statusModernStandby;
}

@riverpod
bool tmMonitoringStatus(Ref ref) {
  return ref.watch(utilitiesServiceProvider).statusTMMonitoring;
}

@riverpod
bool usageReportingStatus(Ref ref) {
  return ref.watch(utilitiesServiceProvider).statusUsageReporting;
}

@riverpod
bool weeklyAppUpdatesStatus(Ref ref) {
  return ref.watch(utilitiesServiceProvider).statusWeeklyAppUpdates;
}
