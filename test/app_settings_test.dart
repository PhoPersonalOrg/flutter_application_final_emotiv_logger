import 'package:flutter_emotiv_logger/app/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppSettings copyWith and protocol storage', () {
    const s = AppSettings();
    expect(s.hostname, AppSettings.defaultHostname);
    final next = s.copyWith(
      lslEnabled: false,
      hostname: 'LabPhone',
      useNetworkStream: true,
      networkProtocol: NetworkProtocol.tcp,
      networkPort: 1234,
      dropboxAutoUpload: true,
      dropboxRemoteRoot: 'LabUploads',
    );
    expect(next.lslEnabled, isFalse);
    expect(next.hostname, 'LabPhone');
    expect(next.useNetworkStream, isTrue);
    expect(next.networkProtocol, NetworkProtocol.tcp);
    expect(next.networkPort, 1234);
    expect(next.dropboxAutoUpload, isTrue);
    expect(next.dropboxRemoteRoot, 'LabUploads');
    expect(NetworkProtocolX.fromStorage('tcp'), NetworkProtocol.tcp);
    expect(NetworkProtocolX.fromStorage(null), NetworkProtocol.udp);
  });
}
