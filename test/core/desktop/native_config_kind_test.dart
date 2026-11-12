import 'package:fl_clash/core/desktop/native_config_kind.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes sing-box and Xray schemas, not the filename', () {
    expect(
      detectNativeCoreKind('{"outbounds":[{"type":"vless"}]}'),
      NativeCoreKind.singBox,
    );
    expect(
      detectNativeCoreKind('{"outbounds":[{"protocol":"vless"}]}'),
      NativeCoreKind.xray,
    );
  });

  test('recognizes Hysteria client YAML and JSON', () {
    expect(
      detectNativeCoreKind('server: example.org:443\nauth: secret\n'),
      NativeCoreKind.hysteria2,
    );
    expect(
      detectNativeCoreKind('{"server":"example.org:443","auth":"secret"}'),
      NativeCoreKind.hysteria2,
    );
  });

  test('leaves Clash, malformed and ambiguous configs unchanged', () {
    for (final source in [
      'proxies: []',
      '{"proxies":[],"outbounds":[{"type":"vless"}]}',
      '{"outbounds":[{"type":"vless"},{"protocol":"vless"}]}',
      '{"server":"example.org:443"}',
      '{}',
      'server: [',
    ]) {
      expect(detectNativeCoreKind(source), isNull, reason: source);
    }
  });
}
