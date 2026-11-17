import 'package:nsd/nsd.dart';

/// One SMB server discovered via Bonjour / NSD (`_smb._tcp`).
class DiscoveredSmbHost {
  const DiscoveredSmbHost({
    required this.displayName,
    required this.host,
    required this.port,
  });

  /// Human-readable service instance name (often the computer name).
  final String displayName;

  /// Hostname preferred for SMB connect (e.g. `Apogee.local`).
  final String host;

  /// Advertised port (usually 445).
  final int port;
}

/// Browses the LAN for `_smb._tcp` services.
class SmbDiscovery {
  SmbDiscovery._();

  static const serviceType = '_smb._tcp';

  /// Discovers SMB hosts for [duration], then stops browsing.
  static Future<List<DiscoveredSmbHost>> browse({
    Duration duration = const Duration(seconds: 6),
  }) async {
    final discovery = await startDiscovery(
      serviceType,
      autoResolve: true,
      ipLookupType: IpLookupType.any,
    );
    try {
      await Future<void>.delayed(duration);
      final byHost = <String, DiscoveredSmbHost>{};
      for (final service in discovery.services) {
        final mapped = _mapService(service);
        if (mapped == null) continue;
        byHost.putIfAbsent(mapped.host.toLowerCase(), () => mapped);
      }
      final list = byHost.values.toList()
        ..sort(
          (a, b) =>
              a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
        );
      return list;
    } finally {
      await stopDiscovery(discovery);
    }
  }

  static DiscoveredSmbHost? _mapService(Service service) {
    final host = _preferredHost(service);
    if (host == null || host.isEmpty) return null;
    final display = (service.name?.trim().isNotEmpty ?? false)
        ? service.name!.trim()
        : host;
    final port = service.port != null && service.port! > 0
        ? service.port!
        : 445;
    return DiscoveredSmbHost(
      displayName: display,
      host: host,
      port: port,
    );
  }

  /// Prefer a `.local` hostname; otherwise resolved host / first IP.
  static String? _preferredHost(Service service) {
    final raw = service.host?.trim();
    if (raw != null && raw.isNotEmpty) {
      final host = raw.endsWith('.') ? raw.substring(0, raw.length - 1) : raw;
      return host;
    }
    final addrs = service.addresses;
    if (addrs != null && addrs.isNotEmpty) {
      return addrs.first.address;
    }
    return null;
  }
}
