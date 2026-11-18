import 'dart:io';

import 'package:flutter_emotiv_logger/sinks/recorder_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resolveRecorderIdentity returns non-empty device_id and version', () async {
    final id = await resolveRecorderIdentity(
      gpsTimeout: const Duration(milliseconds: 500),
    );
    expect(id.deviceId, isNotEmpty);
    expect(id.appVersionName, isNotEmpty);
    expect(id.gpsStatus, isNotNull);
    expect(
      ['ok', 'denied', 'disabled', 'timeout', 'unavailable'],
      contains(id.gpsStatus),
    );
    if (id.gpsStatus == 'ok') {
      expect(id.gps, isNotNull);
      expect(id.gps!['latitude'], isA<double>());
      expect(id.gps!['longitude'], isA<double>());
    }
    if (Platform.isIOS) {
      expect(
        id.deviceId.toLowerCase().contains('iphone') ||
            id.deviceId.toLowerCase().contains('ipad') ||
            id.deviceId.toLowerCase().contains('ipod'),
        isTrue,
        reason: 'iOS device_id should be a model class like iPhone/iPad',
      );
    }
  });
}
