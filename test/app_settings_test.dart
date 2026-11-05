import 'package:flutter_emotiv_logger/app/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppSettings copyWith and protocol storage', () {
    const s = AppSettings();
    final next = s.copyWith(
      lslEnabled: false,
      useNetworkStream: true,
      networkProtocol: NetworkProtocol.tcp,
      networkPort: 1234,
    );
    expect(next.lslEnabled, isFalse);
    expect(next.useNetworkStream, isTrue);
    expect(next.networkProtocol, NetworkProtocol.tcp);
    expect(next.networkPort, 1234);
    expect(NetworkProtocolX.fromStorage('tcp'), NetworkProtocol.tcp);
    expect(NetworkProtocolX.fromStorage(null), NetworkProtocol.udp);
  });
}
