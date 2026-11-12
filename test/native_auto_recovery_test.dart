import 'dart:convert';
import 'package:fl_clash/core/native_auto_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> config() => {
  'route': {'final': 'main'},
  'outbounds': [
    {'type': 'selector', 'tag': 'main', 'default': 'a', 'outbounds': ['a', 'b', 'direct']},
    {'type': 'vless', 'tag': 'a', 'server': 'a.example'},
    {'type': 'trojan', 'tag': 'b', 'server': 'b.example'},
    {'type': 'direct', 'tag': 'direct'},
  ],
};

void main() {
  test('adds native auto group without changing original routing or default', () {
    final original = config();
    final result = buildNativeAutoRecovery(jsonEncode(original));
    final decoded = jsonDecode(result.json) as Map;
    final outbounds = decoded['outbounds'] as List;
    final auto = outbounds.last as Map;
    expect(result.addedGroups, ['FlClash Auto · main']);
    expect(auto['outbounds'], ['a', 'b']);
    expect(auto['type'], 'urltest');
    expect(auto['interval'], '3m');
    expect(auto['idle_timeout'], '15m');
    expect(auto['interrupt_exist_connections'], false);
    expect((outbounds.first as Map)['default'], 'a');
    expect(decoded['route'], original['route']);
    expect((outbounds.first as Map)['outbounds'], ['a', 'b', 'direct', 'FlClash Auto · main']);
    expect((original['outbounds'] as List).length, 4);
  });
  test('existing auto group is not duplicated', () {
    final value = config();
    final items = value['outbounds'] as List;
    (items.first['outbounds'] as List).add('auto');
    items.add({'type': 'urltest', 'tag': 'auto', 'outbounds': ['a', 'b']});
    expect(() => buildNativeAutoRecovery(jsonEncode(value)), throwsFormatException);
  });
  test('name collisions get a unique tag and direct is excluded', () {
    final value = config();
    (value['outbounds'] as List).add({'type': 'direct', 'tag': 'FlClash Auto · main'});
    expect(buildNativeAutoRecovery(jsonEncode(value)).addedGroups, ['FlClash Auto · main 2']);
  });
  test('does not create group from one proxy and direct', () {
    final value = config();
    ((value['outbounds'] as List).first['outbounds'] as List).remove('b');
    expect(() => buildNativeAutoRecovery(jsonEncode(value)), throwsFormatException);
  });
}
