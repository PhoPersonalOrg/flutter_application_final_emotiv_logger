import 'package:shared_preferences/shared_preferences.dart';

/// Supported network transport protocols for streaming samples.
enum NetworkProtocol { udp, tcp }

extension NetworkProtocolExtension on NetworkProtocol {
  String get storageValue => switch (this) {
    NetworkProtocol.udp => 'udp',
    NetworkProtocol.tcp => 'tcp',
  };

  static NetworkProtocol fromStorage(String? raw) {
    return switch (raw) {
      'tcp' => NetworkProtocol.tcp,
      'udp' => NetworkProtocol.udp,
      _ => NetworkProtocol.udp,
    };
  }
}

/// User-configurable settings persisted locally.
class AppSettings {
  const AppSettings({
    this.useNetworkStream = false,
    this.networkHost = defaultHost,
    this.networkPort = defaultPort,
    this.networkProtocol = NetworkProtocol.udp,
    this.saveDirectory,
  });

  final bool useNetworkStream;
  final String networkHost;
  final int networkPort;
  final NetworkProtocol networkProtocol;
  final String? saveDirectory;

  static const String defaultHost = 'apogee.tailc8d2c6.ts.net';
  static const int defaultPort = 9878;

  AppSettings copyWith({bool? useNetworkStream, String? networkHost, int? networkPort, NetworkProtocol? networkProtocol, String? saveDirectory}) {
    return AppSettings(useNetworkStream: useNetworkStream ?? this.useNetworkStream, networkHost: networkHost ?? this.networkHost, networkPort: networkPort ?? this.networkPort, networkProtocol: networkProtocol ?? this.networkProtocol, saveDirectory: saveDirectory ?? this.saveDirectory);
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{'useNetworkStream': useNetworkStream, 'networkHost': networkHost, 'networkPort': networkPort, 'networkProtocol': networkProtocol.storageValue, 'saveDirectory': saveDirectory};
  }

  static AppSettings fromJson(Map<String, Object?> json) {
    return AppSettings(useNetworkStream: (json['useNetworkStream'] as bool?) ?? false, networkHost: (json['networkHost'] as String?) ?? defaultHost, networkPort: (json['networkPort'] as int?) ?? defaultPort, networkProtocol: NetworkProtocolExtension.fromStorage(json['networkProtocol'] as String?), saveDirectory: json['saveDirectory'] as String?);
  }
}

/// Simple persistence helper backed by [SharedPreferences].
class AppSettingsRepository {
  static const _useNetworkStreamKey = 'settings.useNetworkStream';
  static const _networkHostKey = 'settings.networkHost';
  static const _networkPortKey = 'settings.networkPort';
  static const _networkProtocolKey = 'settings.networkProtocol';
  static const _saveDirectoryKey = 'settings.saveDirectory';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(useNetworkStream: prefs.getBool(_useNetworkStreamKey) ?? false, networkHost: prefs.getString(_networkHostKey) ?? AppSettings.defaultHost, networkPort: prefs.getInt(_networkPortKey) ?? AppSettings.defaultPort, networkProtocol: NetworkProtocolExtension.fromStorage(prefs.getString(_networkProtocolKey)), saveDirectory: prefs.getString(_saveDirectoryKey));
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useNetworkStreamKey, settings.useNetworkStream);
    await prefs.setString(_networkHostKey, settings.networkHost);
    await prefs.setInt(_networkPortKey, settings.networkPort);
    await prefs.setString(_networkProtocolKey, settings.networkProtocol.storageValue);
    if (settings.saveDirectory != null) {
      await prefs.setString(_saveDirectoryKey, settings.saveDirectory!);
    } else {
      await prefs.remove(_saveDirectoryKey);
    }
  }
}
