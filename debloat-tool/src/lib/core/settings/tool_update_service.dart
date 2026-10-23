import 'dart:io';

import 'package:dio/dio.dart';

import '../../utils.dart';
import '../network/network_endpoints.dart';

class const ToolUpdateService._private() {
  factory() {
    return _instance;
  }
  static final Map<String, dynamic> _data = {};
  Map<String, dynamic> get data => _data;

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 15),
    ),
  );
  static final _options = Options(
    headers: {
      'user-agent': 'Mozilla/5.0 (Windows NT 10.0; rv:107.0) Gecko/20100101 Firefox/107.0',
      'content-type': 'application/json;charset=utf-8',
      'accept': 'application/json',
    },
  );

  static final String _githubAPI = NetworkEndpoints.githubLatestRelease(
    GitHubRepositoryEndpoint.winDebloat,
  ).toString();

  static final Directory _tempDir = Directory.systemTemp;

  static const _instance = ToolUpdateService._private();

  Future<void> fetchData() async {
    if (_data.isNotEmpty) {
      _data.clear();
    }

    final Response<dynamic> response = await _dio.get(_githubAPI, options: _options);

    final responseJson = Map<String, dynamic>.from(response.data as Map<String, dynamic>);
    _data.addAll(responseJson);
  }

  int get getCurrentVersion {
    const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');

    return int.parse(appVersion.replaceAll('.', ''));
  }

  int get getLatestVersion {
    if (_data.isEmpty) {
      logger.e('The fetched API data variable is empty');
      return -1;
    }
    return int.parse(_data['tag_name'].toString().replaceAll('.', ''));
  }

  Future<void> downloadNewVersion() async {
    final path = '${_tempDir.path}\\WinDebloatTool-Setup.exe';
    final assetList = List<Map<String, dynamic>>.from(_data['assets'] as List<dynamic>);
    // Playbook releases also carry the .apbx, so pick the installer by name.
    final Map<String, dynamic> asset = assetList.firstWhere(
      (a) => a['name'] == NetworkEndpoints.toolSetupAsset,
      orElse: () => throw StateError('${NetworkEndpoints.toolSetupAsset} not found in the latest release'),
    );
    final Response<dynamic> download = await _dio.download(
      asset['browser_download_url'] as String,
      path,
    );
    logger.i('New WinDebloat Tool download status: ${download.statusMessage}');
  }

  Future<void> installUpdate() async {
    final installerPath = '${_tempDir.path}\\WinDebloatTool-Setup.exe';
    final String appPath = Platform.resolvedExecutable;
    final scriptPath = '${_tempDir.path}\\wdtool_update.cmd';

    File(scriptPath).writeAsStringSync(
      '@echo off\r\n'
      '"$installerPath" /VERYSILENT /TASKS="desktopicon"\r\n'
      'start "" "$appPath"\r\n',
    );

    await Process.start(scriptPath, [], mode: ProcessStartMode.detached);
    exit(0);
  }
}
