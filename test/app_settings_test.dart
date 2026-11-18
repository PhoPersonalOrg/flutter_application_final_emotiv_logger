import 'package:flutter_emotiv_logger/app/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppSettings copyWith and protocol storage', () {
    const s = AppSettings();
    expect(s.hostname, AppSettings.defaultHostname);
    expect(s.dropboxLiveSync, isTrue);
    final next = s.copyWith(
      lslEnabled: false,
      hostname: 'LabPhone',
      useNetworkStream: true,
      networkProtocol: NetworkProtocol.tcp,
      networkPort: 1234,
      dropboxLiveSync: false,
      dropboxRemoteRoot: 'LabUploads',
    );
    expect(next.lslEnabled, isFalse);
    expect(next.hostname, 'LabPhone');
    expect(next.useNetworkStream, isTrue);
    expect(next.networkProtocol, NetworkProtocol.tcp);
    expect(next.networkPort, 1234);
    expect(next.dropboxLiveSync, isFalse);
    expect(next.dropboxRemoteRoot, 'LabUploads');
    expect(NetworkProtocolX.fromStorage('tcp'), NetworkProtocol.tcp);
    expect(NetworkProtocolX.fromStorage(null), NetworkProtocol.udp);
  });
}
