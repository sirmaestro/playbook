enum GitHubRepositoryEndpoint({required final String api}) {
  /// The WinDebloat playbook monorepo; its releases carry `WinDebloatTool-Setup.exe`.
  winDebloat(api: 'sirmaestro/playbook');

}

abstract final class NetworkEndpoints() {
  static const String microsoftUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; rv:107.0) Gecko/20100101 Firefox/107.0';

  /// Release asset name the self-updater downloads (see `.github/workflows/main.yml`).
  static const String toolSetupAsset = 'WinDebloatTool-Setup.exe';

  static Uri githubLatestRelease(GitHubRepositoryEndpoint endpoint) {
    return Uri.https('api.github.com', '/repos/${endpoint.api}/releases/latest');
  }
}

/// Links shown in the UI. This tool is a GPL-3.0 fork of Revision Tool; [upstream] is attribution only.
abstract final class ProjectLinks() {
  static const String repository = 'https://github.com/sirmaestro/playbook';
  static const String docs = '$repository/tree/main/debloat-tool#readme';
  static const String issues = '$repository/issues';
  static const String upstream = 'https://github.com/meetrevision/revision-tool';
}
