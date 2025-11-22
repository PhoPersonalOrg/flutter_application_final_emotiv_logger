import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_emotiv_logger/settings/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettingsRepository', () {
    test('loads defaults when no preferences are stored', () async {
      SharedPreferences.setMockInitialValues({});

      final repo = AppSettingsRepository();
      final settings = await repo.load();

      expect(settings.useNetworkStream, isFalse);
      expect(settings.networkHost, AppSettings.defaultHost);
      expect(settings.networkPort, AppSettings.defaultPort);
      expect(settings.networkProtocol, NetworkProtocol.udp);
    });

    test('persists and reloads custom values', () async {
      SharedPreferences.setMockInitialValues({});

      final repo = AppSettingsRepository();
      const updated = AppSettings(
        useNetworkStream: true,
        networkHost: '10.0.0.5',
        networkPort: 9000,
        networkProtocol: NetworkProtocol.tcp,
      );

      await repo.save(updated);
      final settings = await repo.load();

      expect(settings.useNetworkStream, isTrue);
      expect(settings.networkHost, '10.0.0.5');
      expect(settings.networkPort, 9000);
      expect(settings.networkProtocol, NetworkProtocol.tcp);
    });
  });
}
