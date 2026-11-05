import 'package:shared_preferences/shared_preferences.dart';

enum NetworkProtocol { udp, tcp }

extension NetworkProtocolX on NetworkProtocol {
  String get storageValue => name;

  static NetworkProtocol fromStorage(String? raw) {
    return switch (raw) {
      'tcp' => NetworkProtocol.tcp,
      _ => NetworkProtocol.udp,
    };
  }
}

/// Rewritten settings schema (no backwards compatibility with prior keys).
class AppSettings {
  const AppSettings({
    this.saveDirectory,
    this.lslEnabled = true,
    this.useNetworkStream = false,
    this.networkHost = defaultHost,
    this.networkPort = defaultPort,
    this.networkProtocol = NetworkProtocol.udp,
  });

  final String? saveDirectory;
  final bool lslEnabled;
  final bool useNetworkStream;
  final String networkHost;
  final int networkPort;
  final NetworkProtocol networkProtocol;

  static const String defaultHost = 'apogee.tailc8d2c6.ts.net';
  static const int defaultPort = 9878;

  AppSettings copyWith({
    String? saveDirectory,
    bool clearSaveDirectory = false,
    bool? lslEnabled,
    bool? useNetworkStream,
    String? networkHost,
    int? networkPort,
    NetworkProtocol? networkProtocol,
  }) {
    return AppSettings(
      saveDirectory: clearSaveDirectory
          ? null
          : (saveDirectory ?? this.saveDirectory),
      lslEnabled: lslEnabled ?? this.lslEnabled,
      useNetworkStream: useNetworkStream ?? this.useNetworkStream,
      networkHost: networkHost ?? this.networkHost,
      networkPort: networkPort ?? this.networkPort,
      networkProtocol: networkProtocol ?? this.networkProtocol,
    );
  }
}

class AppSettingsRepository {
  static const _prefix = 'acq.v1.';
  static const _saveDirectoryKey = '${_prefix}saveDirectory';
  static const _lslEnabledKey = '${_prefix}lslEnabled';
  static const _useNetworkStreamKey = '${_prefix}useNetworkStream';
  static const _networkHostKey = '${_prefix}networkHost';
  static const _networkPortKey = '${_prefix}networkPort';
  static const _networkProtocolKey = '${_prefix}networkProtocol';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      saveDirectory: prefs.getString(_saveDirectoryKey),
      lslEnabled: prefs.getBool(_lslEnabledKey) ?? true,
      useNetworkStream: prefs.getBool(_useNetworkStreamKey) ?? false,
      networkHost: prefs.getString(_networkHostKey) ?? AppSettings.defaultHost,
      networkPort: prefs.getInt(_networkPortKey) ?? AppSettings.defaultPort,
      networkProtocol: NetworkProtocolX.fromStorage(
        prefs.getString(_networkProtocolKey),
      ),
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    if (settings.saveDirectory != null) {
      await prefs.setString(_saveDirectoryKey, settings.saveDirectory!);
    } else {
      await prefs.remove(_saveDirectoryKey);
    }
    await prefs.setBool(_lslEnabledKey, settings.lslEnabled);
    await prefs.setBool(_useNetworkStreamKey, settings.useNetworkStream);
    await prefs.setString(_networkHostKey, settings.networkHost);
    await prefs.setInt(_networkPortKey, settings.networkPort);
    await prefs.setString(
      _networkProtocolKey,
      settings.networkProtocol.storageValue,
    );
  }
}
