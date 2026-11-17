import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'save_directory_policy.dart';

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
    this.hostname = defaultHostname,
    this.useNetworkStream = false,
    this.networkHost = defaultHost,
    this.networkPort = defaultPort,
    this.networkProtocol = NetworkProtocol.udp,
    this.preferredDeviceId,
    this.preferredDeviceName,
    this.dropboxAutoUpload = false,
    this.dropboxRemoteRoot = defaultDropboxRemoteRoot,
  });

  final String? saveDirectory;
  final bool lslEnabled;

  /// Label advertised as the LSL outlet hostname (when supported).
  final String hostname;

  final bool useNetworkStream;
  final String networkHost;
  final int networkPort;
  final NetworkProtocol networkProtocol;

  /// Last successfully connected headset (for one-tap reconnect).
  final String? preferredDeviceId;
  final String? preferredDeviceName;

  /// Upload finished session folders to Dropbox App Folder after Stop.
  final bool dropboxAutoUpload;

  /// Folder under the Dropbox App Folder (e.g. `EmotivSessions`).
  final String dropboxRemoteRoot;

  static const String defaultHostname = 'iPhone';
  static const String defaultHost = 'apogee.tailc8d2c6.ts.net';
  static const int defaultPort = 9878;
  static const String defaultDropboxRemoteRoot = 'EmotivSessions';

  AppSettings copyWith({
    String? saveDirectory,
    bool clearSaveDirectory = false,
    bool? lslEnabled,
    String? hostname,
    bool? useNetworkStream,
    String? networkHost,
    int? networkPort,
    NetworkProtocol? networkProtocol,
    String? preferredDeviceId,
    String? preferredDeviceName,
    bool clearPreferredDevice = false,
    bool? dropboxAutoUpload,
    String? dropboxRemoteRoot,
  }) {
    return AppSettings(
      saveDirectory: clearSaveDirectory
          ? null
          : (saveDirectory ?? this.saveDirectory),
      lslEnabled: lslEnabled ?? this.lslEnabled,
      hostname: hostname ?? this.hostname,
      useNetworkStream: useNetworkStream ?? this.useNetworkStream,
      networkHost: networkHost ?? this.networkHost,
      networkPort: networkPort ?? this.networkPort,
      networkProtocol: networkProtocol ?? this.networkProtocol,
      preferredDeviceId: clearPreferredDevice
          ? null
          : (preferredDeviceId ?? this.preferredDeviceId),
      preferredDeviceName: clearPreferredDevice
          ? null
          : (preferredDeviceName ?? this.preferredDeviceName),
      dropboxAutoUpload: dropboxAutoUpload ?? this.dropboxAutoUpload,
      dropboxRemoteRoot: dropboxRemoteRoot ?? this.dropboxRemoteRoot,
    );
  }
}

class AppSettingsRepository {
  static const _prefix = 'acq.v1.';
  static const _saveDirectoryKey = '${_prefix}saveDirectory';
  static const _lslEnabledKey = '${_prefix}lslEnabled';
  static const _hostnameKey = '${_prefix}hostname';
  static const _useNetworkStreamKey = '${_prefix}useNetworkStream';
  static const _networkHostKey = '${_prefix}networkHost';
  static const _networkPortKey = '${_prefix}networkPort';
  static const _networkProtocolKey = '${_prefix}networkProtocol';
  static const _preferredDeviceIdKey = '${_prefix}preferredDeviceId';
  static const _preferredDeviceNameKey = '${_prefix}preferredDeviceName';
  static const _dropboxAutoUploadKey = '${_prefix}dropboxAutoUpload';
  static const _dropboxRemoteRootKey = '${_prefix}dropboxRemoteRoot';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    var saveDirectory = prefs.getString(_saveDirectoryKey);
    if (Platform.isIOS && saveDirectory != null) {
      await prefs.remove(_saveDirectoryKey);
      saveDirectory = null;
    }
    final hostnameRaw = prefs.getString(_hostnameKey)?.trim();
    return AppSettings(
      saveDirectory: effectiveSaveDirectory(saveDirectory),
      lslEnabled: prefs.getBool(_lslEnabledKey) ?? true,
      hostname: (hostnameRaw == null || hostnameRaw.isEmpty)
          ? AppSettings.defaultHostname
          : hostnameRaw,
      useNetworkStream: prefs.getBool(_useNetworkStreamKey) ?? false,
      networkHost: prefs.getString(_networkHostKey) ?? AppSettings.defaultHost,
      networkPort: prefs.getInt(_networkPortKey) ?? AppSettings.defaultPort,
      networkProtocol: NetworkProtocolX.fromStorage(
        prefs.getString(_networkProtocolKey),
      ),
      preferredDeviceId: prefs.getString(_preferredDeviceIdKey),
      preferredDeviceName: prefs.getString(_preferredDeviceNameKey),
      dropboxAutoUpload: prefs.getBool(_dropboxAutoUploadKey) ?? false,
      dropboxRemoteRoot: prefs.getString(_dropboxRemoteRootKey) ??
          AppSettings.defaultDropboxRemoteRoot,
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    final saveDirectory = effectiveSaveDirectory(settings.saveDirectory);
    if (saveDirectory != null) {
      await prefs.setString(_saveDirectoryKey, saveDirectory);
    } else {
      await prefs.remove(_saveDirectoryKey);
    }
    await prefs.setBool(_lslEnabledKey, settings.lslEnabled);
    await prefs.setString(
      _hostnameKey,
      settings.hostname.trim().isEmpty
          ? AppSettings.defaultHostname
          : settings.hostname.trim(),
    );
    await prefs.setBool(_useNetworkStreamKey, settings.useNetworkStream);
    await prefs.setString(_networkHostKey, settings.networkHost);
    await prefs.setInt(_networkPortKey, settings.networkPort);
    await prefs.setString(
      _networkProtocolKey,
      settings.networkProtocol.storageValue,
    );
    if (settings.preferredDeviceId != null) {
      await prefs.setString(
        _preferredDeviceIdKey,
        settings.preferredDeviceId!,
      );
    } else {
      await prefs.remove(_preferredDeviceIdKey);
    }
    if (settings.preferredDeviceName != null) {
      await prefs.setString(
        _preferredDeviceNameKey,
        settings.preferredDeviceName!,
      );
    } else {
      await prefs.remove(_preferredDeviceNameKey);
    }
    await prefs.setBool(_dropboxAutoUploadKey, settings.dropboxAutoUpload);
    await prefs.setString(
      _dropboxRemoteRootKey,
      settings.dropboxRemoteRoot.trim().isEmpty
          ? AppSettings.defaultDropboxRemoteRoot
          : settings.dropboxRemoteRoot.trim(),
    );
  }
}
